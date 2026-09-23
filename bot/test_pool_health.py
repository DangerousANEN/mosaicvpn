"""test_pool_health.py — Regression and Sandbox Test Suite for mosaic_pool_health.py.

Verifies:
1. Safe bounded concurrency with empirical speedup vs sequential execution.
2. Anti-destructive candidate preservation across transient network hiccups.
3. Automatic candidate re-add / restoration upon recovery.
4. Strict exclusion & permanent purging of VPS own hosts (5.175.188.152, *.zxc1x1.ru).
5. Multi-protocol probing (TCP, TLS/UDP Hysteria2) with timeout and error handling.
6. Non-destructive empty group defense (urltest groups never emptied out).
7. Service restart on config change vs silence when unchanged.
8. Persistent state tracking across successive runs in /tmp/mosaic-pool-qa.
"""

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import MagicMock, patch

# Load mosaic_pool_health dynamically
MODULE_PATH = Path(__file__).with_name("mosaic_pool_health.py")
spec = importlib.util.spec_from_file_location("mosaic_pool_health", MODULE_PATH)
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


QA_DIR = Path("/tmp/mosaic-health-repair")


class BaseSandboxTestCase(unittest.TestCase):
    """Base class providing an isolated sandbox directory per test."""

    def setUp(self):
        QA_DIR.mkdir(parents=True, exist_ok=True)
        self.sandbox_dir = Path(tempfile.mkdtemp(prefix="test_health_", dir=str(QA_DIR)))
        self.config_path = self.sandbox_dir / "config.json"
        self.state_path = self.sandbox_dir / "mosaic_pool_state.json"
        os.environ["MOSAIC_NO_RESTART"] = "1"
        os.environ["MOSAIC_ALLOW_MISSING_SINGBOX"] = "1"

    def tearDown(self):
        shutil.rmtree(self.sandbox_dir, ignore_errors=True)
        os.environ.pop("MOSAIC_ALLOW_MISSING_SINGBOX", None)
        os.environ.pop("MOSAIC_NO_RESTART", None)

    def create_mock_pool_config(
        self,
        node_count: int = 5,
        include_forbidden: bool = False,
    ) -> dict:
        """Create a realistic sing-box pool config structure."""
        outbounds = []
        tags = []

        for i in range(node_count):
            tag = f"node-{i}"
            tags.append(tag)
            outbounds.append({
                "type": "vless",
                "tag": tag,
                "server": f"192.0.2.{10 + i}",
                "server_port": 443,
                "uuid": "00000000-0000-0000-0000-000000000000",
            })

        if include_forbidden:
            # Add forbidden nodes
            outbounds.append({
                "type": "vless",
                "tag": "forbidden-vps-ip",
                "server": "5.175.188.152",
                "server_port": 443,
                "uuid": "00000000-0000-0000-0000-000000000000",
            })
            outbounds.append({
                "type": "trojan",
                "tag": "forbidden-subdomain",
                "server": "sub.zxc1x1.ru",
                "server_port": 443,
                "password": "mock_password",
            })
            outbounds.append({
                "type": "shadowsocks",
                "tag": "forbidden-wildcard",
                "server": "edge01.zxc1x1.ru",
                "server_port": 8388,
                "method": "aes-128-gcm",
                "password": "mock_password",
            })
            tags.extend(["forbidden-vps-ip", "forbidden-subdomain", "forbidden-wildcard"])

        # URLTest groups
        urltest_group = {
            "type": "urltest",
            "tag": "rg-all",
            "outbounds": list(tags),
            "url": "https://www.gstatic.com/generate_204",
            "interval": "5m",  # intentional non-standard to verify harmonization
            "tolerance": 100,
        }

        config = {
            "log": {"level": "warning"},
            "inbounds": [{"type": "socks", "tag": "in-socks", "listen": "127.0.0.1", "listen_port": 10080}],
            "outbounds": outbounds + [urltest_group, {"type": "direct", "tag": "direct"}],
            "route": {"rules": [], "final": "rg-all"},
        }
        return config

    def write_config(self, config: dict) -> Path:
        self.config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
        return self.config_path


