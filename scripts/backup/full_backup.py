#!/usr/bin/env python3
"""Encrypted PG + SQLite + configuration snapshots. Never stores encryption identities."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def pg(tool, *args, stdin=None, stdout=None):
    command = [tool, '-U', os.getenv('DB_USER', 'postgres')]
    if tool != 'pg_restore' or '--list' not in args:
        command += ['-d', os.getenv('DB_NAME', 'postgres')]
    command += list(args)
    if os.getenv('PG_MODE', 'docker') == 'docker':
        command = ['docker', 'exec', '-i', os.getenv('CONTAINER_NAME', 'remnawave-db')] + command
    return run(command, stdin=stdin, stdout=stdout)


def sha(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def sqlite_check(path):
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as db:
        if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise RuntimeError('SQLite integrity check failed')


def snapshot_sqlite(source, target):
    deadline = time.monotonic() + 120
    def progress(*_):
        if time.monotonic() > deadline:
            raise TimeoutError('SQLite snapshot exceeded 120 seconds')
    with sqlite3.connect(source.as_uri() + '?mode=ro', uri=True) as src:
        with sqlite3.connect(target) as dst:
            src.backup(dst, pages=256, progress=progress)
    sqlite_check(target)


def config_files():
    listing = Path(os.getenv('CONFIG_PATHS_FILE', '/etc/mosaic-backup.paths'))
    if not listing.is_file():
        raise RuntimeError('Required config path list missing: ' + str(listing))
    result = []
    for line in listing.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        path = Path(line.strip())
        if not path.is_absolute() or not path.exists():
            raise RuntimeError('Required config path missing: ' + str(path))
        if path.is_dir():
            children = list(path.rglob('*'))
            if any(p.is_symlink() and (not p.exists() or p.is_dir()) for p in children):
                raise RuntimeError('Broken or directory symlink in config tree: ' + str(path))
            found = [p for p in children if p.is_file()]
            if not found:
                raise RuntimeError('Required config directory is empty: ' + str(path))
            result.extend(found)
        else:
            result.append(path)
    if not result:
        raise RuntimeError('Config path list must not be empty')
    return sorted(set(result))


def backup():
    root = Path(os.getenv('BACKUP_DIR', '/var/backups/mosaic-db')).resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    recipients = Path(os.getenv('AGE_RECIPIENTS_FILE', '/etc/mosaic-backup.recipients'))
    if not recipients.is_file():
        raise RuntimeError('Encryption recipients missing; refusing plaintext backup')
    configs = config_files()
    source = Path(os.getenv('BOT_DB_PATH', '/opt/mosaic-bot/bot.db')).resolve()
    if not source.is_file():
        raise RuntimeError('Required SQLite DB missing')
    reserve = int(os.getenv('MIN_FREE_MB', '768')) * 1024 ** 2
    if shutil.disk_usage(root).free < reserve + source.stat().st_size * 2:
        raise RuntimeError('Insufficient free disk space before snapshot')
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output = root / ('mosaic_full_' + stamp + '.tar.gz.age')
    partial = output.with_suffix(output.suffix + '.partial')
    try:
        db_bytes = int(subprocess.check_output(
            (['docker', 'exec', os.getenv('CONTAINER_NAME', 'remnawave-db')] if os.getenv('PG_MODE', 'docker') == 'docker' else [])
            + ['psql', '-X', '-At', '-U', os.getenv('DB_USER', 'postgres'), '-d', os.getenv('DB_NAME', 'postgres'),
               '-v', 'ON_ERROR_STOP=1', '-c', 'SELECT pg_database_size(current_database())'], text=True).strip())
        estimated = db_bytes + source.stat().st_size + sum(p.stat().st_size for p in configs)
        if shutil.disk_usage(root).free < reserve + estimated * 2:
            raise RuntimeError('Insufficient disk for database/config staging plus encrypted output')
        with tempfile.TemporaryDirectory(prefix='.staging-', dir=root) as tmp:
            stage = Path(tmp)
            with (stage / 'postgres.dump').open('wb') as stream:
                pg('pg_dump', '--format=custom', '--compress=3', stdout=stream)
            with (stage / 'postgres.dump').open('rb') as stream:
                pg('pg_restore', '--list', stdin=stream, stdout=subprocess.DEVNULL)
            snapshot_sqlite(source, stage / 'bot.db')
            for item in configs:
                target = stage / 'config' / str(item).lstrip('/')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(item, target)
                os.chmod(target, 0o600)
            links = {}
            config_root = (stage / 'config').resolve()
            for item in configs:
                if item.is_symlink():
                    link_target = os.readlink(item)
                    if os.path.isabs(link_target) or '\\' in link_target:
                        raise RuntimeError('Unsafe symlink target: ' + str(item))
                    target = stage / 'config' / str(item).lstrip('/')
                    resolved = (target.parent / link_target).resolve()
                    try:
                        resolved.relative_to(config_root)
                    except ValueError:
                        raise RuntimeError('Symlink target escapes config tree: ' + str(item))
                    if not resolved.is_file() or resolved.is_symlink():
                        raise RuntimeError('Symlink target is not an archived regular file: ' + str(item))
                    rel_name = str(target.relative_to(stage))
                    links[rel_name] = link_target
            files = [p for p in stage.rglob('*') if p.is_file()]
            manifest = {'format': 1, 'created_utc': stamp,
                        'consistency': 'Independent online PG and SQLite snapshots, not a cross-database transaction',
                        'files': {str(p.relative_to(stage)): {'sha256': sha(p), 'bytes': p.stat().st_size} for p in files},
                        'links': links}
            (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2))
            if shutil.disk_usage(root).free < reserve + sum(p.stat().st_size for p in files):
                raise RuntimeError('Insufficient free space for encrypted archive')
            with partial.open('wb') as destination:
                enc = subprocess.Popen(['age', '-R', str(recipients)], stdin=subprocess.PIPE, stdout=destination)
                try:
                    with tarfile.open(fileobj=enc.stdin, mode='w|gz') as archive:
                        for item in sorted(stage.rglob('*')):
                            if item.is_file():
                                archive.add(item, arcname=str(item.relative_to(stage)), recursive=False)
                except BaseException:
                    enc.kill()
                    raise
                finally:
                    enc.stdin.close()
                    code = enc.wait()
                if code:
                    raise RuntimeError('age encryption failed')
                destination.flush()
                os.fsync(destination.fileno())
        partial.rename(output)
        digest = sha(output)
        checksum = Path(str(output) + '.sha256')
        checksum.write_text(digest + '  ' + output.name + '\n')
        latest_tmp = root / '.latest.age.new'
        latest_tmp.unlink(missing_ok=True)
        latest_tmp.symlink_to(output.name)
        latest_tmp.replace(root / 'latest.tar.gz.age')
        remote = os.getenv('RCLONE_REMOTE', '').strip()
        if remote:
            for file in (output, checksum):
                target = remote.rstrip('/') + '/' + file.name
                run(['rclone', 'copyto', str(file), target, '--retries', '3'])
                proc = subprocess.Popen(['rclone', 'cat', target], stdout=subprocess.PIPE)
                remote_hash = hashlib.file_digest(proc.stdout, 'sha256').hexdigest()
                proc.stdout.close()
                if proc.wait() or remote_hash != sha(file):
                    raise RuntimeError('Remote read-back hash mismatch')
        rotate(root, output)
        if remote:
            rotate_remote(remote, output)
        status = {'created_utc': stamp, 'file': output.name, 'sha256': digest,
                  'bytes': output.stat().st_size, 'offsite_verified': bool(remote)}
        (root / 'last-success.json').write_text(json.dumps(status, indent=2))
        print(json.dumps(status))
    finally:
        partial.unlink(missing_ok=True)


def rotate(root, latest):
    files = sorted(root.glob('mosaic_full_*.tar.gz.age'), key=lambda p: p.stat().st_mtime, reverse=True)
    budget = int(os.getenv('MAX_LOCAL_MB', '1024')) * 1024 ** 2
    max_age = int(os.getenv('RETENTION_DAYS', '14')) * 86400
    total = 0
    for index, item in enumerate(files):
        total += item.stat().st_size
        if index >= 2 and item != latest and (total > budget or time.time() - item.stat().st_mtime > max_age):
            item.unlink()
            Path(str(item) + '.sha256').unlink(missing_ok=True)


def rotate_remote(remote, latest):
    max_age = int(os.getenv('RETENTION_DAYS', '14')) * 86400
    out = subprocess.check_output([
        'rclone', 'lsjson', remote, '--files-only', '--include', 'mosaic_full_*.tar.gz.age*'
    ], text=True)
    items = json.loads(out)
    archives = [it for it in items if it['Name'].startswith('mosaic_full_') and it['Name'].endswith('.tar.gz.age')]
    archives.sort(key=lambda it: it['Name'], reverse=True)
    now = time.time()
    for index, arch in enumerate(archives):
        name = arch['Name']
        if index < 2 or name == latest.name:
            continue
        mtime_str = arch.get('ModTime', '')
        if mtime_str:
            if mtime_str.endswith('Z'):
                mtime = dt.datetime.fromisoformat(mtime_str[:-1]).replace(tzinfo=dt.timezone.utc).timestamp()
            else:
                mtime = dt.datetime.fromisoformat(mtime_str).timestamp()
        else:
            mtime = now
        if now - mtime > max_age:
            remote_base = remote.rstrip('/')
            run(['rclone', 'deletefile', f'{remote_base}/{name}'])
            subprocess.run(['rclone', 'deletefile', f'{remote_base}/{name}.sha256'], capture_output=True)


def unpack(source, identity, stage):
    # Authenticate the WHOLE age payload before inspecting/extracting anything.
    archive_path = stage / 'payload.tar.gz'
    run(['age', '-d', '-i', str(identity), '-o', str(archive_path), str(source)])
    limit = int(os.getenv('MAX_EXTRACT_MB', '4096')) * 1024 ** 2
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = archive.getmembers()
        names = [m.name for m in members]
        if len(names) != len(set(names)) or sum(m.size for m in members) > limit:
            raise RuntimeError('Invalid archive size or duplicate members')
        for member in members:
            p = Path(member.name)
            if not member.isfile() or p.is_absolute() or '..' in p.parts or '\\' in member.name:
                raise RuntimeError('Unsafe archive member')
            if member.name not in ('manifest.json', 'postgres.dump', 'bot.db') and not member.name.startswith('config/'):
                raise RuntimeError('Unexpected archive member')
        for member in members:
            target = stage / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as src, target.open('xb') as dst:
                shutil.copyfileobj(src, dst)
    archive_path.unlink()
    manifest = json.loads((stage / 'manifest.json').read_text())
    if manifest.get('format') != 1 or set(manifest['files']) != set(names) - {'manifest.json'}:
        raise RuntimeError('Manifest does not match archive')
    if not {'postgres.dump', 'bot.db'}.issubset(manifest['files']):
        raise RuntimeError('Required databases absent')
    for name, info in manifest['files'].items():
        target = stage / name
        if target.stat().st_size != info['bytes'] or sha(target) != info['sha256']:
            raise RuntimeError('Manifest integrity mismatch: ' + name)
    sqlite_check(stage / 'bot.db')
    with (stage / 'postgres.dump').open('rb') as stream:
        pg('pg_restore', '--list', stdin=stream, stdout=subprocess.DEVNULL)
    config_root = (stage / 'config').resolve()
    for rel_name, link_target in manifest.get('links', {}).items():
        if not rel_name.startswith('config/') or '..' in Path(rel_name).parts or '\\' in rel_name:
            raise RuntimeError('Unsafe symlink member path: ' + rel_name)
        if os.path.isabs(link_target) or '\\' in link_target:
            raise RuntimeError('Unsafe symlink target path: ' + link_target)
        link_file = stage / rel_name
        resolved = (link_file.parent / link_target).resolve()
        try:
            resolved.relative_to(config_root)
        except ValueError:
            raise RuntimeError('Manifest symlink target escapes config tree: ' + rel_name)
        if not resolved.is_file() or resolved.is_symlink():
            raise RuntimeError('Manifest symlink target is not an unpacked regular file: ' + rel_name)
        link_file.unlink()
        link_file.symlink_to(link_target)
    return manifest


def restore(args):
    if not args.identity:
        raise RuntimeError('--identity required; identity must be kept outside the backed-up VPS')
    if not args.verify_only and not args.confirm_stopped:
        raise RuntimeError('Stop all DB writers and pass --confirm-stopped; services are never restarted on failure')
    with tempfile.TemporaryDirectory(prefix='mosaic-restore-') as tmp:
        stage = Path(tmp)
        manifest = unpack(Path(args.archive), Path(args.identity), stage)
        if args.verify_only:
            print(json.dumps({'verified': True, 'files': len(manifest['files']), 'created_utc': manifest['created_utc']}))
            return
        target = Path(os.getenv('BOT_DB_PATH', '/opt/mosaic-bot/bot.db')).resolve()
        config_target = Path(args.config_output).resolve()
        if config_target.exists():
            raise RuntimeError('Config output already exists; refusing before database modifications')
        target.parent.mkdir(parents=True, exist_ok=True)
        # Preserve SQLite before touching either database. PG restore is transactional.
        old_stat = target.stat() if target.exists() else None
        if target.exists():
            safety = target.with_name(target.name + '.pre-restore-' + str(time.time_ns()))
            try:
                snapshot_sqlite(target, safety)
            except (sqlite3.DatabaseError, RuntimeError) as exc:
                if isinstance(exc, RuntimeError) and 'SQLite integrity check failed' not in str(exc):
                    raise
                safety.unlink(missing_ok=True)
                # Corrupt DBs must not make disaster recovery impossible. Preserve raw evidence.
                shutil.copyfile(target, safety)
                for suffix in ('-wal', '-shm', '-journal'):
                    sidecar = Path(str(target) + suffix)
                    if sidecar.exists():
                        shutil.copyfile(sidecar, Path(str(safety) + suffix))
        with (stage / 'postgres.dump').open('rb') as stream:
            pg('pg_restore', '--clean', '--if-exists', '--exit-on-error', '--single-transaction', stdin=stream)
        incoming = target.with_name(target.name + '.restore-tmp')
        shutil.copyfile(stage / 'bot.db', incoming)
        os.chmod(incoming, 0o600)
        if old_stat:
            os.chown(incoming, old_stat.st_uid, old_stat.st_gid)
        for suffix in ('-wal', '-shm', '-journal'):
            Path(str(target) + suffix).unlink(missing_ok=True)
        incoming.replace(target)
        sqlite_check(target)
        # Configs are always staged, never blindly overwrite live credentials/services.
        shutil.copytree(stage / 'config', config_target, symlinks=True)
        print(json.dumps({'restored': True, 'config_staging': str(config_target), 'services_restarted': False}))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('backup')
    r = sub.add_parser('restore')
    r.add_argument('archive')
    r.add_argument('--identity', default=os.getenv('AGE_IDENTITY_FILE'))
    r.add_argument('--verify-only', action='store_true')
    r.add_argument('--confirm-stopped', '--force', dest='confirm_stopped', action='store_true')
    r.add_argument('--config-output', default='/var/backups/mosaic-restored-config')
    args = parser.parse_args()
    lock = Path(os.getenv('BACKUP_LOCK', '/var/lock/mosaic-backup.lock'))
    lock.parent.mkdir(parents=True, exist_ok=True)
    try:
        handle = lock.open('a')
    except OSError as exc:
        raise RuntimeError(f'Failed to open backup lock file {lock}: {exc}') from exc
    with handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as exc:
            raise RuntimeError(f'Another backup or restore operation is in progress (lock {lock} held)') from exc
        if args.action == 'backup':
            backup()
        else:
            restore(args)


if __name__ == '__main__':
    main()
