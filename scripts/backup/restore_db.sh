#!/usr/bin/env bash
# ==============================================================================
# MosaicVPN PostgreSQL Database Restore Utility
# Restores a compressed SQL dump into Docker container (remnawave-db)
# Usage:
#   ./restore_db.sh [/path/to/backup.sql.gz] [--force]
# ==============================================================================

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-remnawave-db}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
DEFAULT_BACKUP="/var/backups/mosaic-db/latest.sql.gz"

BACKUP_PATH="${1:-$DEFAULT_BACKUP}"
FORCE="${2:-}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

if [ ! -f "${BACKUP_PATH}" ]; then
    log "ERROR: Backup file not found at '${BACKUP_PATH}'!"
    exit 1
fi

log "=== MosaicVPN Database Restore ==="
log "Target File:      ${BACKUP_PATH}"
log "Target Container: ${CONTAINER_NAME}"
log "Target Database:  ${DB_NAME}"

# Verify gzip integrity before touching DB
log "Verifying archive integrity..."
if ! gzip -t "${BACKUP_PATH}"; then
    log "FATAL: Backup file is corrupt! Restore cancelled."
    exit 2
fi

if [ -f "${BACKUP_PATH}.sha256" ]; then
    log "Verifying SHA256 checksum..."
    (cd "$(dirname "${BACKUP_PATH}")" && sha256sum -c "$(basename "${BACKUP_PATH}.sha256")") || {
        log "FATAL: Checksum mismatch! Restore cancelled."
        exit 3
    }
fi

if [ "${FORCE}" != "--force" ] && [ "${FORCE}" != "-f" ]; then
    echo ""
    echo "WARNING: This will overwrite tables in '${DB_NAME}' with data from ${BACKUP_PATH}!"
    echo "Press Enter to proceed, or Ctrl+C to cancel..."
    read -r _
fi

log "Stopping backend services that might lock DB..."
docker stop remnawave mosaic-bot 2>/dev/null || true

log "Streaming SQL dump into ${CONTAINER_NAME}..."
gunzip -c "${BACKUP_PATH}" | docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}"

log "Starting backend services..."
docker start remnawave 2>/dev/null || true
systemctl restart mosaic-bot 2>/dev/null || true

log "Verifying restored relations..."
docker exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT count(*) as total_users FROM users;"
docker exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT count(*) as total_accounts FROM mosaic_accounts;"

log "=== Database Restore Complete & Verified! ==="