class ConcurrencyAndPerformanceTest(BaseSandboxTestCase):
    """Measures probe concurrency and verifies speedup vs sequential execution."""

    def test_probe_concurrency_measurement(self):
        """Simulate probing 20 nodes with 50ms simulated latency and verify concurrency speedup."""
        node_count = 20
        simulated_delay = 0.05  # 50ms per probe
        concurrency = 10

        outbounds_by_tag = {}
        tags = []
        for i in range(node_count):
            tag = f"bench-node-{i}"
            tags.append(tag)
            outbounds_by_tag[tag] = {
                "tag": tag,
                "server": f"10.0.0.{i + 1}",
                "server_port": 443,
            }

        active_threads = set()
        lock = threading.Lock()

        def mock_probe_tcp(server, port, timeout=2.5):
            with lock:
                active_threads.add(threading.get_ident())
            time.sleep(simulated_delay)
            return True, simulated_delay * 1000.0, None

        t0 = time.monotonic()
        with patch.object(health, "probe_tcp", side_effect=mock_probe_tcp):
            results = health.probe_candidates_concurrently(
                outbounds_by_tag,
                tags,
                concurrency=concurrency,
                timeout=1.0,
            )
        elapsed = time.monotonic() - t0

        sequential_expected = node_count * simulated_delay  # 20 * 0.05s = 1.00s
        concurrency_speedup = sequential_expected / max(elapsed, 0.001)

        self.assertEqual(len(results), node_count)
        self.assertTrue(all(r.alive is None for r in results.values()), "Transport-only TCP probes must be UNKNOWN (alive=None)")
        self.assertTrue(all(r.latency_ms is not None for r in results.values()), "All probes must have latency measured")
        self.assertTrue(all(r.error is None for r in results.values()), "All successful connects must have error=None")
        # Measured probe concurrency check
        self.assertGreaterEqual(len(active_threads), 2, "Multiple worker threads must be utilized")
        self.assertLess(elapsed, sequential_expected * 0.6, f"Elapsed {elapsed:.3f}s must be faster than sequential {sequential_expected:.3f}s")
        self.assertGreater(concurrency_speedup, 1.5, f"Speedup ratio must be > 1.5x (measured: {concurrency_speedup:.2f}x)")


