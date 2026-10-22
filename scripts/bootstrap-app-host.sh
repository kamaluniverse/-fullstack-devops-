#!/usr/bin/env bash
#
# bootstrap-app-host.sh — prepare a fresh Ubuntu 22.04/24.04 EC2 instance to
# run the ProShop stack. Run it ON the instance with sudo.
#
#   sudo ./scripts/bootstrap-app-host.sh
#
# It installs Docker Engine + the Compose plugin from Docker's official
# repository, installs helper tooling, and creates the deployment directory.
# It does NOT copy application code or start the stack.
#
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run with sudo" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/proshop}"
DEPLOY_USER="${SUDO_USER:-ubuntu}"

echo "==> Installing base packages"
apt-get update -y
apt-get install -y ca-certificates curl gnupg git unzip jq

echo "==> Adding Docker's official GPG key and repository"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Enabling Docker"
systemctl enable --now docker

if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  usermod -aG docker "$DEPLOY_USER"
  echo "Added $DEPLOY_USER to the docker group (re-login required)."
fi

echo "==> Creating application directory $APP_DIR"
mkdir -p "$APP_DIR"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$APP_DIR"

docker --version
docker compose version

cat <<EOF

Bootstrap complete.

Next steps (as $DEPLOY_USER):
  1. Copy the project (or clone it) into $APP_DIR
  2. cd $APP_DIR && cp .env.example .env && edit .env
  3. ./scripts/deploy.sh
EOF
