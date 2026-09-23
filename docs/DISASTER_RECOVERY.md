# Recovery and encrypted backups

## Contents and limits

`scripts/backup/backup_db.sh` creates `mosaic_full_<UTC>.tar.gz.age`:
- PostgreSQL custom dump from `remnawave-db`, validated by `pg_restore --list`.
- Online SQLite backup of `/opt/mosaic-bot/bot.db`, validated with `PRAGMA integrity_check` (accounts, credentials, Telegram links, payments and support data).
- Required configuration paths listed in `/etc/mosaic-backup.paths`, including environment, compose, Nginx, certificates and bot unit.
- Manifest with SHA-256 and sizes for every archived file.

PG and SQLite are individually consistent online snapshots, **not an atomic cross-database transaction**. After DR reconcile payments/account grants against payment-provider records. Code and static assets remain in the Git repository, not this data backup. Additional node hosts require their own configuration backup.

Encryption uses age public recipients. The private recovery identity is kept **off the VPS**, outside Git and outside the archive. Losing every copy of the private identity makes recovery impossible. Backups and staging directories use restrictive permissions. Compression is streamed into encryption, avoiding an additional plaintext tar file; individual snapshots temporarily exist in a private staging directory and are removed on normal completion/failure. Abrupt power loss can leave `.staging-*`; inspect and remove stale staging directories manually when no backup is running.

Local policy: 14 days, 1 GiB target budget, always preserve newest two encrypted backups. The two-file minimum may exceed the budget. Preflight reserves at least 768 MiB; low disk fails rather than pruning the last good copies. Old `mosaic_db_*.sql.gz` files are not deleted automatically by the new policy. Preserve them until the encrypted restore rehearsal passes, then explicitly retire obsolete plaintext copies.

## Operations

Config templates: `deploy/backup.env.example`, `deploy/backup.paths.example`.
Installed scripts: `/opt/mosaicvpn/scripts/backup/`.
Schedule: `mosaic-backup.timer`, explicitly 03:00 and 15:00 UTC.

```bash
systemctl start mosaic-backup.service
systemctl status mosaic-backup.service --no-pager
journalctl -u mosaic-backup.service -n 50 --no-pager
python3 -m json.tool /var/backups/mosaic-db/last-success.json
```

`last-success.json` is written only after local creation and, when configured, successful remote read-back. `offsite_verified: false` means there is **no verified offsite copy**. A timer being active alone does not prove backup health. Check last-success freshness against the 12-hour schedule.

## Google Drive (final authorization step)

Install/configure rclone with an explicitly authorized Google account, then set `RCLONE_REMOTE` to a dedicated folder, e.g. `mosaic-drive:MosaicVPN/backups`. No OAuth secret belongs in Git. rclone credentials must be root-only. Only encrypted archives/checksums are uploaded; each uploaded object is streamed back and SHA-256 compared. Remote failure makes the job fail while preserving the local archive.

Remote retention is scoped strictly to `mosaic_full_*.tar.gz.age` and `.sha256` archives: prunes archives older than `RETENTION_DAYS` (default 14) via `rclone lsjson` and `rclone deletefile`, while always retaining the latest and at least two archives offsite. Unrelated files on the remote are never touched. A prior local-only archive is not automatically retried; run another full backup or explicitly upload and verify it.

## Verify without database modification

Run on an isolated recovery machine with matching/newer PostgreSQL client utilities, age and Python. Use the original PG major version for production recovery unless a major upgrade is intentionally planned.

```bash
AGE_IDENTITY_FILE=/secure/offline-recovery.key \
  /opt/mosaicvpn/scripts/backup/restore_db.sh /secure/snapshot.tar.gz.age --verify-only
```

Authenticates the complete ciphertext before extraction, rejects links/traversal/duplicates, checks manifest and SQLite integrity and PG archive structure. This is necessary but does not replace an actual restore rehearsal.

## Restore rehearsal / disaster recovery

1. Provision an isolated PostgreSQL instance, matching extensions/roles and application code. Do not point a rehearsal at production.
2. Stop **all writers**: bot systemd service, Remnawave, maintenance timers/workers and any application accessing either database. Preserve a current PG snapshot before destructive restoration. Never restart automatically after failure.
3. Run verify-only first. Set `DB_NAME`, `CONTAINER_NAME` and `BOT_DB_PATH` explicitly for the intended target. For local non-Docker PG use `PG_MODE=local` and standard libpq environment variables.
4. Restore with explicit acknowledgement:

```bash
AGE_IDENTITY_FILE=/secure/offline-recovery.key \
  /opt/mosaicvpn/scripts/backup/restore_db.sh /secure/snapshot.tar.gz.age \
  --confirm-stopped --config-output /secure/recovered-config
```

PostgreSQL uses `--exit-on-error --single-transaction`; a SQL error rolls that restore back. SQLite is replaced only after PG succeeds, preserving a pre-restore SQLite snapshot if present. This is not a distributed transaction: if SQLite replacement fails after PG commit, leave writers stopped and complete recovery. Existing target database objects absent from the dump are not guaranteed to be removed: use a clean target for exact recovery.

5. Config files are staged only, NEVER copied over live service credentials automatically. Review and install to their corresponding absolute paths, preserving root-only secret permissions. Certificate renewal requires `/etc/letsencrypt/archive` and `/etc/letsencrypt/accounts` coverage alongside `live/` and `renewal/`. Relative symlinks (e.g. `live/<domain>/cert.pem -> ../../archive/<domain>/cert1.pem`) are safely reconstructed via manifest link metadata without arbitrary archive symlinks or path traversal risk. If restoring from a legacy snapshot where `live/` files were materialized flat, verify symlinks point into `archive/` and ACME accounts exist before running `certbot renew`.
6. Verify restored account/link/payment row counts, account login and subscription retrieval in the isolated instance. Reconcile cross-database/payment state. Start services only after these gates, then verify real HTTP/DNS through the client tunnel; a CONNECTED badge is insufficient.

### Legacy PG-only archive

```bash
/opt/mosaicvpn/scripts/backup/restore_db.sh --legacy-pg-only old.sql.gz --confirm-stopped
```

Uses `psql -X -v ON_ERROR_STOP=1 --single-transaction`. This does **not** restore SQLite/config. No longer supported through unattended `bootstrap_server.sh --restore`, which now refuses before modifying the system.

## Sandbox regression tests

`test_full_backup.py` uses real PostgreSQL, real SQLite and real age encryption: roundtrip data/config, corruption fallback and sidecar handling (-journal/-wal/-shm), wrong key, missing SQLite, absent recipients, low disk, lock parent creation and contention, scoped remote retention via rclone transport, certbot safe symlink reconstruction and path escape rejection, writer-stop gate and archive traversal rejection. Run inside the isolated sandbox, not the user's desktop. Test fixtures contain no production credentials.
