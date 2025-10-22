#!/bin/sh
# deploy.sh
# POSIX-friendly deployment script for Stage 1 task (EC2/remote Linux)
# Performs steps 1-10 from the task spec, includes --cleanup, logging, idempotency.
# Usage:
#   ./deploy.sh            # interactive deploy
#   ./deploy.sh --cleanup  # cleanup deployed resources (asks for remote details)
#
# Exit codes:
# 10 input validation, 20 git, 30 ssh, 40 remote prep, 50 transfer, 60 deploy, 70 nginx, 80 validation, 255 unexpected

set -eu
# try pipefail if available
( set -o pipefail ) 2>/dev/null || true

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE="deploy_${TIMESTAMP}.log"
exec 3>&1
# redirect stdout/stderr to logfile
exec 1>>"$LOGFILE" 2>&1

info() {
  printf "[%s] INFO: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&3
  printf "[%s] INFO: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}
fatal() {
  printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&3
  printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" 1>&2
  exit "${2:-1}"
}
on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fatal "Script exited with code $rc. See $LOGFILE"
  else
    info "Script finished successfully. Full log: $LOGFILE"
  fi
}
trap on_exit EXIT

# parse optional flag
CLEANUP=false
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP=true
fi

# helpers
prompt() {
  varname=$1; shift
  printf "%s: " "$*" >&3
  read -r val
  eval "$varname=\"\$val\""
}
prompt_secret() {
  varname=$1; shift
  printf "%s (hidden): " "$*" >&3
  if command -v stty >/dev/null 2>&1; then
    stty -echo || true
    read -r val || val=""
    stty echo || true
    printf "\n" >&3
  else
    read -r val
  fi
  eval "$varname=\"\$val\""
}
is_num() {
  case "$1" in
    ''|*[!0-9]* ) return 1;;
    *) return 0;;
  esac
}
looks_like_git() {
  case "$1" in
    https://*|http://*|git@*|ssh://*) return 0;;
    *) return 1;;
  esac
}

# CLEANUP path
if [ "$CLEANUP" = "true" ]; then
  info "CLEANUP mode: please provide remote details"
  prompt REMOTE_USER "Remote SSH username (e.g. ubuntu)"
  prompt REMOTE_HOST "Remote IP/hostname"
  prompt SSH_KEY "SSH key path (e.g. ~/.ssh/my-ec2-key.pem)"
  prompt REMOTE_PROJECT_DIR "Remote project directory to remove (e.g. /opt/app)"
  [ -z "${REMOTE_PROJECT_DIR}" ] && fatal "Remote project dir required for cleanup" 10

  info "Running cleanup on ${REMOTE_USER}@${REMOTE_HOST}..."
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" <<'EOF'
set -e
sudo systemctl stop nginx || true
docker ps -a -q | xargs -r docker rm -f || true
docker network ls -q | xargs -r docker network rm || true
sudo rm -rf "${REMOTE_PROJECT_DIR}" || true
sudo rm -f /etc/nginx/sites-enabled/deploy_site || true
sudo rm -f /etc/nginx/sites-available/deploy_site || true
sudo nginx -t || true
sudo systemctl reload nginx || true
echo CLEANUP_DONE
EOF

  info "Cleanup done."
  exit 0
fi

# Step 1: collect inputs
info "Collecting inputs..."
prompt GIT_URL "Git repository URL (HTTPS or SSH)"
if ! looks_like_git "$GIT_URL"; then
  fatal "Invalid Git URL." 10
