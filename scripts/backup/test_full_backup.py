import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name('full_backup.py')


class FullBackupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = Path(tempfile.mkdtemp(prefix='backup-test-'))
        cls.identity = cls.base / 'identity'
        subprocess.run(['age-keygen', '-o', str(cls.identity)], check=True, capture_output=True)
        pub = subprocess.check_output(['age-keygen', '-y', str(cls.identity)], text=True)
        (cls.base / 'recipients').write_text(pub)
        subprocess.run(['createdb', 'mosaic_backup_test'], check=True)
        subprocess.run(['psql', '-d', 'mosaic_backup_test', '-v', 'ON_ERROR_STOP=1', '-c',
                        "CREATE TABLE backup_probe(id integer primary key, value text); INSERT INTO backup_probe VALUES (1,'real-pg-fixture');"], check=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['dropdb', 'mosaic_backup_test'], check=True)

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir=self.base))
        self.db = self.root / 'bot.db'
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE web_credentials(id integer, login text)')
            c.execute("INSERT INTO web_credentials VALUES (1,'fixture@example.invalid')")
        config = self.root / 'service.env'
        config.write_text('FIXTURE_ONLY=not-a-real-secret\n')
        paths = self.root / 'paths'
        paths.write_text(str(config))
        self.env = dict(os.environ, PG_MODE='local', DB_USER=os.getenv('USER', 'postgres'),
                        DB_NAME='mosaic_backup_test', BOT_DB_PATH=str(self.db),
                        BACKUP_DIR=str(self.root / 'backups'), BACKUP_LOCK=str(self.root / 'lock'),
                        AGE_RECIPIENTS_FILE=str(self.base / 'recipients'), CONFIG_PATHS_FILE=str(paths), MIN_FREE_MB='1')

    def call(self, *args, ok=True, env=None):
        result = subprocess.run(['python3', str(SCRIPT), *args], env=env or self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def create(self):
        self.call('backup')
        return (self.root / 'backups/latest.tar.gz.age').resolve()

    def test_real_pg_sqlite_config_roundtrip(self):
        archive = self.create()
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.call('restore', str(archive), '--identity', str(self.identity), '--verify-only')
        subprocess.run(['psql', '-d', 'mosaic_backup_test', '-c', 'DELETE FROM backup_probe'], check=True)
        with sqlite3.connect(self.db) as c:
            c.execute('DELETE FROM web_credentials')
        out = self.root / 'restored-config'
        self.call('restore', str(archive), '--identity', str(self.identity), '--confirm-stopped', '--config-output', str(out))
        result = subprocess.check_output(['psql', '-d', 'mosaic_backup_test', '-Atc', 'SELECT value FROM backup_probe'], text=True)
        self.assertEqual(result.strip(), 'real-pg-fixture')
        with sqlite3.connect(self.db) as c:
            self.assertEqual(c.execute('SELECT count(*) FROM web_credentials').fetchone()[0], 1)
        self.assertEqual(len(list(out.rglob('service.env'))), 1)
        self.assertFalse(list((self.root / 'backups').glob('.staging-*')))

    def test_corrupt_pg_archive_leaves_sqlite_untouched(self):
        import full_backup
        archive = self.create()
        stage = self.root / 'mutated'
        stage.mkdir()
        with unittest.mock.patch.dict(os.environ, self.env):
            full_backup.unpack(archive, self.identity, stage)
        dump = stage / 'postgres.dump'
        raw = dump.read_bytes()
        # Keep outer manifest valid so rejection exercises pg_restore archive validation.
        dump.write_bytes(raw[:64])
        manifest = json.loads((stage / 'manifest.json').read_text())
        manifest['files']['postgres.dump'] = {'bytes': dump.stat().st_size, 'sha256': full_backup.sha(dump)}
        (stage / 'manifest.json').write_text(json.dumps(manifest))
        payload = self.root / 'broken.tar.gz'
        with tarfile.open(payload, 'w:gz') as t:
            for p in stage.rglob('*'):
                if p.is_file():
                    t.add(p, arcname=str(p.relative_to(stage)))
        broken = self.root / 'broken.age'
        subprocess.run(['age', '-R', str(self.base / 'recipients'), '-o', str(broken), str(payload)], check=True)
        self.call('restore', str(broken), '--identity', str(self.identity), '--confirm-stopped', '--config-output', str(self.root / 'out'), ok=False)
        with sqlite3.connect(self.db) as c:
            self.assertEqual(c.execute('SELECT count(*) FROM web_credentials').fetchone()[0], 1)

    def test_restore_over_corrupted_sqlite(self):
        archive = self.create()
        self.db.write_bytes(b'corrupt database fixture')
        self.call('restore', str(archive), '--identity', str(self.identity), '--confirm-stopped', '--config-output', str(self.root / 'recovered'))
        with sqlite3.connect(self.db) as c:
            self.assertEqual(c.execute('SELECT count(*) FROM web_credentials').fetchone()[0], 1)
        self.assertEqual(next(self.root.glob('bot.db.pre-restore-*')).read_bytes(), b'corrupt database fixture')

    def test_missing_sqlite_never_creates_empty_database(self):
        self.db.unlink()
        self.call('backup', ok=False)
        self.assertFalse(self.db.exists())

    def test_requires_recipients_and_space(self):
        self.call('backup', ok=False, env=dict(self.env, AGE_RECIPIENTS_FILE='/missing'))
        self.call('backup', ok=False, env=dict(self.env, MIN_FREE_MB='9999999999'))

    def test_corrupted_ciphertext_rejected(self):
        archive = self.create()
        data = bytearray(archive.read_bytes())
        data[-12] ^= 1
        archive.write_bytes(data)
        self.call('restore', str(archive), '--identity', str(self.identity), '--verify-only', ok=False)

    def test_rclone_transport_readback_and_status(self):
        remote = self.root / 'remote-fixture'
        self.call('backup', env=dict(self.env, RCLONE_REMOTE=str(remote)))
        status = json.loads((self.root / 'backups/last-success.json').read_text())
        self.assertTrue(status['offsite_verified'])
        local = self.root / 'backups' / status['file']
        self.assertEqual(local.read_bytes(), (remote / status['file']).read_bytes())

    def test_remote_failure_preserves_local_without_success_status(self):
        self.call('backup', ok=False, env=dict(self.env, RCLONE_REMOTE='unconfigured-fixture:backup'))
        self.assertEqual(len(list((self.root / 'backups').glob('mosaic_full_*.tar.gz.age'))), 1)
        self.assertFalse((self.root / 'backups/last-success.json').exists())

    def test_restore_requires_explicit_writer_stop(self):
        archive = self.create()
        self.call('restore', str(archive), '--identity', str(self.identity), ok=False)

    def test_wrong_key_rejected(self):
        archive = self.create()
        key = self.root / 'wrong-key'
        subprocess.run(['age-keygen', '-o', str(key)], check=True, capture_output=True)
        self.call('restore', str(archive), '--identity', str(key), '--verify-only', ok=False)

    def test_tar_traversal_rejected(self):
        payload = self.root / 'malicious.tar.gz'
        with tarfile.open(payload, 'w:gz') as t:
            member = tarfile.TarInfo('../escape')
            member.size = 4
            t.addfile(member, io.BytesIO(b'evil'))
        enc = self.root / 'malicious.age'
        subprocess.run(['age', '-R', str(self.base / 'recipients'), '-o', str(enc), str(payload)], check=True)
        self.call('restore', str(enc), '--identity', str(self.identity), '--verify-only', ok=False)
        self.assertFalse((self.root / 'escape').exists())

    def test_sqlite_runtime_error_integrity_check_fallback(self):
        # Verify narrow SQLite integrity check fallback and stale -journal preservation
        archive = self.create()
        # Create a valid SQLite DB then corrupt cells so backup succeeds but PRAGMA integrity_check fails
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE foo (id INT, bar TEXT)')
            for i in range(500):
                c.execute('INSERT INTO foo VALUES (?, ?)', (i, 'val_' + str(i)))
        # Stale journal alongside corrupted DB
        journal = Path(str(self.db) + '-journal')
        journal.write_bytes(b'stale journal data')
        raw = bytearray(self.db.read_bytes())
        for j in range(8200, 8210):
            raw[j] ^= 0xFF
        self.db.write_bytes(raw)

        self.call('restore', str(archive), '--identity', str(self.identity), '--confirm-stopped', '--config-output', str(self.root / 'rec-journal'))
        with sqlite3.connect(self.db) as c:
            self.assertEqual(c.execute('SELECT count(*) FROM web_credentials').fetchone()[0], 1)
        # Verify stale -journal was removed from live db target
        self.assertFalse(journal.exists())
        # Verify stale -journal was preserved in the safety pre-restore backup
        safety = [p for p in self.root.glob('bot.db.pre-restore-*') if not p.name.endswith('-journal')][0]
        safety_journal = Path(str(safety) + '-journal')
        self.assertTrue(safety_journal.exists())
        self.assertEqual(safety_journal.read_bytes(), b'stale journal data')

    def test_lock_parent_creation_and_contention(self):
        import fcntl
        # Test parent creation
        nested_lock = self.root / 'nested' / 'dir' / 'backup.lock'
        self.assertFalse(nested_lock.parent.exists())
        self.call('backup', env=dict(self.env, BACKUP_LOCK=str(nested_lock)))
        self.assertTrue(nested_lock.parent.exists())

        # Test lock contention raises error
        with nested_lock.open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            res = self.call('backup', env=dict(self.env, BACKUP_LOCK=str(nested_lock)), ok=False)
            self.assertIn('Another backup or restore operation is in progress', res.stderr)

    def test_certbot_symlink_reconstruction_roundtrip(self):
        # Create mock certbot structure: archive/, accounts/, and live/ with relative symlinks
        etc = self.root / 'etc_letsencrypt'
        archive_dir = etc / 'archive' / 'domain.com'
        live_dir = etc / 'live' / 'domain.com'
        accounts_dir = etc / 'accounts' / 'acme'
        archive_dir.mkdir(parents=True)
        live_dir.mkdir(parents=True)
        accounts_dir.mkdir(parents=True)

        cert = archive_dir / 'cert1.pem'
        cert.write_text('CERT_DATA_1')
        privkey = archive_dir / 'privkey1.pem'
        privkey.write_text('PRIVKEY_DATA_1')
        account_meta = accounts_dir / 'meta.json'
        account_meta.write_text('{"account": "123"}')

        # Relative symlinks as created by Certbot
        (live_dir / 'cert.pem').symlink_to('../../archive/domain.com/cert1.pem')
        (live_dir / 'privkey.pem').symlink_to('../../archive/domain.com/privkey1.pem')

        paths = self.root / 'cert_paths'
        paths.write_text(f"{archive_dir.parent}\n{live_dir.parent}\n{accounts_dir.parent}\n")

        archive = self.call('backup', env=dict(self.env, CONFIG_PATHS_FILE=str(paths)))
        latest = (self.root / 'backups/latest.tar.gz.age').resolve()

        # Restore
        out = self.root / 'cert-restored'
        self.call('restore', str(latest), '--identity', str(self.identity), '--force', '--config-output', str(out))

        restored_live = out / str(live_dir).lstrip('/')
        restored_archive = out / str(archive_dir).lstrip('/')
        restored_accounts = out / str(accounts_dir).lstrip('/')

        self.assertTrue((restored_accounts / 'meta.json').is_file())
        self.assertTrue((restored_archive / 'cert1.pem').is_file())
        self.assertTrue((restored_live / 'cert.pem').is_symlink())
        self.assertTrue((restored_live / 'privkey.pem').is_symlink())
        self.assertEqual(os.readlink(restored_live / 'cert.pem'), '../../archive/domain.com/cert1.pem')
        # Reading through symlink returns target data
        self.assertEqual((restored_live / 'cert.pem').read_text(), 'CERT_DATA_1')

    def test_certbot_symlink_path_escape_rejected(self):
        import full_backup
        archive = self.create()
        stage = self.root / 'escape_stage'
        stage.mkdir()
        with unittest.mock.patch.dict(os.environ, self.env):
            full_backup.unpack(archive, self.identity, stage)
        manifest = json.loads((stage / 'manifest.json').read_text())
        # Inject malicious symlink escaping config tree
        manifest['links'] = {'config/evil.pem': '../../../../etc/shadow'}
        (stage / 'manifest.json').write_text(json.dumps(manifest))
        payload = self.root / 'escape.tar.gz'
        with tarfile.open(payload, 'w:gz') as t:
            for p in stage.rglob('*'):
                if p.is_file():
                    t.add(p, arcname=str(p.relative_to(stage)))
        escape_age = self.root / 'escape.age'
        subprocess.run(['age', '-R', str(self.base / 'recipients'), '-o', str(escape_age), str(payload)], check=True)
        res = self.call('restore', str(escape_age), '--identity', str(self.identity), '--verify-only', ok=False)
        self.assertIn('escapes config tree', res.stderr)

    def test_scoped_remote_retention_local_transport(self):
        remote = self.root / 'remote_retention'
        remote.mkdir(parents=True)
        # Put an unrelated file in remote to verify it is NOT deleted
        unrelated = remote / 'do_not_touch.txt'
        unrelated.write_text('safe')

        # Run multiple backups with RETENTION_DAYS=0 to trigger retention pruning of older backups
        # Each backup is unique in timestamp
        archives_created = []
        for _ in range(4):
            time.sleep(0.01)
            self.call('backup', env=dict(self.env, RCLONE_REMOTE=str(remote), RETENTION_DAYS='0'))
            status = json.loads((self.root / 'backups/last-success.json').read_text())
            archives_created.append(status['file'])

        # Unrelated file must be intact
        self.assertTrue(unrelated.exists())
        self.assertEqual(unrelated.read_text(), 'safe')

        # Remote archives must retain latest and at least 2 archives
        remote_files = [p.name for p in remote.glob('mosaic_full_*.tar.gz.age')]
        self.assertGreaterEqual(len(remote_files), 2)
        # The latest archive must be present
        self.assertIn(archives_created[-1], remote_files)
        # Checksums for retained archives must also exist
        for f in remote_files:
            self.assertTrue((remote / (f + '.sha256')).exists())
        # Pruning should have removed older archives (we created 4 with RETENTION_DAYS=0)
        self.assertEqual(len(remote_files), 2)
        self.assertNotIn(archives_created[0], remote_files)
        self.assertNotIn(archives_created[1], remote_files)
        self.assertIn(archives_created[2], remote_files)
        self.assertIn(archives_created[3], remote_files)

    def test_pg_restore_idempotent_fk_schema(self):
        # Verify pg_restore restores cleanly twice over existing schema with foreign keys
        # without requiring DROP SCHEMA outside transaction.
        subprocess.run(['psql', '-d', 'mosaic_backup_test', '-v', 'ON_ERROR_STOP=1', '-c', """
            CREATE TABLE fk_parent (id integer primary key, name text);
            CREATE TABLE fk_child (id integer primary key, parent_id integer references fk_parent(id));
            INSERT INTO fk_parent VALUES (1, 'parent-1');
            INSERT INTO fk_child VALUES (10, 1);
        """], check=True)
        try:
            archive = self.create()
            out1 = self.root / 'fk-restored-1'
            out2 = self.root / 'fk-restored-2'
            # First restore into existing DB
            self.call('restore', str(archive), '--identity', str(self.identity), '--confirm-stopped', '--config-output', str(out1))
            res1 = subprocess.check_output(['psql', '-d', 'mosaic_backup_test', '-Atc',
                                            'SELECT c.id, p.name FROM fk_child c JOIN fk_parent p ON c.parent_id = p.id'], text=True)
            self.assertEqual(res1.strip(), '10|parent-1')

            # Second restore into existing DB (idempotence rehearsal test)
            self.call('restore', str(archive), '--identity', str(self.identity), '--confirm-stopped', '--config-output', str(out2))
            res2 = subprocess.check_output(['psql', '-d', 'mosaic_backup_test', '-Atc',
                                            'SELECT c.id, p.name FROM fk_child c JOIN fk_parent p ON c.parent_id = p.id'], text=True)
            self.assertEqual(res2.strip(), '10|parent-1')
        finally:
            subprocess.run(['psql', '-d', 'mosaic_backup_test', '-c',
                            'DROP TABLE IF EXISTS fk_child; DROP TABLE IF EXISTS fk_parent;'], check=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