class AntiDestructivePruningTest(BaseSandboxTestCase):
    """Verifies candidate preservation on transient failure and automatic restoration on recovery."""

    def test_transient_failure_does_not_prune_candidate(self):
        """A single transient probe failure should NOT remove candidate when fail_threshold is 2."""
        cfg = self.create_mock_pool_config(node_count=4)
        self.write_config(cfg)

        # In run 1: node-1 fails once, others succeed
        def mock_probe_run1(outbound, timeout=2.5, own_hosts=None):
            tag = outbound.get("tag")
            if tag == "node-1":
                return health.ProbeResult(tag=tag, alive=False, error="transient_timeout")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=45.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_run1), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_run1):
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        # Check config
        updated_cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest = next(g for g in updated_cfg["outbounds"] if g.get("type") == "urltest")
        # node-1 must still be present in urltest outbounds!
        self.assertIn("node-1", urltest["outbounds"], "Transient failure must NOT prune candidate from urltest group")

        # State must reflect failure count of 1
        state = health.load_pool_state(self.state_path)
        self.assertEqual(state["fail_counts"].get("node-1"), 1)
        self.assertEqual(summary["dead"], 0)

    def test_unknown_probe_preserves_membership_and_failure_counts(self):
        """Unknown probe result (alive=None on silence) preserves active membership and failure counts."""
        cfg = self.create_mock_pool_config(node_count=3)
        self.write_config(cfg)

        # Run 1: node-1 returns unknown (silence). Should remain active, fail_count stays 0.
        def mock_probe_silence(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            if tag == "node-1":
                return health.ProbeResult(tag=tag, alive=None, error="udp_silence_timeout", caveat="unverified_udp_silence")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=30.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_silence), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_silence):
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        updated_cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest = next(g for g in updated_cfg["outbounds"] if g.get("type") == "urltest")
        self.assertIn("node-1", urltest["outbounds"], "Candidate on silence must remain active")
        state = health.load_pool_state(self.state_path)
        self.assertEqual(state["fail_counts"].get("node-1", 0), 0)
        self.assertEqual(summary["total_unknown"], 1)

        # Pre-seed fail_counts with 1 failure for node-1, then probe with silence
        state["fail_counts"]["node-1"] = 1
        health.save_pool_state(self.state_path, state)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_silence), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_silence):
            summary2 = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        state2 = health.load_pool_state(self.state_path)
        self.assertEqual(state2["fail_counts"].get("node-1"), 1, "Silence must NOT increment nor reset failure count")
        updated_cfg2 = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest2 = next(g for g in updated_cfg2["outbounds"] if g.get("type") == "urltest")
        self.assertIn("node-1", urltest2["outbounds"], "Candidate must stay active since 1 < threshold (2)")

    def test_silence_never_readds_previously_removed_candidate(self):
        """A previously removed candidate must NEVER be re-added on silence (alive=None); requires verified response."""
        cfg = self.create_mock_pool_config(node_count=3)
        self.write_config(cfg)

        # Step 1: node-1 fails 2 times and is pruned/deactivated
        def mock_probe_fail(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            if tag == "node-1":
                return health.ProbeResult(tag=tag, alive=False, error="timeout")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=40.0)

        for _ in range(2):
            with patch.object(health, "probe_outbound", side_effect=mock_probe_fail), \
                 patch.object(health, "probe_candidate_http", side_effect=mock_probe_fail):
                health.run_health_check(
                    config_path=str(self.config_path),
                    state_path=str(self.state_path),
                    fail_threshold=2,
                )

        cfg_deactivated = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest = next(g for g in cfg_deactivated["outbounds"] if g.get("type") == "urltest")
        self.assertNotIn("node-1", urltest["outbounds"], "node-1 should be deactivated")

        # Step 2: probe returns silence/unknown (alive=None). Node-1 must NOT be re-added!
        def mock_probe_silence(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            if tag == "node-1":
                return health.ProbeResult(tag=tag, alive=None, error="silence", caveat="unverified_udp_silence")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=40.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_silence), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_silence):
            health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        cfg_after_silence = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest_after = next(g for g in cfg_after_silence["outbounds"] if g.get("type") == "urltest")
        self.assertNotIn("node-1", urltest_after["outbounds"], "Previously removed candidate must NEVER be re-added on silence")

        # Step 3: probe returns verified alive=True with protocol response -> node-1 restored!
        def mock_probe_alive(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=25.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_alive), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_alive):
            health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        cfg_restored = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest_restored = next(g for g in cfg_restored["outbounds"] if g.get("type") == "urltest")
        self.assertIn("node-1", urltest_restored["outbounds"], "Candidate must be restored on verified alive response")

    def test_persistent_failure_deactivates_but_preserves_membership(self):
        """Two consecutive failures deactivate candidate from active outbounds, but candidate list is preserved."""
        cfg = self.create_mock_pool_config(node_count=4)
        self.write_config(cfg)

        # Run 1: node-1 fails
        def mock_probe_fail_node1(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            if tag == "node-1":
                return health.ProbeResult(tag=tag, alive=False, error="timeout")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=50.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_fail_node1), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_fail_node1):
            health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        # Run 2: node-1 fails again -> reaches threshold 2
        with patch.object(health, "probe_outbound", side_effect=mock_probe_fail_node1), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_fail_node1):
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        updated_cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest = next(g for g in updated_cfg["outbounds"] if g.get("type") == "urltest")
        # node-1 should now be removed from active outbounds
        self.assertNotIn("node-1", urltest["outbounds"], "node-1 must be deactivated after reaching threshold")
        self.assertEqual(summary["dead"], 1)
        self.assertEqual(summary["dead_tags"], ["node-1"])

        # But candidate membership in state MUST still include node-1!
        state = health.load_pool_state(self.state_path)
        self.assertIn("node-1", state["candidates"]["rg-all"], "node-1 must remain a registered candidate in state")

    def test_automatic_readd_upon_recovery(self):
        """When a deactivated node recovers, it must be automatically re-added to active outbounds."""
        cfg = self.create_mock_pool_config(node_count=4)
        self.write_config(cfg)

        # Run 1 & 2: node-1 fails twice
        def mock_probe_fail(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            if tag == "node-1":
                return health.ProbeResult(tag=tag, alive=False, error="timeout")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=50.0)

        for _ in range(2):
            with patch.object(health, "probe_outbound", side_effect=mock_probe_fail), \
                 patch.object(health, "probe_candidate_http", side_effect=mock_probe_fail):
                health.run_health_check(
                    config_path=str(self.config_path),
                    state_path=str(self.state_path),
                    fail_threshold=2,
                )

        cfg_after_fail = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest_fail = next(g for g in cfg_after_fail["outbounds"] if g.get("type") == "urltest")
        self.assertNotIn("node-1", urltest_fail["outbounds"])

        # Run 3: node-1 recovers and is alive again!
        def mock_probe_all_alive(outbound, timeout=2.5, own_hosts=None, **kwargs):
            tag = outbound.get("tag")
            return health.ProbeResult(tag=tag, alive=True, latency_ms=30.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_all_alive), \
             patch.object(health, "probe_candidate_http", side_effect=mock_probe_all_alive):
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
            )

        cfg_recovered = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest_rec = next(g for g in cfg_recovered["outbounds"] if g.get("type") == "urltest")
        # node-1 MUST be restored!
        self.assertIn("node-1", urltest_rec["outbounds"], "Recovered candidate must be automatically re-added")
        self.assertEqual(summary["dead"], 0)
        self.assertEqual(summary["changed"], True)

        state = health.load_pool_state(self.state_path)
        self.assertEqual(state["fail_counts"].get("node-1"), 0)


