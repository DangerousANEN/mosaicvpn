#!/usr/bin/env bash
# ==============================================================================
# MosaicVPN 1-Click Server Bootstrap & Disaster Recovery Suite
# Target OS: Ubuntu 22.04 / 24.04 LTS, Debian 12
# Usage:
#   sudo ./bootstrap_server.sh [--restore /path/to/backup.sql.gz]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RESTORE_BACKUP=""
if [ "${1:-}" = "--restore" ] && [ -n "${2:-}" ]; then
    RESTORE_BACKUP="$2"
fi

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_CYAN="\033[1;36m"

log_info() { echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $1"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_err()  { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }
log_step() { echo -e "\n${COLOR_CYAN}==>${COLOR_RESET} ${COLOR_GREEN}$1${COLOR_RESET}"; }

if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root (or with sudo)."
    exit 1
fi

log_step "Step 1: System Packages and Docker Installation"
apt-get update -y
apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    jq \
    gzip \
    tar \
    ufw \
    fail2ban \
    python3 \
    python3-venv \
    python3-pip \
    libpq-dev \
    gcc

if ! command -v docker >/dev/null 2>&1; then
    log_info "Docker not found. Installing official Docker CE..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
else
    log_info "Docker is already installed."
fi

log_step "Step 2: Firewall Security Configuration (UFW)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP / Let-s-Encrypt'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 8443/tcp comment 'HTTPS Alternate'
ufw --force enable
log_info "Firewall configured (Ports 22, 80, 443, 8443 open; DB port 6767 bound strictly to 127.0.0.1)."

log_step "Step 3: Directory Structure Creation"
mkdir -p /opt/remnawave/nginx/ssl
mkdir -p /opt/mosaic-bot
mkdir -p /etc/letsencrypt/landing
mkdir -p /var/backups/mosaic-db
mkdir -p /opt/mosaicvpn/scripts/backup
mkdir -p /var/www

log_step "Step 4: Deploying Static Site, Blog, Docs & SEO Intelligence"
if [ -d "${ROOT_DIR}/site" ]; then
    cp -r "${ROOT_DIR}/site/"* /etc/letsencrypt/landing/
    log_info "Static pages copied to /etc/letsencrypt/landing/"
else
    log_warn "site directory not found in ${ROOT_DIR}. Skipping static files copy."
fi

log_step "Step 5: Deploying Docker Compose and Nginx Configurations"
cp "${SCRIPT_DIR}/docker-compose.yml" /opt/remnawave/docker-compose.yml
if [ -d "${SCRIPT_DIR}/nginx" ]; then
    cp "${SCRIPT_DIR}/nginx/nginx.conf" /opt/remnawave/nginx.conf
    cp "${SCRIPT_DIR}/nginx/nginx-main.conf" /opt/remnawave/nginx-main.conf
    log_info "Nginx configurations deployed to /opt/remnawave/"
fi

if [ ! -f /opt/remnawave/.env ]; then
    if [ -f "${SCRIPT_DIR}/env.example" ]; then
        cp "${SCRIPT_DIR}/env.example" /opt/remnawave/.env
        log_warn "Created /opt/remnawave/.env from template. PLEASE UPDATE SECRETS!"
    fi
else
    log_info "/opt/remnawave/.env exists. Preserving existing secrets."
fi

log_step "Step 6: Setting Up Mosaic Bot & Cabinet API"
if [ -d "${ROOT_DIR}/bot" ]; then
    cp -r "${ROOT_DIR}/bot/"* /opt/mosaic-bot/
    log_info "Bot files synchronized to /opt/mosaic-bot/"
fi

if [ ! -d /opt/mosaic-bot/venv ]; then
    log_info "Creating Python virtual environment for bot..."
    python3 -m venv /opt/mosaic-bot/venv
fi

log_info "Installing bot dependencies..."
if [ -f /opt/mosaic-bot/requirements.txt ]; then
    /opt/mosaic-bot/venv/bin/pip install --upgrade pip
    /opt/mosaic-bot/venv/bin/pip install -r /opt/mosaic-bot/requirements.txt
fi

if [ ! -f /etc/mosaic-bot.env ]; then
    log_warn "/etc/mosaic-bot.env not found! Creating template..."
    cat <<'EOF' > /etc/mosaic-bot.env
# Mosaic Bot Environment Config (chmod 600)
BOT_TOKEN=YOUR_TELEGRAM_BOT_TOKEN_HERE
PG_HOST=127.0.0.1
PG_PORT=6767
PG_USER=postgres
PG_PASS=YOUR_POSTGRES_PASSWORD_HERE
PG_DB=postgres
EOF
    chmod 600 /etc/mosaic-bot.env
    log_warn "PLEASE EDIT /etc/mosaic-bot.env with your real credentials!"
fi

log_step "Step 7: Installing Automated Database Backup & Restore System"
cp "${ROOT_DIR}/scripts/backup/backup_db.sh" /opt/mosaicvpn/scripts/backup/backup_db.sh
cp "${ROOT_DIR}/scripts/backup/restore_db.sh" /opt/mosaicvpn/scripts/backup/restore_db.sh
chmod +x /opt/mosaicvpn/scripts/backup/*.sh

cp "${SCRIPT_DIR}/systemd/mosaic-backup.service" /etc/systemd/system/mosaic-backup.service
cp "${SCRIPT_DIR}/systemd/mosaic-backup.timer" /etc/systemd/system/mosaic-backup.timer
cp "${SCRIPT_DIR}/systemd/mosaic-bot.service" /etc/systemd/system/mosaic-bot.service

systemctl daemon-reload
systemctl enable --now mosaic-backup.timer
log_info "Automated database backup timer activated (runs at 03:00 and 15:00 UTC)."

log_step "Step 8: Starting Docker Infrastructure Stack"
cd /opt/remnawave
docker compose pull || true
docker compose up -d

log_info "Waiting for database container (remnawave-db) to become healthy..."
MAX_WAIT=60
WAITED=0
while ! docker exec remnawave-db pg_isready -U postgres >/dev/null 2>&1; do
    sleep 2
    WAITED=$((WAITED+2))
    if [ $WAITED -ge $MAX_WAIT ]; then
        log_err "Database did not become ready in ${MAX_WAIT} seconds!"
        break
    fi
done

if [ -n "${RESTORE_BACKUP}" ]; then
    log_step "Step 9: Restoring Database from Provided Snapshot (${RESTORE_BACKUP})"
    if [ -f "${RESTORE_BACKUP}" ]; then
        /opt/mosaicvpn/scripts/backup/restore_db.sh "${RESTORE_BACKUP}" --force
        log_info "Database restoration complete!"
    else
        log_err "Restore file ${RESTORE_BACKUP} not found!"
    fi
else
    log_info "No --restore parameter specified. Skipping database import."
fi

log_step "Step 10: Starting Mosaic Bot Service"
systemctl enable --now mosaic-bot.service
systemctl restart mosaic-bot.service || true

log_step "=== Deployment & Verification Summary ==="
echo ""
echo "Docker Containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Systemd Services:"
systemctl status mosaic-bot.service --no-pager | head -n 8 || true
echo ""
systemctl status mosaic-backup.timer --no-pager | head -n 8 || true
echo ""
log_info "MosaicVPN server deployment process finished!"
log_info "To test SEO & health: python3 ${ROOT_DIR}/scripts/seo_analyzer.py --remote"