fi
prompt_secret GITHUB_PAT "Git Personal Access Token (PAT) - leave empty for public/SSH"
prompt BRANCH "Branch (press Enter for 'main')"
BRANCH=${BRANCH:-main}
prompt REMOTE_USER "Remote SSH username (e.g. ubuntu)"
prompt REMOTE_HOST "Remote IP/hostname"
prompt SSH_KEY "SSH key path (e.g. ~/.ssh/my-ec2-key.pem)"
case "$SSH_KEY" in "~"/*) SSH_KEY=$(printf "%s" "$SSH_KEY" | sed "s#^~#$HOME#") ;; esac
[ ! -r "$SSH_KEY" ] && fatal "SSH key not readable at $SSH_KEY" 10
prompt CONTAINER_PORT "Application internal container port (numeric, e.g. 8080)"
if ! is_num "$CONTAINER_PORT"; then fatal "Container port must be numeric" 10; fi
prompt REMOTE_PROJECT_DIR "Remote project dir (e.g. /opt/app) - press Enter for /opt/app"
REMOTE_PROJECT_DIR=${REMOTE_PROJECT_DIR:-/opt/app}

info "Inputs: repo=$GIT_URL branch=$BRANCH remote=${REMOTE_USER}@${REMOTE_HOST} project_dir=${REMOTE_PROJECT_DIR} container_port=${CONTAINER_PORT}"

# Step 2: clone/pull repo locally
LOCAL_WORKDIR="$(pwd)/deploy_repo_${TIMESTAMP}"
mkdir -p "$LOCAL_WORKDIR" || fatal "Cannot create workdir" 1
cd "$LOCAL_WORKDIR" || fatal "Cannot cd to workdir" 1

CLONE_URL="$GIT_URL"
if [ -n "${GITHUB_PAT:-}" ]; then
  case "$GIT_URL" in
    https://*) CLONE_URL=$(printf "%s" "$GIT_URL" | sed "s#https://#https://${GITHUB_PAT}@#") ;;
    *) info "PAT provided but repo URL is not HTTPS; will use SSH/public method." ;;
  esac
fi

REPO_NAME=$(basename "$GIT_URL" .git)
if [ -d "$REPO_NAME/.git" ]; then
  info "Repository exists locally; pulling latest"
  cd "$REPO_NAME" || fatal "cd repo failed" 20
  git fetch --all --prune || true
  if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then git checkout "$BRANCH" || true; else git checkout -b "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1 || true; fi
  git pull origin "$BRANCH" || fatal "git pull failed" 20
else
  info "Cloning $GIT_URL (branch $BRANCH)"
  if ! git clone --branch "$BRANCH" "$CLONE_URL" "$REPO_NAME"; then fatal "git clone failed" 20; fi
  cd "$REPO_NAME" || fatal "cd repo failed" 20
fi

# Step 3: verify dockerfile or compose
if [ -f Dockerfile ]; then
  APP_MODE="dockerfile"; info "Dockerfile found"
elif [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  APP_MODE="compose"; info "docker-compose found"
else
  fatal "No Dockerfile or docker-compose.yml found!" 22
fi

# Step 4: SSH dry run
info "Testing SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo SSH_OK" >/dev/null 2>&1; then
  fatal "SSH connectivity failed. Check key/user/host/security group" 30
fi
info "SSH OK"

# Step 5: prepare remote environment (idempotent)
info "Preparing remote environment (install Docker, compose, nginx)..."
REMOTE_PREP=$(cat <<'EOF'
set -eu
if command -v apt-get >/dev/null 2>&1; then
  PM=apt
elif command -v yum >/dev/null 2>&1; then
  PM=yum
else
  echo "UNSUPPORTED"
  exit 1
fi
if [ "$PM" = "apt" ]; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release || true
fi
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
if ! docker compose version >/dev/null 2>&1; then
  if [ "$PM" = "apt" ]; then
    sudo apt-get install -y docker-compose-plugin || true
  fi
  if ! docker compose version >/dev/null 2>&1; then
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || true
    sudo chmod +x /usr/local/bin/docker-compose || true
  fi
fi
sudo systemctl enable docker --now || true
if ! groups "$USER" 2>/dev/null | grep -q docker; then sudo usermod -aG docker "$USER" || true; fi
if ! command -v nginx >/dev/null 2>&1; then
  if [ "$PM" = "apt" ]; then
    sudo apt-get install -y nginx || true
  else
    sudo yum install -y epel-release nginx || true
    sudo systemctl enable nginx --now || true
  fi
fi
sudo systemctl enable nginx --now || true
docker --version || true
docker compose version || true
nginx -v || true
echo PREP_DONE
EOF
)
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<EOF
$REMOTE_PREP
EOF
then
  fatal "Remote preparation failed" 40
fi
info "Remote prepared"

# Step 6: transfer files
info "Transferring project to ${REMOTE_HOST}:${REMOTE_PROJECT_DIR}"
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo mkdir -p '${REMOTE_PROJECT_DIR}' && sudo chown -R ${REMOTE_USER}:${REMOTE_USER} '${REMOTE_PROJECT_DIR}'" || fatal "remote dir prepare failed" 50

if command -v rsync >/dev/null 2>&1; then
  RSYNC_EXCL="--exclude=.git --exclude=node_modules --exclude=venv --exclude=__pycache__"
  if ! rsync -az ${RSYNC_EXCL} -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" ./ "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/"; then
    fatal "rsync transfer failed" 50
  fi
else
  if ! scp -i "$SSH_KEY" -r . "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/"; then
    fatal "scp transfer failed" 50
  fi
fi
info "Files transferred"

# Step 6 continued: remote build/run
info "Building and starting container(s) on remote"
REMOTE_DEPLOY=$(cat <<END
set -eu
cd "${REMOTE_PROJECT_DIR}" || exit 1
sudo chown -R "${REMOTE_USER}":"${REMOTE_USER}" "${REMOTE_PROJECT_DIR}" || true
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  docker compose down --remove-orphans || true
  docker compose pull || true
  docker compose up -d --build || true
else
  IMAGE_NAME="deploy_$(basename "${REMOTE_PROJECT_DIR}")"
  docker build -t "\${IMAGE_NAME}" . || true
  if docker ps -a --format '{{.Names}}' | grep -q "\${IMAGE_NAME}" 2>/dev/null; then
    docker rm -f "\${IMAGE_NAME}" || true
  fi
  docker run -d --name "\${IMAGE_NAME}" -p ${CONTAINER_PORT}:${CONTAINER_PORT} "\${IMAGE_NAME}" || true
fi
sleep 3
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
echo DEPLOY_OK
END
)
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<EOF
$REMOTE_DEPLOY
EOF
then
  fatal "Remote build/run failed" 60
fi
info "Remote containers started"

# Step 7: configure Nginx reverse proxy
info "Configuring Nginx reverse proxy (port 80 -> ${CONTAINER_PORT})"
NGINX_CONF="server {
    listen 80;
    listen [::]:80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"
TMP_REMOTE_CONF="/tmp/deploy_nginx_${TIMESTAMP}.conf"
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "cat > ${TMP_REMOTE_CONF}" <<EOF
${NGINX_CONF}
EOF
SSH_NGINX_CMDS="sudo mv '${TMP_REMOTE_CONF}' /etc/nginx/sites-available/deploy_site || true; \
sudo ln -sf /etc/nginx/sites-available/deploy_site /etc/nginx/sites-enabled/deploy_site || true; \
sudo nginx -t; sudo systemctl reload nginx || sudo systemctl restart nginx || true; echo NGINX_OK"
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "${SSH_NGINX_CMDS}"; then
  fatal "Failed to apply/reload Nginx config" 70
fi
info "Nginx configured"

# Step 8: validation
info "Validating deployment..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active --quiet docker"; then fatal "Docker not active" 80; fi
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active --quiet nginx"; then fatal "Nginx not active" 80; fi

REMOTE_HTTP_CODE=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${CONTAINER_PORT} || echo 000")
info "Remote localhost:${CONTAINER_PORT} HTTP code: ${REMOTE_HTTP_CODE}"
LOCAL_HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${REMOTE_HOST}/" || echo 000)
info "Via Nginx (http://${REMOTE_HOST}/) HTTP code: ${LOCAL_HTTP_CODE}"
if [ "${LOCAL_HTTP_CODE}" = "000" ] || [ "${LOCAL_HTTP_CODE}" != "200" ]; then
  fatal "App not reachable via Nginx (port 80). Check EC2 security group allows TCP/80" 80
fi

info "Deployment validated. App reachable at: http://${REMOTE_HOST}/"
info "Logfile saved at: ${LOCAL_WORKDIR}/${LOGFILE}"

exit 0
