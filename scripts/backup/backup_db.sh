#!/usr/bin/env bash
# Full encrypted PostgreSQL + SQLite + configuration snapshot.
set -euo pipefail
umask 077
if [[ -f /etc/mosaic-backup.env ]]; then
    set -a
    source /etc/mosaic-backup.env
    set +a
fi
exec python3 "$(dirname "$(realpath "$0")")/full_backup.py" backup "$@"