class ForbiddenHostDefenseTest(BaseSandboxTestCase):
    """Verifies that VPS own server IP (5.175.188.152) and *.zxc1x1.ru are strictly excluded."""

    def test_is_forbidden_host_classification(self):
        """Direct check of host classification logic."""
        self.assertTrue(health.is_forbidden_host("5.175.188.152"))
        self.assertTrue(health.is_forbidden_host("sub.zxc1x1.ru"))
        self.assertTrue(health.is_forbidden_host("panel.zxc1x1.ru"))
        self.assertTrue(health.is_forbidden_host("zxc1x1.ru"))
        self.assertTrue(health.is_forbidden_host("node1.zxc1x1.ru"))
        self.assertTrue(health.is_forbidden_host("nested.sub.zxc1x1.ru"))
        self.assertTrue(health.is_forbidden_host(None))
        self.assertTrue(health.is_forbidden_host(""))
        self.assertTrue(health.is_forbidden_host("   "))

        # Valid third-party hosts
        self.assertFalse(health.is_forbidden_host("8.8.8.8"))
        self.assertFalse(health.is_forbidden_host("vpn.example.com"))
        self.assertFalse(health.is_forbidden_host("node.cloudflare.com"))

    def test_forbidden_hosts_purged_from_pool_config(self):
        """Any forbidden host present in candidate outbounds must be permanently purged."""
        cfg = self.create_mock_pool_config(node_count=3, include_forbidden=True)
        self.write_config(cfg)

        probed_tags = []

        def mock_probe_tracker(outbound, timeout=2.5, own_hosts=None):
            tag = outbound.get("tag")
            probed_tags.append(tag)
            return health.ProbeResult(tag=tag, alive=True, latency_ms=25.0)

        with patch.object(health, "probe_outbound", side_effect=mock_probe_tracker):
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
            )

        # 1. Forbidden nodes must never be probed
        self.assertNotIn("forbidden-vps-ip", probed_tags)
        self.assertNotIn("forbidden-subdomain", probed_tags)
        self.assertNotIn("forbidden-wildcard", probed_tags)

        # 2. Forbidden nodes must be purged from urltest groups
        updated_cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
        urltest = next(g for g in updated_cfg["outbounds"] if g.get("type") == "urltest")
        for forbidden in ["forbidden-vps-ip", "forbidden-subdomain", "forbidden-wildcard"]:
            self.assertNotIn(forbidden, urltest["outbounds"])

        # 3. State must not have forbidden tags
        state = health.load_pool_state(self.state_path)
        for cand_list in state["candidates"].values():
            for forbidden in ["forbidden-vps-ip", "forbidden-subdomain", "forbidden-wildcard"]:
                self.assertNotIn(forbidden, cand_list)

        self.assertEqual(summary["forbidden_purged"], 3)


