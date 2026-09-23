"""test_pool_collector.py — Adversarial Regression & Unit Tests for mosaic_pool_collector.py.

Verifies:
1. Canonical fingerprint: tag-insensitive, remarks/name-insensitive, key-order invariant, SHA-256 formatting.
2. Reject own and private host: VPS own IPs/domains, subdomains, RFC1918, loopback, IPv6 ULA/link-local, localhost, single-label.
3. Malformed URI line isolation: multi-line feeds with corrupt URIs never crash parsing of valid lines.
4. Tiny stratify hard cap: total_limit bounds (0, 1, 10, 80, negative) strictly enforced without overflow.
5. UDP vs TCP gate behavior: Hysteria/Hysteria2 bypasses TCP probe and is not gated out by TCP failure.
6. Proxy probe curl invocation: exact HTTP 204 requirement, remote time_total latency extraction, process cleanup.
7. Missing sing-box: raises infrastructure RuntimeError instead of recording false negative health.
8. Unknown throughput remains None: failed stage 2 leaves speed_mbps=None without fabricated default bandwidth.
9. ICMP loss probe: loss_pct correctly reflects packet_loss percentage (0.0 to 100.0, not inverted).
10. Database upsert logic: unknown health (proxy_ok is None) preserved; upsert query integrity verified.
11. Real local TCP & SOCKS5 tests: genuine in-process server tests without mocked sockets or fake claims.
"""

import base64
import contextlib
import http.server
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import types
from typing import Any, Dict, List, Optional
import unittest
from unittest.mock import MagicMock, call, patch

# Ensure psycopg2 mock fallback if run in environments lacking psycopg2
if "psycopg2" not in sys.modules:
    try:
        import psycopg2
        import psycopg2.extras
    except ImportError:
        psycopg2 = types.ModuleType("psycopg2")
        extras = types.ModuleType("psycopg2.extras")
        extras.Json = lambda value: value
        psycopg2.extras = extras
        sys.modules["psycopg2"] = psycopg2
        sys.modules["psycopg2.extras"] = extras

# Dynamic loader for mosaic_pool_collector
MODULE_PATH = Path(__file__).with_name("mosaic_pool_collector.py")
if not MODULE_PATH.exists():
    MODULE_PATH = Path(__file__).parent / "mosaic_pool_collector.py"
spec = importlib.util.spec_from_file_location("mosaic_pool_collector", MODULE_PATH)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


# ── Helper for Creating Sample Nodes ──────────────────────────────────────────

def make_node(**overrides) -> collector.Node:
    defaults = {
        "source_name": "test-feed",
        "source_url": "https://feed.example.com/subs",
        "country_code": "DE",
        "protocol": "vless",
        "address": "93.184.216.34",
        "port": 443,
        "config": {
            "type": "vless",
            "server": "93.184.216.34",
            "server_port": 443,
            "uuid": "11111111-2222-3333-4444-555555555555",
            "tag": "mosaic-orig",
        },
        "fingerprint": "a" * 64,
        "tcp_ok": None,
        "latency_ms": None,
        "jitter_ms": None,
        "loss_pct": None,
        "proxy_ok": None,
        "exit_country_code": None,
        "speed_mbps": None,
        "tls_ok": None,
        "composite_score": None,
        "success_rate": None,
    }
    defaults.update(overrides)
    return collector.Node(**defaults)


# ── 1. Canonical Fingerprint Tests ────────────────────────────────────────────

class CanonicalFingerprintTest(unittest.TestCase):
    """Verifies fingerprinting is tag/remarks/name insensitive, key-order invariant, and SHA-256."""

    def test_tag_insensitivity(self):
        c1 = {"type": "vless", "server": "93.184.216.34", "server_port": 443, "uuid": "abc", "tag": "proxy-1"}
        c2 = {"type": "vless", "server": "93.184.216.34", "server_port": 443, "uuid": "abc", "tag": "proxy-2"}
        self.assertEqual(collector.fingerprint(c1), collector.fingerprint(c2))

    def test_remarks_and_name_insensitivity(self):
        c_clean = {"type": "trojan", "server": "93.184.216.34", "server_port": 443, "password": "pass"}
        c_annotated = {
            "type": "trojan",
            "server": "93.184.216.34",
            "server_port": 443,
            "password": "pass",
            "tag": "custom-tag-123",
            "remarks": "Free Fast German Node",
            "name": "Node-DE-Fast",
        }
        self.assertEqual(collector.fingerprint(c_clean), collector.fingerprint(c_annotated))

    def test_key_order_invariance(self):
        c1 = {"type": "shadowsocks", "server": "8.8.8.8", "server_port": 8388, "method": "aes-128-gcm", "password": "p"}
        c2 = {"password": "p", "server_port": 8388, "type": "shadowsocks", "method": "aes-128-gcm", "server": "8.8.8.8"}
        self.assertEqual(collector.fingerprint(c1), collector.fingerprint(c2))

    def test_nested_dict_key_order_invariance(self):
        c1 = {
            "type": "vless", "server": "8.8.8.8", "server_port": 443,
            "tls": {"enabled": True, "server_name": "example.com", "insecure": False}
        }
        c2 = {
            "tls": {"server_name": "example.com", "insecure": False, "enabled": True},
            "server_port": 443, "type": "vless", "server": "8.8.8.8",
            "tag": "different-tag"
        }
        self.assertEqual(collector.fingerprint(c1), collector.fingerprint(c2))

    def test_different_parameters_produce_different_fingerprints(self):
        base = {"type": "vless", "server": "93.184.216.34", "server_port": 443, "uuid": "abc"}
        diff_host = dict(base, server="93.184.216.35")
        diff_port = dict(base, server_port=8443)
        diff_uuid = dict(base, uuid="xyz")
        diff_proto = dict(base, type="trojan")

        fps = {
            collector.fingerprint(base),
            collector.fingerprint(diff_host),
            collector.fingerprint(diff_port),
            collector.fingerprint(diff_uuid),
            collector.fingerprint(diff_proto),
        }
        self.assertEqual(len(fps), 5, "Every core configuration change must yield a unique fingerprint")

    def test_fingerprint_is_valid_sha256_hex(self):
        c = {"type": "vless", "server": "1.2.3.4", "server_port": 443}
        fp = collector.fingerprint(c)
        self.assertEqual(len(fp), 64)
        self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", fp))


