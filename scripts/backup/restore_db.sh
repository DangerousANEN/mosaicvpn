#!/usr/bin/env bash
# Encrypted full restore. Legacy PG-only restore is explicit and transactional.
set -euo pipefail
umask 077
if [[ -f /etc/mosaic-backup.env ]]; then
    set -a
    source /etc/mosaic-backup.env
    set +a
fi
if [[ "${1:-}" == "--legacy-pg-only" ]]; then
    [[ $# == 3 && "$3" == "--confirm-stopped" ]] || { printf '%s\n' 'Usage: restore_db.sh --legacy-pg-only FILE.sql.gz --confirm-stopped'; exit 2; }
    gzip -t "$2"
    printf '%s\n' 'WARNING: legacy archive contains PostgreSQL only, NOT SQLite or configuration.'
    gzip -dc "$2" | docker exec -i "${CONTAINER_NAME:-remnawave-db}" \
        psql -X -v ON_ERROR_STOP=1 --single-transaction -U "${DB_USER:-postgres}" -d "${DB_NAME:-postgres}"
    exit
fi
exec python3 "$(dirname "$(realpath "$0")")/full_backup.py" restore "$@"