class MultiProtocolProbeTest(BaseSandboxTestCase):
    """Verifies TCP and UDP probing mechanism and error handling."""

    def test_probe_tcp_open_and_closed(self):
        """Test TCP probe against local open port vs closed port."""
        # Setup temporary local TCP listener
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", 0))
        open_port = server.getsockname()[1]
        server.listen(1)

        def accept_conn():
            try:
                conn, _ = server.accept()
                conn.close()
            except Exception:
                pass

        t = threading.Thread(target=accept_conn)
        t.start()

        try:
            ok, rtt, err = health.probe_tcp("127.0.0.1", open_port, timeout=1.0)
            self.assertTrue(ok)
            self.assertIsNotNone(rtt)
            self.assertIsNone(err)
        finally:
            server.close()
            t.join()

        # Closed port test
        ok_closed, rtt_closed, err_closed = health.probe_tcp("127.0.0.1", 59981, timeout=0.3)
        self.assertFalse(ok_closed)
        self.assertIsNone(rtt_closed)
        self.assertIsNotNone(err_closed)

    def test_probe_udp_silent_socket_regression(self):
        """Regression test: real local UDP socket that receives but stays silent returns unknown (None), no fake RTT."""
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("127.0.0.1", 0))
        silent_port = server.getsockname()[1]

        try:
            # Direct probe_udp on silent socket
            alive, rtt, err, caveat = health.probe_udp("127.0.0.1", silent_port, timeout=0.2)
            self.assertIsNone(alive, "UDP silence must return unknown (alive=None), not True")
            self.assertIsNone(rtt, "UDP silence must NOT report fake RTT latency")
            self.assertIn("udp_silence_timeout", err)
            self.assertEqual(caveat, "unverified_udp_silence")

            # Via probe_outbound
            ob = {
                "type": "hysteria2",
                "tag": "node-silent-hy2",
                "server": "127.0.0.1",
                "server_port": silent_port,
            }
            res = health.probe_outbound(ob, timeout=0.2)
            self.assertIsNone(res.alive, "ProbeResult.alive must be None on UDP silence")
            self.assertIsNone(res.latency_ms)
            self.assertEqual(res.caveat, "unverified_udp_silence")
        finally:
            server.close()

    def test_probe_udp_actual_response_verified(self):
        """When UDP target responds with datagram, alive is None (unknown; arbitrary datagram is not verified proxy) with caveat."""
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("127.0.0.1", 0))
        active_port = server.getsockname()[1]

        def echo_worker():
            try:
                server.settimeout(1.0)
                data, addr = server.recvfrom(64)
                if addr:
                    server.sendto(b"QUIC_RESP", addr)
            except Exception:
                pass

        t = threading.Thread(target=echo_worker)
        t.start()

        try:
            alive, rtt, err, caveat = health.probe_udp("127.0.0.1", active_port, timeout=0.5)
            self.assertIsNone(alive, "Generic UDP response must be UNKNOWN (alive=None), not True")
            self.assertIsNotNone(rtt)
            self.assertIsNone(err)
            self.assertEqual(caveat, "unverified_generic_udp_response")
        finally:
            server.close()
            t.join()

    def test_probe_udp_hysteria_protocol_dispatch(self):
        """Outbounds with protocol hysteria/hysteria2 dispatch to UDP probe."""
        outbound_hysteria = {
            "type": "hysteria2",
            "tag": "node-hy2",
            "server": "8.8.8.8",
            "server_port": 53,
        }

        with patch.object(health, "probe_udp", return_value=(None, 24.5, None, "unverified_generic_udp_response")) as mock_udp:
            res = health.probe_outbound(outbound_hysteria)
            mock_udp.assert_called_once_with("8.8.8.8", 53, timeout=health.DEFAULT_TIMEOUT)
            self.assertIsNone(res.alive)
            self.assertEqual(res.protocol, "udp")
            self.assertEqual(res.caveat, "unverified_generic_udp_response")