# ── 2. Reject Own and Private Host Tests ──────────────────────────────────────

class RejectForbiddenHostTest(unittest.TestCase):
    """Verifies strict rejection of VPS own IPs/domains, private IP ranges, and local hostnames."""

    def test_empty_or_none_is_forbidden(self):
        self.assertTrue(collector.is_forbidden_host(""))
        self.assertTrue(collector.is_forbidden_host(None))
        self.assertTrue(collector.is_forbidden_host("   "))

    def test_vps_own_hosts_rejected(self):
        for own in collector.OWN_HOSTS:
            self.assertTrue(collector.is_forbidden_host(own), f"Must reject own host: {own}")
            self.assertTrue(collector.is_forbidden_host(f"sub.{own}"), f"Must reject subdomain: sub.{own}")
            self.assertTrue(collector.is_forbidden_host(f"deep.sub.{own}"), f"Must reject nested subdomain: deep.sub.{own}")
            self.assertTrue(collector.is_forbidden_host(own.upper()), f"Must reject uppercase: {own.upper()}")
            self.assertTrue(collector.is_forbidden_host(f"{own}."), f"Must reject trailing dot: {own}.")

    def test_private_ipv4_addresses_rejected(self):
        private_ips = [
            "127.0.0.1", "127.0.1.1",     # Loopback
            "10.0.0.1", "10.254.1.1",     # Class A private
            "172.16.0.1", "172.31.255.1", # Class B private
            "192.168.0.1", "192.168.1.50",# Class C private
            "169.254.1.1",                # Link-local / metadata service
            "0.0.0.0", "255.255.255.255", # Broadcast/Unspecified
            "100.64.0.1", "100.127.255.2",# CGNAT (non-global)
        ]
        for ip in private_ips:
            self.assertTrue(collector.is_forbidden_host(ip), f"Must reject private/non-global IPv4: {ip}")

    def test_private_ipv6_addresses_rejected(self):
        non_global_ipv6 = [
            "::1",          # Loopback
            "::",           # Unspecified
            "fc00::1",      # Unique local
            "fd12:3456::1", # Unique local
            "fe80::1",      # Link-local
        ]
        for ip6 in non_global_ipv6:
            self.assertTrue(collector.is_forbidden_host(ip6), f"Must reject private/non-global IPv6: {ip6}")

    def test_local_hostnames_rejected(self):
        local_hosts = [
            "localhost",
            "localhost.",
            "foo.localhost",
            "gateway.local",
            "service.internal",
            "router",       # Single label (no dot)
            "myhostname",   # Single label (no dot)
        ]
        for h in local_hosts:
            self.assertTrue(collector.is_forbidden_host(h), f"Must reject local hostname: {h}")

    def test_legitimate_global_hosts_allowed(self):
        public_hosts = [
            "1.1.1.1",
            "8.8.8.8",
            "93.184.216.34",
            "node01.vpn-provider.com",
            "de-proxy.fastnetwork.org",
            "singbox.community.net",
            "notzxc1x1.ru",
            "zxc1x1.ru.com",
        ]
        for h in public_hosts:
            self.assertFalse(collector.is_forbidden_host(h), f"Must allow public host: {h}")

    def test_node_from_singbox_rejects_forbidden_host(self):
        forbidden_outbound = {
            "type": "vless",
            "server": "5.175.188.152",
            "server_port": 443,
            "uuid": "abc",
        }
        self.assertIsNone(collector.node_from_singbox("src", "https://src.test", "DE", forbidden_outbound))

        private_outbound = {
            "type": "trojan",
            "server": "192.168.1.10",
            "server_port": 443,
            "password": "pass",
        }
        self.assertIsNone(collector.node_from_singbox("src", "https://src.test", "DE", private_outbound))

    def test_node_from_singbox_rejects_unsafe_keys_and_paths(self):
        for unsafe_key in ["detour", "bind_interface", "routing_mark", "protect_path"]:
            outbound = {
                "type": "vless",
                "server": "1.1.1.1",
                "server_port": 443,
                "uuid": "abc",
                unsafe_key: "forbidden_val",
            }
            self.assertIsNone(collector.node_from_singbox("src", "https://src.test", "DE", outbound))

        tls_path_outbound = {
            "type": "vless",
            "server": "1.1.1.1",
            "server_port": 443,
            "uuid": "abc",
            "tls": {"enabled": True, "certificate_path": "/etc/shadow"},
        }
        self.assertIsNone(collector.node_from_singbox("src", "https://src.test", "DE", tls_path_outbound))


# ── 3. Malformed URI Line Isolation Tests ────────────────────────────────────

class MalformedUriLineIsolationTest(unittest.TestCase):
    """Verifies that malformed or garbage lines in subscription feeds never abort valid lines."""

    def test_mixed_feed_isolates_malformed_lines(self):
        feed_lines = [
            "# Header comment",
            "vless://00000000-0000-0000-0000-000000000001@93.184.216.34:443?security=tls&sni=example.com#DE-Frankfurt",
            "not-a-uri",
            "vless://",
            "://no-scheme",
            "vless://corrupt-host-syntax:notaport",
            "vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443#ForbiddenLocalhost",
            "trojan://mysecretpassword@8.8.8.8:443?sni=example.org#US-NewYork",
            "ss://invalid_base64_payload_here",
            "ss://YWVzLTEyOC1nY206c2VjcmV0@1.1.1.1:8388#NL-Amsterdam",
            "   ",
            "splithttp://unsupported@1.1.1.1:443",
        ]
        body = "\n".join(feed_lines)
        nodes = collector._parse_nodes("test-source", "https://example.com/feed", None, body)

        self.assertEqual(len(nodes), 3)
        protocols = [n.protocol for n in nodes]
        self.assertEqual(protocols, ["vless", "trojan", "shadowsocks"])
        self.assertEqual(nodes[0].country_code, "DE")
        self.assertEqual(nodes[1].country_code, "US")
        self.assertEqual(nodes[2].country_code, "NL")

    def test_base64_encoded_feed_with_malformed_lines(self):
        raw_feed = (
            "vless://11111111-1111-1111-1111-111111111111@93.184.216.34:443?security=tls#FR-Paris\n"
            "garbage_line_here\n"
            "trojan://mypass@8.8.8.8:443#CA-Toronto\n"
        )
        encoded = base64.b64encode(raw_feed.encode("utf-8")).decode("utf-8")
        nodes = collector._parse_nodes("b64-src", "https://example.com/sub", None, encoded)
        self.assertEqual(len(nodes), 2)
        self.assertEqual(nodes[0].country_code, "FR")
        self.assertEqual(nodes[1].country_code, "CA")

    def test_adversarial_uri_strings_safely_isolated(self):
        adversarial_feed = [
            "vless://[::1:443",
            "trojan://pass@example.com:999999",
            "ss://@@@:abc",
            "vless://" + "a" * 10000,
            "vless://uuid@zxc1x1.ru:443",
            "vless://uuid@5.175.188.152:443",
            "vless://22222222-2222-2222-2222-222222222222@93.184.216.34:443?security=tls#ValidNode",
        ]
        nodes = collector._parse_nodes("test", "http://test", "DE", "\n".join(adversarial_feed))
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0].address, "93.184.216.34")


