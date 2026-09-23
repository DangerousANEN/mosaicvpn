"""Tests for rebuild_pool_config.apply_config_change restart guard.

Covers the live-incident root cause: an unconditional `systemctl restart` on
every collector cycle tore down active tunnels even when the rebuilt config
was semantically identical to the running one.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


def _load_module():
    path = Path(__file__).resolve().parent / "rebuild_pool_config.py"
    spec = importlib.util.spec_from_file_location("rebuild_pool_config_tested", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ApplyConfigChangeGuardTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.module = _load_module()
        self.pool_config = self.base / "config.json"
        self._orig = self.module.POOL_CONFIG
        self.module.POOL_CONFIG = self.pool_config
        self.restarts = []
        self._orig_run = self.module.subprocess.run
        self.module.subprocess.run = (
            lambda cmd, **kw: self.restarts.append(cmd) or mock.Mock(returncode=0)
        )
        self._orig_mkdtemp = None

    def tearDown(self):
        self.module.POOL_CONFIG = self._orig
        self.module.subprocess.run = self._orig_run
        self._tmp.cleanup()

    def _tmp_file(self):
        p = self.base / f"candidate-{len(self.restarts)}.json"
        p.write_text("{}", encoding="utf-8")
        return str(p)

    def test_identical_config_skips_restart(self):
        cfg = {"a": 1, "b": [1, 2, 3]}
        self.pool_config.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
        tmp = self.base / "cand.json"
        tmp.write_text(json.dumps(cfg), encoding="utf-8")
        self.assertFalse(self.module.apply_config_change(cfg, str(tmp)))
        self.assertEqual(self.restarts, [])
        self.assertFalse(tmp.exists(), "temp file must be removed on skip")
        # live config untouched
        self.assertEqual(json.loads(self.pool_config.read_text()), cfg)

    def test_changed_config_restarts_once(self):
        self.pool_config.write_text(json.dumps({"old": True}), encoding="utf-8")
        new_cfg = {"new": True}
        tmp = self.base / "cand2.json"
        tmp.write_text(json.dumps(new_cfg), encoding="utf-8")
        self.assertTrue(self.module.apply_config_change(new_cfg, str(tmp)))
        self.assertEqual(len(self.restarts), 1)
        self.assertEqual(json.loads(self.pool_config.read_text()), new_cfg)
        # .prev backup created
        self.assertTrue(self.pool_config.with_suffix(".json.prev").exists())

    def test_corrupt_previous_config_restarts(self):
        self.pool_config.write_text("{not json", encoding="utf-8")
        new_cfg = {"recovery": True}
        tmp = self.base / "cand3.json"
        tmp.write_text(json.dumps(new_cfg), encoding="utf-8")
        self.assertTrue(self.module.apply_config_change(new_cfg, str(tmp)))
        self.assertEqual(len(self.restarts), 1)


if __name__ == "__main__":
    unittest.main()
