"""Run the complete generator against fixed DB rows in fresh processes."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch


def generate():
    import rebuild_pool_config as r
    countries = ['DE', 'NL', 'FR', 'GB', 'FI', 'PL', 'US', 'CA', 'JP', 'SG']
    rows = []
    for i in range(100):
        tag = f'fixture-{i:03d}'
        rows.append((i, {'type': 'vless', 'tag': tag, 'server': '192.0.2.1',
                         'server_port': 443, 'uuid': '00000000-0000-0000-0000-000000000001'},
                     countries[i % len(countries)], 100, 1.0, 10.0, 1.0))
    cur = Mock()
    cur.fetchall.side_effect = [rows, []]
    conn = Mock()
    conn.cursor.return_value = cur
    captured = []
    def capture(config, tmp_path):
        captured.append(config)
        Path(tmp_path).unlink()
        return False
    with patch.object(r, 'pg_connect', return_value=conn), \
         patch.object(r.subprocess, 'run', return_value=Mock(returncode=0)), \
         patch.object(r, 'apply_config_change', side_effect=capture), \
         contextlib.redirect_stdout(io.StringIO()):
        r.main()
    print(json.dumps(captured[0], sort_keys=True))


class GeneratorDeterminismTest(unittest.TestCase):
    def test_same_rows_produce_identical_membership_and_order_across_processes(self):
        configs = []
        for seed in ['1', '2', '3', '17', '42']:
            env = dict(os.environ, PYTHONHASHSEED=seed)
            result = subprocess.run([sys.executable, __file__, '--generate'],
                                    env=env, capture_output=True, text=True,
                                    check=True, timeout=15)
            configs.append(json.loads(result.stdout))
        for i, config in enumerate(configs[1:], 1):
            a = {x['tag']: x.get('outbounds', []) for x in configs[0]['outbounds']}
            b = {x['tag']: x.get('outbounds', []) for x in config['outbounds']}
            differences = [tag for tag in a if a[tag] != b[tag]]
            self.assertEqual(configs[0], config,
                             f'Non-deterministic groups in process {i}: {differences}')


if __name__ == '__main__':
    if '--generate' in sys.argv:
        generate()
    else:
        unittest.main()