# ── 4. Tiny Stratify Hard Cap Tests ──────────────────────────────────────────

class StratifyHardCapTest(unittest.TestCase):
    """Verifies that stratify_candidates strictly honors hard cap limits (0, 1, 10, 80, negative)."""

    def setUp(self):
        self.mock_nodes = []
        countries = ["DE", "NL", "US", "FR", "CA", "GB", "FI", "PL", "SG", "JP", "RU", "AU", "OTHER"]
        idx = 0
        for cc in countries:
            for i in range(15):
                idx += 1
                fp = f"{idx:04x}" * 16
                node = make_node(
                    country_code=cc,
                    address=f"93.184.216.{idx % 200 + 1}",
                    fingerprint=fp,
                )
                self.mock_nodes.append(node)

    def test_cap_zero(self):
        selected = collector.stratify_candidates(self.mock_nodes, total_limit=0)
        self.assertEqual(len(selected), 0)

    def test_cap_negative(self):
        selected = collector.stratify_candidates(self.mock_nodes, total_limit=-10)
        self.assertEqual(len(selected), 0)

    def test_cap_one(self):
        selected = collector.stratify_candidates(self.mock_nodes, total_limit=1)
        self.assertEqual(len(selected), 1)

    def test_cap_ten(self):
        selected = collector.stratify_candidates(self.mock_nodes, total_limit=10)
        self.assertEqual(len(selected), 10)

    def test_cap_eighty(self):
        selected = collector.stratify_candidates(self.mock_nodes, total_limit=80)
        self.assertEqual(len(selected), 80)

        selected_countries = {n.country_code for n in selected}
        self.assertGreaterEqual(len(selected_countries), 8, "Must represent wide array of countries")

    def test_cap_exceeds_pool_size(self):
        small_pool = self.mock_nodes[:5]
        selected = collector.stratify_candidates(small_pool, total_limit=80)
        self.assertEqual(len(selected), 5)

    def test_deduplication_by_fingerprint_preserves_country_code(self):
        fp = "e" * 64
        n_no_cc = make_node(fingerprint=fp, country_code=None)
        n_with_cc = make_node(fingerprint=fp, country_code="DE")

        selected = collector.stratify_candidates([n_no_cc, n_with_cc], total_limit=10)
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].country_code, "DE")


# ── 5. UDP vs TCP Gate Behavior Tests ─────────────────────────────────────────

class UdpTcpGateTest(unittest.TestCase):
    """Verifies that Hysteria/Hysteria2 protocols bypass TCP probing and are not gated out by TCP failures."""

    def test_tcp_probe_bypasses_hysteria(self):
        node_h1 = make_node(protocol="hysteria", tcp_ok=None, latency_ms=None)
        node_h2 = make_node(protocol="hysteria2", tcp_ok=None, latency_ms=None)

        with patch("socket.create_connection") as mock_conn:
            res1 = collector.tcp_probe(node_h1)
            res2 = collector.tcp_probe(node_h2)
            mock_conn.assert_not_called()

        self.assertIsNone(res1.tcp_ok, "Hysteria tcp_ok must remain None")
        self.assertIsNone(res2.tcp_ok, "Hysteria2 tcp_ok must remain None")
        self.assertIsNone(res1.latency_ms)
        self.assertIsNone(res2.latency_ms)

    def test_tcp_probe_performs_real_check_for_tcp_protocols(self):
        node_tcp = make_node(protocol="vless", address="93.184.216.34", port=443)

        with patch("socket.create_connection", side_effect=OSError("Connection refused")):
            res = collector.tcp_probe(node_tcp)
            self.assertFalse(res.tcp_ok)
            self.assertIsNone(res.latency_ms)

        with patch("socket.create_connection", return_value=MagicMock()):
            res = collector.tcp_probe(node_tcp)
            self.assertTrue(res.tcp_ok)
            self.assertIsNotNone(res.latency_ms)
            self.assertGreaterEqual(res.latency_ms, 1)

    def test_proxy_probe_gates_out_failed_tcp_nodes(self):
        tcp_failed_node = make_node(protocol="vless", tcp_ok=False, proxy_ok=None)
        with patch.object(Path, "exists", return_value=True), \
             patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen:
            res = collector.proxy_probe(tcp_failed_node)
            mock_run.assert_not_called()
            mock_popen.assert_not_called()
            self.assertIsNone(res.proxy_ok)

    def test_proxy_probe_does_not_gate_out_hysteria_with_false_or_none_tcp(self):
        h2_node = make_node(protocol="hysteria2", tcp_ok=None, proxy_ok=None)

        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"dummy singbox")
            dummy_singbox = f.name

        old_singbox = collector.SING_BOX
        collector.SING_BOX = dummy_singbox
        try:
            with patch("subprocess.run") as mock_run, \
                 patch("subprocess.Popen") as mock_popen, \
                 patch("time.sleep"):
                mock_run.side_effect = [
                    MagicMock(returncode=0, stdout=""),          # check
                    MagicMock(returncode=0, stdout="204|0.120"), # stage 1
                    MagicMock(returncode=0, stdout="200|800000"),# stage 2
                ]
                mock_proc = MagicMock()
                mock_proc.wait.return_value = 0
                mock_popen.return_value = mock_proc

                res = collector.proxy_probe(h2_node)
                self.assertTrue(res.proxy_ok)
                self.assertEqual(res.latency_ms, 120)
                self.assertGreaterEqual(mock_run.call_count, 2)
        finally:
            collector.SING_BOX = old_singbox
            Path(dummy_singbox).unlink(missing_ok=True)


