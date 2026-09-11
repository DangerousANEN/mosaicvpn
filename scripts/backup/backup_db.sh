#!/usr/bin/env bash
# ==============================================================================
# MosaicVPN PostgreSQL Automated Backup System
# Target: PostgreSQL inside Docker (remnawave-db)
# Output: /var/backups/mosaic-db/mosaic_db_YYYY-MM-DD_HHMMSS.sql.gz
# Retention: 14 days of backups automatically rotated
# ==============================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/mosaic-db}"
LOG_FILE="${LOG_FILE:-/var/log/mosaic-backup.log}"
CONTAINER_NAME="${CONTAINER_NAME:-remnawave-db}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

TIMESTAMP="$(date +'%Y-%m-%d_%H%M%S')"
BACKUP_FILE="${BACKUP_DIR}/mosaic_db_${TIMESTAMP}.sql.gz"
LATEST_LINK="${BACKUP_DIR}/latest.sql.gz"

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "${LOG_FILE}" 2>/dev/null || true
}

mkdir -p "${BACKUP_DIR}"
touch "${LOG_FILE}" 2>/dev/null || true

log "=== Starting MosaicVPN Database Backup ==="

# 1. Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR: Container ${CONTAINER_NAME} is not running!"
    exit 1
fi

# 2. Perform pg_dump through container
TMP_FILE="${BACKUP_FILE}.tmp"
log "Dumping database '${DB_NAME}' from container '${CONTAINER_NAME}'..."

if docker exec "${CONTAINER_NAME}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" --clean --if-exists | gzip -9 > "${TMP_FILE}"; then
    # 3. Verify backup file size (must be > 50KB)
    FILE_SIZE=$(wc -c < "${TMP_FILE}")
    if [ "${FILE_SIZE}" -lt 50000 ]; then
        log "ERROR: Dump file is suspiciously small (${FILE_SIZE} bytes). Aborting."
        rm -f "${TMP_FILE}"
        exit 2
    fi

    # 4. Verify gzip integrity
    if ! gzip -t "${TMP_FILE}"; then
        log "ERROR: Corrupt gzip archive detected! Aborting."
        rm -f "${TMP_FILE}"
        exit 3
    fi

    mv "${TMP_FILE}" "${BACKUP_FILE}"
    
    # 5. Generate SHA256 checksum
    sha256sum "${BACKUP_FILE}" > "${BACKUP_FILE}.sha256"
    
    # 6. Update latest symlink
    ln -sf "${BACKUP_FILE}" "${LATEST_LINK}"
    
    HUMAN_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    log "SUCCESS: Backup created at ${BACKUP_FILE} (${HUMAN_SIZE}, ${FILE_SIZE} bytes)"
else
    log "ERROR: pg_dump command failed!"
    rm -f "${TMP_FILE}"
    exit 4
fi

# 7. Rotate old backups (delete files older than RETENTION_DAYS)
log "Cleaning backups older than ${RETENTION_DAYS} days..."
DELETED_COUNT=0
find "${BACKUP_DIR}" -name "mosaic_db_*.sql.gz*" -mtime "+${RETENTION_DAYS}" | while read -r old_file; do
    rm -f "${old_file}"
    log "Rotated out old backup: ${old_file}"
done

TOTAL_BACKUPS=$(find "${BACKUP_DIR}" -name "mosaic_db_*.sql.gz" | wc -l)
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log "Backup complete. Total retained backups: ${TOTAL_BACKUPS} (Total directory size: ${TOTAL_SIZE})"
log "=== Backup Finished Successfully ==="