class SafetyAndHarmonizationTest(BaseSandboxTestCase):
    """Verifies URLTest harmonization, non-empty group safety, and service restart."""

    def test_urltest_group_harmonization(self):
        """Group interval, idle_timeout, tolerance, and interrupt_exist_connections enforced."""
        cfg = self.create_mock_pool_config(node_count=2)
        # Ensure values differ
        urltest = next(g for g in cfg["outbounds"] if g.get("type") == "urltest")
        urltest["interval"] = "1m"
        urltest["tolerance"] = 999
        urltest["interrupt_exist_connections"] = True
        self.write_config(cfg)

        with patch.object(health, "probe_outbound", return_value=health.ProbeResult("tag", True, 20.0)):
            health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
            )

        updated = json.loads(self.config_path.read_text(encoding="utf-8"))
        group = next(g for g in updated["outbounds"] if g.get("type") == "urltest")
        self.assertEqual(group["interval"], "3m")
        self.assertEqual(group["idle_timeout"], "10m")
        self.assertEqual(group["tolerance"], 50)
        self.assertEqual(group["interrupt_exist_connections"], False)

    def test_empty_group_protection(self):
        """If all candidates fail, urltest group refuses to empty out completely."""
        cfg = self.create_mock_pool_config(node_count=3)
        self.write_config(cfg)

        # All nodes fail
        with patch.object(health, "probe_outbound", side_effect=lambda ob, **kw: health.ProbeResult(ob.get("tag"), False, error="offline")):
            # Run multiple times to exceed threshold
            for _ in range(3):
                health.run_health_check(
                    config_path=str(self.config_path),
                    state_path=str(self.state_path),
                    fail_threshold=2,
                )

        updated = json.loads(self.config_path.read_text(encoding="utf-8"))
        group = next(g for g in updated["outbounds"] if g.get("type") == "urltest")
        self.assertGreater(len(group["outbounds"]), 0, "Group must never be completely emptied out")

    def test_service_restart_invoked_on_change(self):
        """Service restart called when config changes and restart_service is True."""
        cfg = self.create_mock_pool_config(node_count=2)
        self.write_config(cfg)

        with patch.object(health, "probe_outbound", return_value=health.ProbeResult("tag", True, 10.0)):
            with patch.object(health, "restart_pool_service", return_value=True) as mock_restart:
                health.run_health_check(
                    config_path=str(self.config_path),
                    state_path=str(self.state_path),
                    restart_service=True,
                )
                mock_restart.assert_called_once_with(service_name="sing-box-pool")

    def test_service_restart_not_invoked_when_no_change(self):
        """Service restart NOT called when config remains identical."""
        cfg = self.create_mock_pool_config(node_count=2)
        # Harmonize in advance
        urltest = next(g for g in cfg["outbounds"] if g.get("type") == "urltest")
        urltest.update(health.HARMONIZED_GROUP_SETTINGS)
        self.write_config(cfg)

        with patch.object(health, "probe_outbound", return_value=health.ProbeResult("tag", True, 10.0)):
            # First run initializes state
            health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                restart_service=False,
            )

        with patch.object(health, "probe_outbound", return_value=health.ProbeResult("tag", True, 10.0)):
            with patch.object(health, "restart_pool_service") as mock_restart:
                summary = health.run_health_check(
                    config_path=str(self.config_path),
                    state_path=str(self.state_path),
                    restart_service=True,
                )
                self.assertFalse(summary["changed"])
                mock_restart.assert_not_called()

    def test_singbox_validation_fail_closed_by_default(self):
        """Sing-box validation must fail closed by default if binary does not exist."""
        os.environ.pop("MOSAIC_ALLOW_MISSING_SINGBOX", None)
        dummy_file = self.sandbox_dir / "test_cfg.json"
        dummy_file.write_text("{}", encoding="utf-8")

        with self.assertRaises(FileNotFoundError):
            health.validate_singbox_config(
                str(dummy_file),
                sing_box_bin="/non/existent/sing-box",
                allow_missing_singbox=False,
            )

    def test_singbox_validation_test_override(self):
        """When test override is provided, fallback to JSON validation succeeds on valid JSON, fails on invalid."""
        dummy_file = self.sandbox_dir / "valid.json"
        dummy_file.write_text('{"log": {"level": "info"}}', encoding="utf-8")

        ok = health.validate_singbox_config(
            str(dummy_file),
            sing_box_bin="/non/existent/sing-box",
            allow_missing_singbox=True,
        )
        self.assertTrue(ok)

        bad_file = self.sandbox_dir / "bad.json"
        bad_file.write_text('{invalid json syntax', encoding="utf-8")
        with self.assertRaises(ValueError):
            health.validate_singbox_config(
                str(bad_file),
                sing_box_bin="/non/existent/sing-box",
                allow_missing_singbox=True,
            )

    def test_service_restart_failure_raises_and_rolls_back_config(self):
        """If service restart fails, run_health_check raises RuntimeError and rolls back config to original content."""
        cfg = self.create_mock_pool_config(node_count=3)
        # Give urltest an old non-harmonized interval to ensure change is triggered
        urltest = next(g for g in cfg["outbounds"] if g.get("type") == "urltest")
        urltest["interval"] = "1m"
        self.write_config(cfg)
        original_bytes = self.config_path.read_bytes()

        with patch.object(health, "probe_outbound", return_value=health.ProbeResult("tag", True, 15.0)):
            with patch.object(health, "restart_pool_service", side_effect=RuntimeError("systemctl failed to start")):
                with self.assertRaises(RuntimeError) as cm:
                    health.run_health_check(
                        config_path=str(self.config_path),
                        state_path=str(self.state_path),
                        restart_service=True,
                    )
                self.assertIn("config rolled back", str(cm.exception))

        # Check that config was restored to original content!
        restored_bytes = self.config_path.read_bytes()
        self.assertEqual(restored_bytes, original_bytes, "Config must be rolled back on restart failure")

    def test_pool_config_lock_mutual_exclusion(self):
        """Config lock prevents concurrent modification via mutual exclusion."""
        lock_file = self.sandbox_dir / "test_pool.lock"

        with health.pool_config_lock(lock_file, timeout=1.0):
            # Attempting to acquire again with low timeout must raise TimeoutError
            with self.assertRaises(TimeoutError):
                with health.pool_config_lock(lock_file, timeout=0.2):
                    pass

        # After releasing, acquiring again must succeed
        acquired = False
        with health.pool_config_lock(lock_file, timeout=0.5):
            acquired = True
        self.assertTrue(acquired)