# ── 6. Proxy Probe Curl & Subprocess Tests ────────────────────────────────────

class ProxyProbeSubprocessTest(unittest.TestCase):
    """Verifies proxy_probe requires exact HTTP 204, extracts time_total, and cleans up processes."""

    def setUp(self):
        self.tmp_file = tempfile.NamedTemporaryFile(delete=False)
        self.tmp_file.write(b"mock sing-box binary")
        self.tmp_file.close()
        self.old_singbox = collector.SING_BOX
        collector.SING_BOX = self.tmp_file.name

    def tearDown(self):
        collector.SING_BOX = self.old_singbox
        Path(self.tmp_file.name).unlink(missing_ok=True)

    def test_curl_requires_exact_204_http_code(self):
        node = make_node(protocol="vless", tcp_ok=True)

        for code in ["200", "301", "302", "403", "404", "500", "502"]:
            with patch("subprocess.run") as mock_run, \
                 patch("subprocess.Popen") as mock_popen, \
                 patch("time.sleep"):
                mock_run.side_effect = [
                    MagicMock(returncode=0, stdout=""),          # syntax check
                    MagicMock(returncode=0, stdout=f"{code}|0.150"), # stage 1
                ]
                mock_proc = MagicMock()
                mock_popen.return_value = mock_proc

                res = collector.proxy_probe(node)
                self.assertFalse(res.proxy_ok, f"HTTP code {code} must NOT be accepted as 204")

    def test_curl_exact_204_sets_proxy_ok_and_remote_latency(self):
        node = make_node(protocol="vless", tcp_ok=True)

        with patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen, \
             patch("time.sleep"):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=""),          # syntax check
                MagicMock(returncode=0, stdout="204|0.245"), # stage 1: 245ms
                MagicMock(returncode=0, stdout="200|1000000.0"), # stage 2
            ]
            mock_proc = MagicMock()
            mock_popen.return_value = mock_proc

            res = collector.proxy_probe(node)
            self.assertTrue(res.proxy_ok)
            self.assertEqual(res.latency_ms, 245)

            stage1_cmd = mock_run.call_args_list[1][0][0]
            self.assertIn("curl", stage1_cmd)
            self.assertIn("--socks5-hostname", stage1_cmd)
            self.assertIn("--write-out", stage1_cmd)
            self.assertIn("%{http_code}|%{time_total}", stage1_cmd)
            self.assertIn(collector.FAST_HTTP_URL, stage1_cmd)

    def test_sub_millisecond_latency_bounded_to_at_least_one(self):
        node = make_node(protocol="vless", tcp_ok=True)

        with patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen, \
             patch("time.sleep"):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=""),
                MagicMock(returncode=0, stdout="204|0.0001"), # 0.1ms
                MagicMock(returncode=0, stdout="200|1000000.0"),
            ]
            mock_proc = MagicMock()
            mock_popen.return_value = mock_proc

            res = collector.proxy_probe(node)
            self.assertTrue(res.proxy_ok)
            self.assertEqual(res.latency_ms, 1)

    def test_process_cleanup_in_finally_block(self):
        node = make_node(protocol="vless", tcp_ok=True)

        with patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen, \
             patch("time.sleep"):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=""),
                MagicMock(returncode=7, stdout=""), # curl failure
            ]
            mock_proc = MagicMock()
            mock_popen.return_value = mock_proc

            collector.proxy_probe(node)
            mock_proc.terminate.assert_called_once()
            mock_proc.wait.assert_called()


# ── 7. Missing Sing-box Raises Infrastructure Error ────────────────────────────

class MissingSingBoxTest(unittest.TestCase):
    """Verifies that missing sing-box raises RuntimeError instead of registering false negative health."""

    def test_missing_binary_raises_runtime_error(self):
        node = make_node(protocol="vless", tcp_ok=True, proxy_ok=None)
        old_singbox = collector.SING_BOX
        collector.SING_BOX = "/nonexistent/path/to/sing-box"
        try:
            with self.assertRaises(RuntimeError) as cm:
                collector.proxy_probe(node)

            self.assertIn("sing-box", str(cm.exception).lower())
            self.assertIsNone(node.proxy_ok, "Node must NOT be marked negative health when binary is missing")
        finally:
            collector.SING_BOX = old_singbox


# ── 8. Unknown Throughput Remains None Tests ──────────────────────────────────

class UnknownThroughputTest(unittest.TestCase):
    """Verifies that when stage 2 throughput test fails or is skipped, speed_mbps remains None."""

    def setUp(self):
        self.tmp_file = tempfile.NamedTemporaryFile(delete=False)
        self.tmp_file.write(b"mock sing-box")
        self.tmp_file.close()
        self.old_singbox = collector.SING_BOX
        collector.SING_BOX = self.tmp_file.name

    def tearDown(self):
        collector.SING_BOX = self.old_singbox
        Path(self.tmp_file.name).unlink(missing_ok=True)

    def test_stage2_failure_keeps_throughput_none(self):
        node = make_node(protocol="vless", tcp_ok=True, speed_mbps=None)

        with patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen, \
             patch("time.sleep"):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=""),          # check
                MagicMock(returncode=0, stdout="204|0.100"), # stage 1: success
                MagicMock(returncode=28, stdout=""),        # stage 2: curl timeout (exit 28)
            ]
            mock_proc = MagicMock()
            mock_popen.return_value = mock_proc

            res = collector.proxy_probe(node)
            self.assertTrue(res.proxy_ok)
            self.assertIsNone(res.speed_mbps, "Unknown throughput must remain None, not fabricated default")

    def test_stage2_non_200_keeps_throughput_none(self):
        node = make_node(protocol="vless", tcp_ok=True, speed_mbps=None)

        with patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen, \
             patch("time.sleep"):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=""),
                MagicMock(returncode=0, stdout="204|0.100"),
                MagicMock(returncode=0, stdout="500|0"), # HTTP 500
            ]
            mock_proc = MagicMock()
            mock_popen.return_value = mock_proc

            res = collector.proxy_probe(node)
            self.assertTrue(res.proxy_ok)
            self.assertIsNone(res.speed_mbps)

    def test_stage2_success_computes_speed_mbps(self):
        node = make_node(protocol="vless", tcp_ok=True, speed_mbps=None)

        with patch("subprocess.run") as mock_run, \
             patch("subprocess.Popen") as mock_popen, \
             patch("time.sleep"):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=""),
                MagicMock(returncode=0, stdout="204|0.100"),
                MagicMock(returncode=0, stdout="200|500000.0"), # 500,000 bytes/sec
            ]
            mock_proc = MagicMock()
            mock_popen.return_value = mock_proc

            res = collector.proxy_probe(node)
            self.assertTrue(res.proxy_ok)
            self.assertEqual(res.speed_mbps, 4.0)

    def test_score_node_handles_none_throughput_safely(self):
        node_none_speed = make_node(proxy_ok=True, speed_mbps=None, latency_ms=100)
        node_zero_speed = make_node(proxy_ok=True, speed_mbps=0.0, latency_ms=100)
        node_fast = make_node(proxy_ok=True, speed_mbps=50.0, latency_ms=100)

        score_none = collector.score_node(node_none_speed)
        score_zero = collector.score_node(node_zero_speed)
        score_fast = collector.score_node(node_fast)

        self.assertGreater(score_none, 0.0)
        self.assertEqual(score_none, score_zero)
        self.assertGreater(score_fast, score_none)


# ── 9. ICMP Packet Loss Probe Tests ───────────────────────────────────────────

class IcmpPacketLossTest(unittest.TestCase):
    """Verifies that icmp_probe calculates packet loss percentage correctly without inverting it."""

    def test_icmp_loss_calculation(self):
        node = make_node(tcp_ok=True, loss_pct=None)

        mock_icmplib = types.ModuleType("icmplib")
        mock_host = MagicMock()
        mock_host.packet_loss = 0.0  # 0% loss
        mock_icmplib.ping = MagicMock(return_value=mock_host)

        with patch.object(collector, "_HAS_ICMP", True), \
             patch.object(collector, "icmplib", mock_icmplib, create=True):

            res = collector.icmp_probe(node)
            self.assertEqual(res.loss_pct, 0.0, "0.0 packet_loss must map to 0.0 loss_pct")

            mock_host.packet_loss = 0.25  # 25% loss
            res = collector.icmp_probe(node)
            self.assertEqual(res.loss_pct, 25.0)

            mock_host.packet_loss = 1.0   # 100% loss
            res = collector.icmp_probe(node)
            self.assertEqual(res.loss_pct, 100.0, "1.0 packet_loss must map to 100.0 loss_pct")

    def test_icmp_probe_exception_sets_none(self):
        node = make_node(tcp_ok=True, loss_pct=None)

        mock_icmplib = types.ModuleType("icmplib")
        mock_icmplib.ping = MagicMock(side_effect=OSError("Network unreachable"))

        with patch.object(collector, "_HAS_ICMP", True), \
             patch.object(collector, "icmplib", mock_icmplib, create=True):

            res = collector.icmp_probe(node)
            self.assertIsNone(res.loss_pct)

    def test_icmp_probe_skips_when_tcp_not_ok(self):
        node = make_node(tcp_ok=False, loss_pct=None)
        mock_icmplib = types.ModuleType("icmplib")
        mock_icmplib.ping = MagicMock()

        with patch.object(collector, "_HAS_ICMP", True), \
             patch.object(collector, "icmplib", mock_icmplib, create=True):
            res = collector.icmp_probe(node)
            mock_icmplib.ping.assert_not_called()
            self.assertIsNone(res.loss_pct)


# ── 10. Database Upsert Unknown Health Preservation Tests ─────────────────────

class DatabaseUpsertLogicTest(unittest.TestCase):
    """Verifies that upsert_nodes preserves unknown health records (proxy_ok=None) and handles upserts."""

    def test_unknown_proxy_ok_skipped_from_upsert(self):
        node_unknown = make_node(proxy_ok=None, fingerprint="f" * 64)
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = mock_cursor
        mock_cursor.fetchall.return_value = [("all",), ("germany",)]

        with patch.object(collector, "pg_connect", return_value=mock_conn):
            collector.upsert_nodes([node_unknown])

            for call_item in mock_cursor.execute.call_args_list:
                sql = call_item[0][0]
                self.assertNotIn("INSERT INTO mosaic_nodes", sql)

    def test_verified_node_upsert_query_execution(self):
        node_verified = make_node(
            proxy_ok=True, fingerprint="a" * 64,
            country_code="DE", exit_country_code="NL", speed_mbps=None
        )
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_conn.cursor.return_value.__enter__.return_value = mock_cursor
        mock_cursor.fetchone.return_value = [0.90]
        mock_cursor.fetchall.return_value = [("all",), ("germany",)]
        mock_cursor.rowcount = 0

        with patch.object(collector, "pg_connect", return_value=mock_conn):
            stats = collector.upsert_nodes([node_verified])
            self.assertIn("purged", stats)

            insert_calls = [
                c for c in mock_cursor.execute.call_args_list
                if "INSERT INTO mosaic_nodes" in c[0][0]
            ]
            self.assertEqual(len(insert_calls), 1)
            params = insert_calls[0][0][1]

            # Effective country should prefer exit_country_code ('NL') over 'DE'
            effective_cc = params[6]
            self.assertEqual(effective_cc, "NL")

            # speed_mbps should be None (NULL in SQL), never fabricated
            speed_param = params[14]
            self.assertIsNone(speed_param)


# ── 11. Real Local TCP & SOCKS5 Socket Tests ─────────────────────────────────