class RealSocketMembershipBoundaryRegressionTest(BaseSandboxTestCase):
    """Regressions with real local sockets proving transport-only TCP and generic UDP cannot re-add or reset failures."""

    def test_regression_real_tcp_accepting_socket_cannot_readd_or_reset_failures(self):
        """Real local TCP accepting socket proves transport-only connect is UNKNOWN: cannot re-add or reset failures."""
        # 1. Start a real listening TCP server socket
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", 0))
        server_port = server.getsockname()[1]
        server.listen(10)
        stop_event = threading.Event()

        def accept_loop():
            while not stop_event.is_set():
                try:
                    server.settimeout(0.2)
                    conn, _ = server.accept()
                    conn.close()
                except (socket.timeout, OSError):
                    pass

        t = threading.Thread(target=accept_loop)
        t.daemon = True
        t.start()

        try:
            # 2. Configure pool with active candidate and previously removed candidate
            config = {
                "log": {"level": "warning"},
                "inbounds": [{"type": "socks", "tag": "in-socks", "listen": "127.0.0.1", "listen_port": 10080}],
                "outbounds": [
                    {
                        "type": "vless",
                        "tag": "tcp-active",
                        "server": "127.0.0.1",
                        "server_port": server_port,
                    },
                    {
                        "type": "vless",
                        "tag": "tcp-removed",
                        "server": "127.0.0.1",
                        "server_port": server_port,
                    },
                    {
                        "type": "urltest",
                        "tag": "rg-all",
                        "outbounds": ["tcp-active"],  # tcp-removed is NOT in active outbounds!
                        "url": "https://www.gstatic.com/generate_204",
                    },
                    {"type": "direct", "tag": "direct"},
                ],
            }
            self.write_config(config)

            # Pre-seed persistent state: tcp-removed has 2 failures (reached threshold)
            state = {
                "version": 1,
                "candidates": {"rg-all": ["tcp-active", "tcp-removed"]},
                "fail_counts": {"tcp-active": 0, "tcp-removed": 2},
            }
            health.save_pool_state(self.state_path, state)

            # 3. Run real health check against the real accepting TCP socket
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
                verify_http=False,
            )

            # 4. Verify membership decision boundary enforcement:
            updated_state = health.load_pool_state(self.state_path)
            updated_cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
            urltest = next(g for g in updated_cfg["outbounds"] if g.get("type") == "urltest")

            # A) Failures must NOT be reset to 0 by transport-only TCP connect
            self.assertEqual(
                updated_state["fail_counts"].get("tcp-removed"),
                2,
                "TCP transport connection must NOT reset failure counts",
            )

            # B) Previously removed candidate must NOT be re-added to active outbounds
            self.assertNotIn(
                "tcp-removed",
                urltest["outbounds"],
                "TCP transport connection must NOT re-add a previously removed candidate",
            )

            # C) Existing active candidate must remain active (membership preserved on unknown)
            self.assertIn(
                "tcp-active",
                urltest["outbounds"],
                "Existing active candidate must be preserved when transport succeeds",
            )
            self.assertEqual(
                updated_state["fail_counts"].get("tcp-active", 0),
                0,
                "Active candidate failure count remains 0",
            )

            # D) Probe result is classified as unknown in summary
            self.assertGreaterEqual(summary["total_unknown"], 1)
        finally:
            stop_event.set()
            server.close()
            t.join(timeout=1.0)

    def test_regression_real_udp_echo_socket_cannot_readd_or_reset_failures(self):
        """Real local UDP echo socket proves generic datagram response is UNKNOWN: cannot re-add or reset failures."""
        # 1. Start a real UDP echo server socket
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("127.0.0.1", 0))
        echo_port = server.getsockname()[1]
        stop_event = threading.Event()

        def udp_echo_loop():
            while not stop_event.is_set():
                try:
                    server.settimeout(0.2)
                    data, addr = server.recvfrom(64)
                    if addr:
                        server.sendto(b"GENERIC_DATAGRAM_ECHO_DATA", addr)
                except (socket.timeout, OSError):
                    pass

        t = threading.Thread(target=udp_echo_loop)
        t.daemon = True
        t.start()

        try:
            # 2. Configure pool with active candidate and previously removed candidate (UDP / Hysteria2)
            config = {
                "log": {"level": "warning"},
                "inbounds": [{"type": "socks", "tag": "in-socks", "listen": "127.0.0.1", "listen_port": 10080}],
                "outbounds": [
                    {
                        "type": "hysteria2",
                        "tag": "udp-active",
                        "server": "127.0.0.1",
                        "server_port": echo_port,
                        "password": "mock_password",
                        "tls": {"enabled": True, "server_name": "example.com", "insecure": True},
                    },
                    {
                        "type": "hysteria2",
                        "tag": "udp-removed",
                        "server": "127.0.0.1",
                        "server_port": echo_port,
                        "password": "mock_password",
                        "tls": {"enabled": True, "server_name": "example.com", "insecure": True},
                    },
                    {
                        "type": "urltest",
                        "tag": "rg-all",
                        "outbounds": ["udp-active"],  # udp-removed is NOT in active outbounds!
                        "url": "https://www.gstatic.com/generate_204",
                    },
                    {"type": "direct", "tag": "direct"},
                ],
            }
            self.write_config(config)

            # Pre-seed state: udp-removed has 2 failures (reached threshold)
            state = {
                "version": 1,
                "candidates": {"rg-all": ["udp-active", "udp-removed"]},
                "fail_counts": {"udp-active": 0, "udp-removed": 2},
            }
            health.save_pool_state(self.state_path, state)

            # 3. Run real health check against the real UDP echo socket
            summary = health.run_health_check(
                config_path=str(self.config_path),
                state_path=str(self.state_path),
                fail_threshold=2,
                verify_http=False,
            )

            # 4. Verify membership decision boundary enforcement:
            updated_state = health.load_pool_state(self.state_path)
            updated_cfg = json.loads(self.config_path.read_text(encoding="utf-8"))
            urltest = next(g for g in updated_cfg["outbounds"] if g.get("type") == "urltest")

            # A) Failures must NOT be reset by generic UDP datagram response
            self.assertEqual(
                updated_state["fail_counts"].get("udp-removed"),
                2,
                "Generic UDP datagram response must NOT reset failure counts",
            )

            # B) Previously removed candidate must NOT be re-added to active outbounds
            self.assertNotIn(
                "udp-removed",
                urltest["outbounds"],
                "Generic UDP datagram response must NOT re-add a previously removed candidate",
            )

            # C) Existing active candidate must remain active
            self.assertIn(
                "udp-active",
                urltest["outbounds"],
                "Existing active candidate must remain active when generic UDP responds",
            )
            self.assertEqual(
                updated_state["fail_counts"].get("udp-active", 0),
                0,
                "Active candidate failure count remains 0",
            )

            # D) Probe result is classified as unknown in summary
            self.assertGreaterEqual(summary["total_unknown"], 1)
        finally:
            stop_event.set()
            server.close()
            t.join(timeout=1.0)

    def test_regression_real_socket_verified_failure_detection_prunes(self):
        """Verified socket failure (connection refused on closed port) accumulates and prunes candidate."""
        # Find an unused port
        temp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        temp_sock.bind(("127.0.0.1", 0))
        closed_port = temp_sock.getsockname()[1]
        temp_sock.close()

        config = {
            "log": {"level": "warning"},
            "inbounds": [{"type": "socks", "tag": "in-socks", "listen": "127.0.0.1", "listen_port": 10080}],
            "outbounds": [
                {
                    "type": "vless",
                    "tag": "node-dead",
                    "server": "127.0.0.1",
                    "server_port": closed_port,
                },
                {
                    "type": "urltest",
                    "tag": "rg-all",
                    "outbounds": ["node-dead"],
                    "url": "https://www.gstatic.com/generate_204",
                },
                {"type": "direct", "tag": "direct"},
            ],
        }
        self.write_config(config)

        # Pre-seed state with 1 failure
        state = {
            "version": 1,
            "candidates": {"rg-all": ["node-dead"]},
            "fail_counts": {"node-dead": 1},
        }
        health.save_pool_state(self.state_path, state)

        # Run health check against closed port -> failure count increments to 2
        summary = health.run_health_check(
            config_path=str(self.config_path),
            state_path=str(self.state_path),
            fail_threshold=2,
        )

        updated_state = health.load_pool_state(self.state_path)
        self.assertEqual(
            updated_state["fail_counts"].get("node-dead"),
            2,
            "Connection refused must increment failure count to 2",
        )
        self.assertEqual(summary["dead"], 1)
        self.assertEqual(summary["total_failures"], 1)


if __name__ == "__main__":
    unittest.main()