class RealLocalSocketTest(unittest.TestCase):
    """Genuinely binds local sockets and runs real probes without mocked OS calls."""

    def test_real_tcp_probe_against_live_server(self):
        class SilentEchoServer(socketserver.ThreadingTCPServer):
            allow_reuse_address = True

        class EchoHandler(socketserver.BaseRequestHandler):
            def handle(self):
                pass

        server = SilentEchoServer(("127.0.0.1", 0), EchoHandler)
        host, port = server.server_address
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()

        try:
            node = make_node(address=host, port=port, protocol="vless", tcp_ok=None)
            res = collector.tcp_probe(node, samples=2)

            self.assertTrue(res.tcp_ok)
            self.assertIsNotNone(res.latency_ms)
            self.assertGreaterEqual(res.latency_ms, 1)
        finally:
            server.shutdown()
            server.server_close()

    def test_real_tcp_probe_against_closed_port(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        _, unused_port = s.getsockname()
        s.close()

        node = make_node(address="127.0.0.1", port=unused_port, protocol="vless", tcp_ok=None)
        res = collector.tcp_probe(node, samples=1)

        self.assertFalse(res.tcp_ok)
        self.assertIsNone(res.latency_ms)

    def test_real_curl_socks5_http_204_pipeline(self):
        class Http204Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/generate_204":
                    self.send_response(204)
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
            def log_message(self, *a):
                pass

        httpd = http.server.HTTPServer(("127.0.0.1", 0), Http204Handler)
        http_port = httpd.server_address[1]
        t_http = threading.Thread(target=httpd.serve_forever, daemon=True)
        t_http.start()

        def handle_socks(cs):
            rs = None
            try:
                ver, nmethods = cs.recv(2)
                cs.recv(nmethods)
                cs.sendall(b"\x05\x00")
                data = cs.recv(4)
                if len(data) < 4:
                    return
                atyp = data[3]
                if atyp == 1:
                    dest_ip = socket.inet_ntoa(cs.recv(4))
                elif atyp == 3:
                    dlen = cs.recv(1)[0]
                    dest_ip = cs.recv(dlen).decode()
                else:
                    return
                dest_port = int.from_bytes(cs.recv(2), "big")
                rs = socket.create_connection((dest_ip, dest_port), timeout=3)
                cs.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                sockets = [cs, rs]
                closed = set()
                while len(closed) < 2:
                    active = [s for s in sockets if s not in closed]
                    r, _, _ = select.select(active, [], [], 3)
                    if not r:
                        break
                    for s in r:
                        other = rs if s is cs else cs
                        d = s.recv(4096)
                        if not d:
                            closed.add(s)
                            try:
                                other.shutdown(socket.SHUT_WR)
                            except OSError:
                                pass
                        else:
                            other.sendall(d)
            except Exception:
                pass
            finally:
                for s in (cs, rs):
                    if s:
                        try:
                            s.close()
                        except OSError:
                            pass

        ss = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ss.bind(("127.0.0.1", 0))
        ss.listen(5)
        socks_port = ss.getsockname()[1]

        def run_ss():
            while True:
                try:
                    cs, _ = ss.accept()
                    threading.Thread(target=handle_socks, args=(cs,), daemon=True).start()
                except Exception:
                    break

        t_ss = threading.Thread(target=run_ss, daemon=True)
        t_ss.start()

        try:
            cmd = [
                "curl", "--silent", "--show-error",
                "--socks5-hostname", f"127.0.0.1:{socks_port}",
                "--output", "NUL",
                "--write-out", "%{http_code}|%{time_total}",
                f"http://127.0.0.1:{http_port}/generate_204"
            ]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            self.assertEqual(res.returncode, 0)
            parts = res.stdout.strip().split("|")
            self.assertEqual(len(parts), 2)
            self.assertEqual(parts[0], "204")
            self.assertGreater(float(parts[1]), 0.0)
        finally:
            try:
                ss.close()
            except Exception:
                pass
            try:
                httpd.shutdown()
                httpd.server_close()
            except Exception:
                pass


# ── Existing Quality Score Regression Tests (Preserved) ───────────────────────

class QualityScoreTest(unittest.TestCase):
    def node(self, **values):
        defaults = dict(
            source_name="test", source_url="https://example.test", country_code="DE",
            protocol="vless", address="93.184.216.34", port=443,
            config={"type": "vless"}, fingerprint="a" * 64,
            proxy_ok=True, latency_ms=100, speed_mbps=20,
            jitter_ms=5, loss_pct=0, success_rate=0.85
        )
        defaults.update(values)
        return collector.Node(**defaults)

    def test_failed_proxy_scores_zero(self):
        n = self.node(proxy_ok=False)
        self.assertEqual(collector.score_node(n), 0.0)

    def test_zero_loss_is_not_treated_as_missing(self):
        n_perfect = self.node(loss_pct=0)
        n_lossy = self.node(loss_pct=100)
        self.assertGreater(collector.score_node(n_perfect), collector.score_node(n_lossy))

    def test_better_node_scores_higher(self):
        good = self.node(latency_ms=40, jitter_ms=2, loss_pct=0, speed_mbps=50)
        poor = self.node(latency_ms=700, jitter_ms=180, loss_pct=50, speed_mbps=1)
        self.assertGreater(collector.score_node(good), collector.score_node(poor))

    def test_score_is_bounded(self):
        score = collector.score_node(self.node(latency_ms=1, jitter_ms=0, loss_pct=0, speed_mbps=1000))
        self.assertGreaterEqual(score, 0.0)
        self.assertLessEqual(score, 1.0)


# ── 12. Collector & Scheduler End-to-End Integration Tests ────────────────────

class CollectorSchedulerIntegrationTest(unittest.TestCase):
    """Verifies end-to-end integration of scheduler in collector main().
    
    Tests:
    1. CLI existing budget enforcement and atomic state persistence.
    2. Unknown proxy_ok never advances failures, cooldowns, or source EWMA yield.
    3. Source yield and cooldowns update ONLY on true proxy checks (not TCP-only or untested).
    4. Multi-cycle rotation and skipping nodes under active cooldown.
    5. Country deficit prioritization in candidate scheduling.
    6. Overdue verified node refresh prioritization.
    7. State bounding and TTL pruning during collection cycles.
    8. Strict exclusion of own hosts and private IPs throughout scheduling.
    """

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="collector_sched_test_"))
        self.state_file = self.test_dir / "scheduler_state.json"

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _sample_nodes(self, count: int = 20) -> List[collector.Node]:
        nodes = []
        countries = ["DE", "NL", "US", "FR", "CA", "GB", "FI", "PL", "SG", "JP"]
        sources = ["source_a", "source_b", "source_c"]
        for i in range(count):
            fp = f"{i + 1:04x}" * 16
            cc = countries[i % len(countries)]
            src = sources[i % len(sources)]
            node = make_node(
                fingerprint=fp,
                source_name=src,
                country_code=cc,
                address=f"93.184.216.{(i % 200) + 1}",
                port=443,
                protocol="vless",
            )
            nodes.append(node)
        return nodes

    def test_main_end_to_end_budget_and_persistence(self):
        """main() enforces budget ceiling and creates/updates atomic scheduler state."""
        nodes = self._sample_nodes(25)
        limit = 7

        def fake_tcp_probe(n):
            n.tcp_ok = True
            n.latency_ms = 45
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe):

            checked = collector.main([
                "--limit", str(limit),
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

            # Hard budget ceiling
            self.assertEqual(len(checked), limit)

            # Atomic state persistence
            self.assertTrue(self.state_file.exists())
            raw = json.loads(self.state_file.read_text(encoding="utf-8"))
            self.assertEqual(raw.get("version"), 1)
            self.assertGreater(raw.get("updated_at", 0), 0)
            # All incoming nodes have their last_seen_at touched
            self.assertEqual(len(raw["candidates"]), 25)
            # Exactly `limit` nodes were scheduled in this cycle
            scheduled_count = sum(
                1 for c in raw["candidates"].values() if (c.get("last_scheduled_at") or 0) > 0
            )
            self.assertEqual(scheduled_count, limit)

    def test_unknown_never_changes_failure_or_cooldown(self):
        """Running without --full-probe leaves proxy_ok=None: zero fails and no cooldown."""
        nodes = self._sample_nodes(10)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            n.latency_ms = 50
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe):

            collector.main([
                "--limit", "10",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

            raw = json.loads(self.state_file.read_text(encoding="utf-8"))
            for fp, meta in raw["candidates"].items():
                self.assertIsNone(meta.get("proxy_ok"))
                self.assertEqual(meta.get("consecutive_fails"), 0)
                self.assertEqual(meta.get("cooldown_until"), 0.0)
                self.assertIsNone(meta.get("last_verified_at"))

            # Sources EWMA yield should not be populated on unknown proxy checks
            self.assertEqual(raw.get("sources"), {})

    def test_source_yield_and_cooldown_only_on_true_proxy_checks(self):
        """True proxy checks update failure/cooldown/EWMA; untested nodes remain unaffected."""
        nodes = self._sample_nodes(10)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            n.latency_ms = 40
            return n

        # Make first probe succeed, second fail
        call_count = 0
        def fake_proxy_probe(n):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                n.proxy_ok = True
                n.exit_country_code = "DE"
            else:
                n.proxy_ok = False
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe), \
             patch.object(collector, "proxy_probe", side_effect=fake_proxy_probe):

            collector.main([
                "--limit", "10",
                "--probe-limit", "2",
                "--full-probe",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

            raw = json.loads(self.state_file.read_text(encoding="utf-8"))
            verified_count = 0
            failed_count = 0
            untested_count = 0

            for fp, meta in raw["candidates"].items():
                if meta.get("proxy_ok") is True:
                    verified_count += 1
                    self.assertEqual(meta["consecutive_fails"], 0)
                    self.assertEqual(meta["cooldown_until"], 0.0)
                    self.assertIsNotNone(meta["last_verified_at"])
                elif meta.get("proxy_ok") is False:
                    failed_count += 1
                    self.assertEqual(meta["consecutive_fails"], 1)
                    self.assertGreater(meta["cooldown_until"], time.time() - 10)
                else:
                    untested_count += 1
                    self.assertEqual(meta["consecutive_fails"], 0)
                    self.assertEqual(meta["cooldown_until"], 0.0)

            self.assertEqual(verified_count, 1)
            self.assertEqual(failed_count, 1)
            self.assertEqual(untested_count, 8)

            # Sources state must only account for the 2 actual proxy checks
            total_checks = sum(s.get("checks_count", 0) for s in raw.get("sources", {}).values())
            self.assertEqual(total_checks, 2)

    def test_cooldown_skipping_in_subsequent_main_cycle(self):
        """Failed node placed in cooldown is skipped during subsequent main() cycle."""
        failing_fp = "f" * 64
        good_fp = "1" * 64

        node_fail = make_node(fingerprint=failing_fp, source_name="src", country_code="DE", address="93.184.216.1")
        node_good = make_node(fingerprint=good_fp, source_name="src", country_code="DE", address="93.184.216.2")
        nodes = [node_fail, node_good]

        def fake_tcp_probe(n):
            n.tcp_ok = True
            return n

        def fake_proxy_probe(n):
            if n.fingerprint == failing_fp:
                n.proxy_ok = False
            else:
                n.proxy_ok = True
            return n

        # Cycle 1: run probe, node_fail fails and enters cooldown
        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe), \
             patch.object(collector, "proxy_probe", side_effect=fake_proxy_probe):

            collector.main([
                "--limit", "2",
                "--probe-limit", "2",
                "--full-probe",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

        # Verify state has cooldown
        state = collector.load_state(self.state_file)
        self.assertGreater(state["candidates"][failing_fp]["cooldown_until"], time.time())

        # Cycle 2: main runs again immediately; failing node must be SKIPPED
        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe):

            checked_c2 = collector.main([
                "--limit", "2",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

            scheduled_fps = [n.fingerprint for n in checked_c2]
            self.assertNotIn(failing_fp, scheduled_fps, "Node under cooldown must be skipped")
            self.assertIn(good_fp, scheduled_fps)

    def test_country_deficit_prioritization_in_main(self):
        """main() scheduling prioritizes countries with deficits against country targets."""
        de_node = make_node(fingerprint="d" * 64, country_code="DE", address="93.184.216.10")
        nl_node = make_node(fingerprint="n" * 64, country_code="NL", address="93.184.216.11")
        us_node = make_node(fingerprint="u" * 64, country_code="US", address="93.184.216.12")
        nodes = [us_node, nl_node, de_node]

        # Seed state with existing verified US nodes (so US has lower deficit)
        state = collector.load_state(self.state_file)
        now = time.time()
        for i in range(40):
            fp_dummy = f"us_verified_{i}"
            state["candidates"][fp_dummy] = {
                "source_name": "src",
                "country_code": "US",
                "proxy_ok": True,
                "last_verified_at": now - 100.0,
                "cooldown_until": 0.0,
            }
        collector.save_state(self.state_file, state)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe):

            # Limit budget to 2: DE and NL must be selected before US
            checked = collector.main([
                "--limit", "2",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

            scheduled_ccs = [n.country_code for n in checked]
            self.assertEqual(len(checked), 2)
            self.assertIn("DE", scheduled_ccs)
            self.assertIn("NL", scheduled_ccs)
            self.assertNotIn("US", scheduled_ccs)

    def test_overdue_verified_node_prioritization_in_main(self):
        """Previously verified node that is overdue for refresh is prioritized first."""
        overdue_fp = "o" * 64
        fresh_fp = "f" * 64
        unverified_fp = "u" * 64

        node_overdue = make_node(fingerprint=overdue_fp, country_code="DE", address="93.184.216.1")
        node_fresh = make_node(fingerprint=fresh_fp, country_code="DE", address="93.184.216.2")
        node_unverified = make_node(fingerprint=unverified_fp, country_code="DE", address="93.184.216.3")
        nodes = [node_unverified, node_fresh, node_overdue]

        now = time.time()
        state = collector.load_state(self.state_file)
        state["candidates"][overdue_fp] = {
            "source_name": "src",
            "country_code": "DE",
            "proxy_ok": True,
            "last_verified_at": now - 10000.0,  # overdue (> 7200s TTL)
            "cooldown_until": 0.0,
        }
        state["candidates"][fresh_fp] = {
            "source_name": "src",
            "country_code": "DE",
            "proxy_ok": True,
            "last_verified_at": now - 100.0,    # fresh
            "cooldown_until": 0.0,
        }
        collector.save_state(self.state_file, state)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe):

            # Limit budget = 1: overdue verified node must win
            checked = collector.main([
                "--limit", "1",
                "--state-file", str(self.state_file),
                "--verify-ttl", "7200",
                "--skip-upsert",
            ])

            self.assertEqual(len(checked), 1)
            self.assertEqual(checked[0].fingerprint, overdue_fp)

    def test_state_bounding_and_ttl_pruning_in_main(self):
        """Unseen non-verified candidates older than prune_ttl are pruned from state."""
        stale_fp = "s" * 64
        now = time.time()
        state = collector.load_state(self.state_file)
        state["candidates"][stale_fp] = {
            "source_name": "src",
            "country_code": "US",
            "proxy_ok": False,
            "last_seen_at": now - 100000.0,
            "consecutive_fails": 1,
        }
        collector.save_state(self.state_file, state)

        fresh_node = make_node(fingerprint="f" * 64, country_code="US", address="93.184.216.1")

        with patch.object(collector, "fetch_all_sources", return_value=[fresh_node]), \
             patch.object(collector, "tcp_probe", side_effect=lambda n: n):

            collector.main([
                "--limit", "5",
                "--state-file", str(self.state_file),
                "--prune-ttl", "3600",
                "--skip-upsert",
            ])

            reloaded = collector.load_state(self.state_file)
            self.assertNotIn(stale_fp, reloaded["candidates"], "Stale unverified candidate must be pruned")
            self.assertIn("f" * 64, reloaded["candidates"])

    def test_exclusions_own_hosts_and_private_never_scheduled(self):
        """Exclusions for 5.175.188.152, *.zxc1x1.ru, and private IPs are preserved."""
        for forbidden in ["5.175.188.152", "sub.zxc1x1.ru", "panel.zxc1x1.ru", "192.168.1.1", "10.0.0.1", "127.0.0.1"]:
            self.assertTrue(collector.is_forbidden_host(forbidden))

        raw_feed = (
            "vless://00000000-0000-0000-0000-000000000001@5.175.188.152:443?security=tls#OwnIP\n"
            "vless://00000000-0000-0000-0000-000000000002@sub.zxc1x1.ru:443?security=tls#OwnDomain\n"
            "vless://00000000-0000-0000-0000-000000000003@192.168.1.1:443?security=tls#PrivateIP\n"
            "vless://00000000-0000-0000-0000-000000000004@93.184.216.34:443?security=tls#Legitimate\n"
        )
        nodes = collector._parse_nodes("test-src", "https://example.com", "DE", raw_feed)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0].address, "93.184.216.34")

    def test_cli_negative_legacy_probe_limit_slice_safe(self):
        """Negative or zero --probe-limit in legacy mode safely yields empty probe_targets without negative slicing."""
        nodes = self._sample_nodes(10)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe), \
             patch.object(collector, "proxy_probe") as mock_proxy_probe:

            checked = collector.main([
                "--limit", "10",
                "--probe-limit", "-5",
                "--no-scheduler",
                "--full-probe",
                "--skip-upsert",
            ])
            # proxy_probe must not be called because probe_targets is safely empty
            mock_proxy_probe.assert_not_called()
            self.assertEqual(len(checked), 10)

    def test_cli_unbounded_worker_inputs_clamped(self):
        """Extreme/negative workers and proxy_workers CLI arguments are clamped safely."""
        nodes = self._sample_nodes(5)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe), \
             patch.object(collector, "proxy_probe", side_effect=lambda n: n):

            # Should not raise ValueError (max_workers <= 0) or crash with extreme values
            checked = collector.main([
                "--limit", "5",
                "--workers", "-10",
                "--proxy-workers", "100",
                "--full-probe",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])
            self.assertEqual(len(checked), 5)

    def test_two_phase_scheduling_preserves_cursor_and_last_scheduled(self):
        """Full probe cycle schedules TCP then HTTP without double-advancing exploration cursor."""
        nodes = self._sample_nodes(12)

        def fake_tcp_probe(n):
            n.tcp_ok = True
            return n

        def fake_proxy_probe(n):
            n.proxy_ok = True
            n.latency_ms = 40
            return n

        with patch.object(collector, "fetch_all_sources", return_value=nodes), \
             patch.object(collector, "tcp_probe", side_effect=fake_tcp_probe), \
             patch.object(collector, "proxy_probe", side_effect=fake_proxy_probe):

            collector.main([
                "--limit", "10",
                "--probe-limit", "4",
                "--full-probe",
                "--state-file", str(self.state_file),
                "--skip-upsert",
            ])

            state = collector.load_state(self.state_file)
            # In one main cycle, cursor must only advance by 1, not 2
            self.assertEqual(state.get("exploration_cursor"), 1)


if __name__ == "__main__":
    unittest.main()
