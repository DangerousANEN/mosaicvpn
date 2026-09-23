#!/usr/bin/env python3
"""mosaic_pool_health.py — Sing-box Pool Health Verifier & Config Harmonizer v4.

Changes in v4:
- Concurrency: Bounded multi-threaded probing via ThreadPoolExecutor replacing slow sequential TCP probes.
- Multi-protocol reachability: TCP connect with RTT measurement + UDP/QUIC reachability (Hysteria2/TUIC).
- Honest probe classification: Explicit UNKNOWN state on transport-only TCP connect, generic UDP responses,
  and UDP silence. Neither transport connect nor arbitrary datagram echo proves a usable authenticated proxy.
  Both are treated as UNKNOWN at the membership decision boundary: failure counts are never reset and
  removed candidates are never re-added.
- Non-destructive candidate preservation: Tracks group candidate lists and consecutive failure counts.
  Preserves existing active membership and failure counts on unknown/silence/transport-only.
  Requires verified authenticated proxy response to reset failures or restore removed candidates.
- Group harmonization: Enforces interrupt_exist_connections: False, interval: 3m, tolerance: 50, idle_timeout: 10m.
- Config validation: Fail-closed sing-box check by default (explicit test-only override required).
- Transactional restart & rollback: Atomic config replacement with rollback to previous config on restart failure.
- Concurrency protection: Advisory file locking preventing race conditions on config and state.
- Strict isolation: Complete exclusion and permanent purging of own VPS server & domains (5.175.188.152, *.zxc1x1.ru).
"""

import argparse
import concurrent.futures
import contextlib
from dataclasses import dataclass
import json
import logging
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Dict, List, Optional, Set, Tuple
import urllib.parse

# ── Logging Configuration ───────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)],
)
logger = logging.getLogger("mosaic_pool_health")


# ── Defaults & Forbidden Hosts ──────────────────────────────────────────────

DEFAULT_CONFIG_PATH = "/etc/sing-box-pool/config.json"
DEFAULT_SERVICE_NAME = "sing-box-pool"
DEFAULT_SING_BOX_BIN = "/usr/local/bin/sing-box"
DEFAULT_CONCURRENCY = 16
DEFAULT_TIMEOUT = 2.5
DEFAULT_FAIL_THRESHOLD = 2
DEFAULT_LOCK_TIMEOUT = 15.0

DEFAULT_FAST_HTTP_URL = "https://cp.cloudflare.com/generate_204"
DEFAULT_FAST_HTTP_TIMEOUT = 4.0
DEFAULT_MAX_FILESIZE = 102400  # 100 KB ceiling

# Approved HTTPS 204 endpoints for health verification
APPROVED_HTTPS_204_URLS: Set[str] = {
    "https://cp.cloudflare.com/generate_204",
    "https://www.gstatic.com/generate_204",
    "https://www.google.com/generate_204",
    "https://yandex.ru/generate_204",
    "https://connectivitycheck.gstatic.com/generate_204",
}
DEFAULT_HTTP_CONCURRENCY = 8
DEFAULT_PORT_BASE = 23200
DEFAULT_PORT_COUNT = 64
DEFAULT_SETTLE_DELAY = 0.4

OWN_HOSTS: Set[str] = {
    "5.175.188.152",
    "sub.zxc1x1.ru",
    "panel.zxc1x1.ru",
    "zxc1x1.ru",
}

HARMONIZED_GROUP_SETTINGS = {
    "interval": "3m",
    "idle_timeout": "10m",
    "tolerance": 50,
    "interrupt_exist_connections": False,
}

UDP_PROTOCOLS = {"hysteria", "hysteria2", "tuic"}


# ── Data Classes ─────────────────────────────────────────────────────────────

@dataclass
class ProbeResult:
    tag: str
    alive: Optional[bool]  # True: verified response; False: dead/unreachable; None: unknown (transport-only TCP, generic UDP, silence, infra failure)
    latency_ms: Optional[float] = None
    error: Optional[str] = None
    forbidden: bool = False
    protocol: str = "tcp"
    caveat: Optional[str] = None


def is_verified_alive(res: Optional[ProbeResult]) -> bool:
    """Determine whether a probe result represents a verified authenticated proxy.

    Transport-only TCP handshake and generic UDP responses do NOT prove a usable
    authenticated proxy. They remain UNKNOWN at the membership decision boundary:
    neither resets failure counts nor re-adds removed candidates.
    """
    if res is None or res.alive is not True:
        return False
    if res.caveat in (
        "tcp_transport_only_no_http_e2e",
        "unverified_generic_udp_response",
        "generic_udp_response",
        "udp_protocol_response_verified",  # deprecated false-positive label
        "unverified_udp_silence",
        "infra_failure",
    ):
        return False
    return True


def is_infra_failure(res: Optional[ProbeResult]) -> bool:
    """Determine if result represents an infrastructure failure (e.g. missing binary, port exhausted)."""
    if res is None:
        return False
    return res.caveat == "infra_failure" or (res.alive is None and "infra_failure" in str(res.error))


# ── Host & Candidate Inspection ──────────────────────────────────────────────

def get_own_hosts(extra_hosts: Optional[Set[str]] = None) -> Set[str]:
    hosts = set(OWN_HOSTS)
    env_hosts = os.environ.get("MOSAIC_OWN_HOSTS", "").strip()
    if env_hosts:
        for item in env_hosts.split(","):
            val = item.strip().lower()
            if val:
                hosts.add(val)
    if extra_hosts:
        for item in extra_hosts:
            val = item.strip().lower()
            if val:
                hosts.add(val)
    return hosts


def is_forbidden_host(host: Optional[str], own_hosts: Optional[Set[str]] = None) -> bool:
    """Strictly forbid own server IP and domain patterns to prevent loopbacks and leaks."""
    if not host:
        return True
    h = str(host).strip().lower()
    if not h:
        return True
    hosts = OWN_HOSTS if own_hosts is None else own_hosts
    if h in hosts:
        return True
    if any(h == o or h.endswith("." + o) for o in hosts):
        return True
    if "zxc1x1.ru" in h:
        return True
    return False


# ── Probing Engine ───────────────────────────────────────────────────────────

def probe_tcp(
    server: str,
    port: int,
    timeout: float = DEFAULT_TIMEOUT,
) -> Tuple[bool, Optional[float], Optional[str]]:
    """Probe TCP connectivity with latency RTT measurement.
    
    NOTE: TCP connect proves only transport layer reachability (SYN/ACK handshake).
    It does NOT verify proxy authentication, HTTP data transfer, or end-to-end egress.
    """
    t0 = time.monotonic()
    try:
        with socket.create_connection((str(server), int(port)), timeout=timeout):
            latency_ms = max(0.1, (time.monotonic() - t0) * 1000.0)
            return True, round(latency_ms, 2), None
    except ConnectionRefusedError as exc:
        return False, None, f"connection_refused: {exc}"
    except (socket.timeout, TimeoutError):
        return False, None, f"timeout ({timeout}s)"
    except socket.gaierror as exc:
        return False, None, f"dns_error: {exc}"
    except OSError as exc:
        return False, None, f"os_error: {exc}"
    except Exception as exc:
        return False, None, f"error: {exc}"


def probe_udp(
    server: str,
    port: int,
    timeout: float = DEFAULT_TIMEOUT,
) -> Tuple[Optional[bool], Optional[float], Optional[str], Optional[str]]:
    """Probe UDP reachability (Hysteria2/QUIC).
    
    Sends a probe datagram:
    - If ICMP Port Unreachable or connection reset is received: alive=False (dead).
    - If a generic datagram response is received: alive=None (unknown; generic datagram
      response does NOT verify an authenticated proxy) with caveat.
    - If silence / timeout occurs: alive=None (unknown), latency_ms=None (no fake RTT).
    """
    t0 = time.monotonic()
    sock = None
    try:
        addrinfo = socket.getaddrinfo(str(server), int(port), socket.AF_UNSPEC, socket.SOCK_DGRAM)
        if not addrinfo:
            return False, None, "dns_resolution_failed", None
        family, socktype, proto, _, sockaddr = addrinfo[0]
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        sock.connect(sockaddr)
        # Send a minimal probe datagram
        sock.send(b"\x00" * 8)
        try:
            sock.settimeout(timeout)
            data = sock.recv(64)
            if data:
                latency_ms = max(0.1, (time.monotonic() - t0) * 1000.0)
                return None, round(latency_ms, 2), None, "unverified_generic_udp_response"
        except (socket.timeout, TimeoutError):
            # UDP silence: neither ICMP unreachable nor verified protocol response.
            # Explicit unknown state, no fake RTT.
            return None, None, f"udp_silence_timeout ({timeout}s)", "unverified_udp_silence"
        except (ConnectionRefusedError, ConnectionResetError) as exc:
            return False, None, f"icmp_unreachable: {exc}", None
        except OSError as exc:
            win_err = getattr(exc, "winerror", None)
            if win_err in (10054, 10061):
                return False, None, f"icmp_unreachable: {exc}", None
            return False, None, f"os_error: {exc}", None

        return None, None, "udp_empty_response", "unverified_udp_silence"
    except (ConnectionRefusedError, ConnectionResetError) as exc:
        return False, None, f"icmp_unreachable: {exc}", None
    except (socket.timeout, TimeoutError):
        return None, None, f"udp_silence_timeout ({timeout}s)", "unverified_udp_silence"
    except socket.gaierror as exc:
        return False, None, f"dns_error: {exc}", None
    except OSError as exc:
        win_err = getattr(exc, "winerror", None)
        if win_err in (10054, 10061):
            return False, None, f"icmp_unreachable: {exc}", None
        return False, None, f"os_error: {exc}", None
    except Exception as exc:
        return False, None, f"error: {exc}", None
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass


def probe_outbound(
    outbound: dict,
    timeout: float = DEFAULT_TIMEOUT,
    own_hosts: Optional[Set[str]] = None,
) -> ProbeResult:
    """Verify reachability of a single outbound candidate."""
    tag = str(outbound.get("tag") or "")
    server = outbound.get("server") or outbound.get("server_address")
    port = outbound.get("server_port") or outbound.get("port")

    if not server or not port:
        return ProbeResult(tag=tag, alive=False, error="missing_server_or_port")

    server_str = str(server).strip()
    try:
        port_int = int(port)
        if not (1 <= port_int <= 65535):
            return ProbeResult(tag=tag, alive=False, error=f"invalid_port_{port}")
    except (ValueError, TypeError):
        return ProbeResult(tag=tag, alive=False, error=f"invalid_port_{port}")

    if is_forbidden_host(server_str, own_hosts=own_hosts):
        return ProbeResult(tag=tag, alive=False, error="forbidden_host", forbidden=True)

    proto = str(outbound.get("type") or "").lower()
    is_udp = proto in UDP_PROTOCOLS or str(outbound.get("network") or "").lower() == "udp"
    protocol_name = "udp" if is_udp else "tcp"

    caveat = None
    if is_udp:
        udp_res = probe_udp(server_str, port_int, timeout=timeout)
        if len(udp_res) >= 4:
            alive, latency, err, caveat = udp_res[0], udp_res[1], udp_res[2], udp_res[3]
        else:
            alive, latency, err = udp_res[0], udp_res[1], udp_res[2]
            if alive is True:
                alive = None
                caveat = "unverified_generic_udp_response"
            elif alive is None:
                caveat = "unverified_udp_silence"
    else:
        tcp_ok, latency, err = probe_tcp(server_str, port_int, timeout=timeout)
        if tcp_ok:
            # Transport-only TCP handshake succeeds, but does not prove usable authenticated proxy.
            # Classified as UNKNOWN (alive=None) at membership decision boundary.
            alive = None
            caveat = "tcp_transport_only_no_http_e2e"
        else:
            alive = False
            caveat = None

    return ProbeResult(
        tag=tag,
        alive=alive,
        latency_ms=latency,
        error=err,
        forbidden=False,
        protocol=protocol_name,
        caveat=caveat,
    )


def probe_candidates_concurrently(
    outbounds_by_tag: Dict[str, dict],
    tags: List[str],
    concurrency: int = DEFAULT_CONCURRENCY,
    timeout: float = DEFAULT_TIMEOUT,
    own_hosts: Optional[Set[str]] = None,
) -> Dict[str, ProbeResult]:
    """Probe all candidate tags concurrently using a bounded thread pool."""
    results: Dict[str, ProbeResult] = {}
    if not tags:
        return results

    max_workers = min(max(1, concurrency), len(tags))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_tag = {
            executor.submit(
                probe_outbound,
                outbounds_by_tag.get(tag, {"tag": tag}),
                timeout=timeout,
                own_hosts=own_hosts,
            ): tag
            for tag in tags
        }
        for future in concurrent.futures.as_completed(future_to_tag):
            tag = future_to_tag[future]
            try:
                res = future.result()
            except Exception as exc:
                res = ProbeResult(tag=tag, alive=False, error=f"probe_exception: {exc}")
            results[tag] = res

    return results


# ── Bounded HTTP Recovery Verification ────────────────────────────────────────

class PortPool:
    """Thread-safe bounded pool of ephemeral loopback ports for sing-box probe inbounds."""

    def __init__(self, base: int = DEFAULT_PORT_BASE, count: int = DEFAULT_PORT_COUNT):
        self._available = list(range(base, base + count))
        self._lock = threading.Lock()

    @contextlib.contextmanager
    def acquire(self, timeout: float = 5.0):
        t0 = time.monotonic()
        port = None
        while time.monotonic() - t0 < timeout:
            with self._lock:
                for idx in range(len(self._available)):
                    cand = self._available[idx]
                    try:
                        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                            s.bind(("127.0.0.1", cand))
                        port = self._available.pop(idx)
                        break
                    except OSError:
                        continue
                if port is not None:
                    break
            time.sleep(0.05)
        if port is None:
            raise RuntimeError("PortPool exhausted: no free loopback port available within timeout")
        try:
            yield port
        finally:
            with self._lock:
                if port not in self._available:
                    self._available.append(port)

_DEFAULT_PORT_POOL = PortPool()


def locate_sing_box(custom_path: Optional[str] = None) -> Optional[str]:
    """Resolve sing-box binary from explicit path, env var, PATH, or standard sandbox paths."""
    if custom_path and custom_path != DEFAULT_SING_BOX_BIN:
        if os.path.isfile(custom_path):
            return str(Path(custom_path).resolve())
        return None
    if custom_path and os.path.isfile(custom_path):
        return str(Path(custom_path).resolve())

    env_bin = os.environ.get("MOSAIC_SING_BOX")
    if env_bin and os.path.isfile(env_bin):
        return str(Path(env_bin).resolve())
    which_bin = shutil.which("sing-box") or shutil.which("sing-box.exe")
    if which_bin and os.path.isfile(which_bin):
        return str(Path(which_bin).resolve())
    for cand in [
        Path.home() / "sing-box.exe",
        Path("C:/Users/ANEN/sing-box.exe"),
        Path("/usr/local/bin/sing-box"),
        Path("/usr/bin/sing-box"),
    ]:
        if cand.is_file():
            return str(cand.resolve())
    return None


def probe_candidate_http(
    outbound: dict,
    sing_box_bin: Optional[str] = None,
    http_url: str = DEFAULT_FAST_HTTP_URL,
    http_timeout: float = DEFAULT_FAST_HTTP_TIMEOUT,
    port_pool: Optional[PortPool] = None,
    allow_local_http: bool = False,
    max_bytes: int = DEFAULT_MAX_FILESIZE,
    own_hosts: Optional[Set[str]] = None,
) -> ProbeResult:
    """Verify an authenticated candidate proxy via sing-box SOCKS outbound and curl HTTP 204.
    
    Invariants enforced:
    - Cert-validated HTTPS: curl enforces strict TLS certificate validation without --insecure.
    - Exact 204: Only HTTP status 204 verifies an active egress proxy; non-204 (200, 302, 502) is rejected.
    - Remote RTT: DNS and TLS handshake measured end-to-end via --socks5-hostname.
    - Infra failure -> UNKNOWN (alive=None, caveat='infra_failure'): missing binary, port exhaustion,
      or local spawn failures do not increment candidate failure counters.
    - Local HTTP fixture allowed only when allow_local_http=True with caveat='local_http_fixture_not_public_https'.
    - Strict cleanup of subprocesses, temporary configs, and allocated ports.
    """
    tag = str(outbound.get("tag") or "")
    server = outbound.get("server") or outbound.get("server_address")
    port = outbound.get("server_port") or outbound.get("port")

    proto = str(outbound.get("type") or "").strip().lower()
    if not proto or proto in ("direct", "block", "dns"):
        return ProbeResult(tag=tag, alive=False, error=f"invalid_proxy_type_{proto or 'empty'}")

    if not server or not port:
        return ProbeResult(tag=tag, alive=False, error="missing_server_or_port")
    server_str = str(server).strip()
    try:
        port_int = int(port)
        if not (1 <= port_int <= 65535):
            return ProbeResult(tag=tag, alive=False, error=f"invalid_port_{port}")
    except (ValueError, TypeError):
        return ProbeResult(tag=tag, alive=False, error=f"invalid_port_{port}")
    if is_forbidden_host(server_str, own_hosts=own_hosts):
        return ProbeResult(tag=tag, alive=False, error="forbidden_host", forbidden=True)

    url_str = str(http_url).strip()
    url_lower = url_str.lower()
    if url_lower.startswith("https://"):
        if url_str not in APPROVED_HTTPS_204_URLS and url_lower not in APPROVED_HTTPS_204_URLS:
            return ProbeResult(tag=tag, alive=False, error=f"unapproved_https_url: {http_url}")
        caveat_label = None
    elif url_lower.startswith("http://"):
        if not allow_local_http:
            return ProbeResult(tag=tag, alive=False, error="insecure_http_rejected_require_cert_validated_https")
        parsed_url = urllib.parse.urlsplit(url_str)
        host = (parsed_url.hostname or "").lower()
        if host not in ("127.0.0.1", "localhost", "::1"):
            return ProbeResult(tag=tag, alive=False, error=f"insecure_remote_http_rejected: {http_url}")
        caveat_label = "local_http_fixture_not_public_https"
    else:
        return ProbeResult(tag=tag, alive=False, error=f"unsupported_scheme_in_{http_url}")

    resolved_bin = locate_sing_box(sing_box_bin)
    if not resolved_bin or not os.path.isfile(resolved_bin):
        return ProbeResult(
            tag=tag,
            alive=None,
            error=f"infra_failure: sing-box binary unavailable ({sing_box_bin})",
            caveat="infra_failure",
        )

    curl_bin = shutil.which("curl") or shutil.which("curl.exe")
    if not curl_bin:
        return ProbeResult(
            tag=tag,
            alive=None,
            error="infra_failure: curl binary not found",
            caveat="infra_failure",
        )

    pool = port_pool or _DEFAULT_PORT_POOL
    try:
        port_ctx = pool.acquire()
        socks_port = port_ctx.__enter__()
    except Exception as exc:
        return ProbeResult(
            tag=tag,
            alive=None,
            error=f"infra_failure: port pool exhausted ({exc})",
            caveat="infra_failure",
        )

    proc = None
    tmp_dir = None
    try:
        tmp_dir = tempfile.mkdtemp(prefix="mosaic_probe_")
        try:
            os.chmod(tmp_dir, 0o700)
        except OSError:
            pass
        cfg_path = Path(tmp_dir) / "config.json"

        cand_outbound = dict(outbound)
        cand_tag = cand_outbound.get("tag") or "candidate"
        cand_outbound["tag"] = cand_tag

        probe_cfg = {
            "log": {"level": "error"},
            "inbounds": [
                {
                    "type": "socks",
                    "tag": "probe-in",
                    "listen": "127.0.0.1",
                    "listen_port": socks_port,
                }
            ],
            "outbounds": [
                cand_outbound,
            ],
            "route": {
                "final": cand_tag,
            },
        }

        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(probe_cfg, f, indent=2)
        try:
            os.chmod(cfg_path, 0o600)
        except OSError:
            pass

        # Check config syntax
        check_res = subprocess.run(
            [resolved_bin, "check", "-c", str(cfg_path)],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
        if check_res.returncode != 0:
            err_msg = (check_res.stderr or check_res.stdout or "").strip()
            return ProbeResult(tag=tag, alive=False, error=f"candidate_singbox_check_failed: {err_msg[:200]}")

        proc = subprocess.Popen(
            [resolved_bin, "run", "-c", str(cfg_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Wait for socks inbound port readiness
        t_start = time.monotonic()
        ready = False
        while time.monotonic() - t_start < 2.0:
            if proc.poll() is not None:
                break
            try:
                with socket.create_connection(("127.0.0.1", socks_port), timeout=0.05):
                    ready = True
                    break
            except (OSError, ConnectionRefusedError):
                time.sleep(0.02)

        if not ready:
            err = ""
            if proc:
                try:
                    proc.terminate()
                    try:
                        _, err_text = proc.communicate(timeout=0.5)
                        err = (err_text or "").strip()
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        _, err_text = proc.communicate(timeout=0.5)
                        err = (err_text or "").strip()
                except Exception:
                    pass
            if "bind: address already in use" in err.lower():
                return ProbeResult(tag=tag, alive=None, error=f"infra_failure: bind_conflict ({err[:300]})", caveat="infra_failure")
            return ProbeResult(tag=tag, alive=False, error=f"singbox_start_failed_rc_{proc.poll()}: {err[:300]}")

        # Execute curl probe
        devnull = "nul" if sys.platform == "win32" else "/dev/null"
        curl_cmd = [
            curl_bin,
            "--silent",
            "--show-error",
            "--noproxy", "",
            "--max-time", str(http_timeout),
            "--max-filesize", str(max_bytes),
            "--socks5-hostname", f"127.0.0.1:{socks_port}",
            "--output", devnull,
            "--write-out", "%{http_code}|%{time_total}",
            http_url,
        ]

        try:
            curl_res = subprocess.run(
                curl_cmd,
                capture_output=True,
                text=True,
                timeout=http_timeout + 2.0,
            )
        except subprocess.TimeoutExpired:
            return ProbeResult(tag=tag, alive=False, error=f"http_probe_timeout ({http_timeout}s)")

        if curl_res.returncode == 0:
            out_parts = curl_res.stdout.strip().split("|")
            http_code = out_parts[0] if out_parts else ""
            rtt_sec = float(out_parts[1]) if len(out_parts) > 1 and out_parts[1] else 0.0
            rtt_ms = round(rtt_sec * 1000.0, 2)
            if http_code == "204":
                return ProbeResult(
                    tag=tag,
                    alive=True,
                    latency_ms=max(0.1, rtt_ms),
                    error=None,
                    caveat=caveat_label,
                )
            else:
                return ProbeResult(
                    tag=tag,
                    alive=False,
                    latency_ms=max(0.1, rtt_ms),
                    error=f"unexpected_http_status_{http_code}_expected_204",
                )
        else:
            err_msg = curl_res.stderr.strip() or f"curl_rc_{curl_res.returncode}"
            return ProbeResult(
                tag=tag,
                alive=False,
                error=f"curl_error: {err_msg[:200]}",
            )
    except Exception as exc:
        return ProbeResult(tag=tag, alive=None, error=f"infra_failure: {exc}", caveat="infra_failure")
    finally:
        if proc:
            try:
                proc.terminate()
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=1.0)
            except Exception:
                pass
        if tmp_dir:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        try:
            port_ctx.__exit__(None, None, None)
        except Exception:
            pass


def probe_candidates_http_concurrently(
    outbounds_by_tag: Dict[str, dict],
    tags: List[str],
    sing_box_bin: Optional[str] = None,
    http_url: str = DEFAULT_FAST_HTTP_URL,
    http_timeout: float = DEFAULT_FAST_HTTP_TIMEOUT,
    concurrency: int = DEFAULT_HTTP_CONCURRENCY,
    port_pool: Optional[PortPool] = None,
    allow_local_http: bool = False,
    max_bytes: int = DEFAULT_MAX_FILESIZE,
    own_hosts: Optional[Set[str]] = None,
) -> Dict[str, ProbeResult]:
    """Probe candidates using bounded concurrent sing-box SOCKS instances."""
    results: Dict[str, ProbeResult] = {}
    if not tags:
        return results

    pool = port_pool or _DEFAULT_PORT_POOL
    max_workers = min(max(1, concurrency), len(tags))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_tag = {
            executor.submit(
                probe_candidate_http,
                outbounds_by_tag.get(tag, {"tag": tag}),
                sing_box_bin=sing_box_bin,
                http_url=http_url,
                http_timeout=http_timeout,
                port_pool=pool,
                allow_local_http=allow_local_http,
                max_bytes=max_bytes,
                own_hosts=own_hosts,
            ): tag
            for tag in tags
        }
        for future in concurrent.futures.as_completed(future_to_tag):
            tag = future_to_tag[future]
            try:
                res = future.result()
            except Exception as exc:
                res = ProbeResult(tag=tag, alive=None, error=f"infra_failure: {exc}", caveat="infra_failure")
            results[tag] = res

    return results


# ── Concurrency & Locking ────────────────────────────────────────────────────

@contextlib.contextmanager
def pool_config_lock(lock_path: Path, timeout: float = DEFAULT_LOCK_TIMEOUT):
    """Advisory file lock ensuring mutual exclusion for pool config inspection and updates."""
    if timeout <= 0:
        yield
        return

    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

    start_time = time.monotonic()
    lock_file = None
    acquired = False
    while time.monotonic() - start_time < timeout:
        try:
            lock_file = open(lock_path, "a+b")
            if sys.platform == "win32":
                import msvcrt
                if lock_file.tell() == 0:
                    lock_file.write(b"L")
                    lock_file.flush()
                lock_file.seek(0)
                msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
            break
        except (OSError, IOError):
            if lock_file:
                try:
                    lock_file.close()
                except Exception:
                    pass
                lock_file = None
            time.sleep(0.05)

    if not acquired:
        raise TimeoutError(f"Could not acquire pool config lock on {lock_path} within {timeout}s")

    try:
        yield
    finally:
        if lock_file:
            try:
                if sys.platform == "win32":
                    import msvcrt
                    lock_file.seek(0)
                    msvcrt.locking(lock_file.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
            try:
                lock_file.close()
            except Exception:
                pass


# ── State Persistence ────────────────────────────────────────────────────────

def resolve_state_path(config_path: str, custom_state_path: Optional[str] = None) -> Path:
    if custom_state_path:
        return Path(custom_state_path)
    env_state = os.environ.get("MOSAIC_POOL_STATE")
    if env_state:
        return Path(env_state)
    cfg = Path(config_path)
    state_file = cfg.with_name("mosaic_pool_state.json")
    try:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        return state_file
    except Exception:
        return Path(tempfile.gettempdir()) / "mosaic_pool_state.json"


def load_pool_state(state_path: Path) -> dict:
    if state_path.exists():
        try:
            with open(state_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
        except Exception as exc:
            logger.warning(f"Failed to read pool state from {state_path}: {exc}")
    return {"version": 1, "candidates": {}, "fail_counts": {}}


def save_pool_state(state_path: Path, state: dict) -> None:
    state["updated_at"] = time.time()
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        temp_file = state_path.with_suffix(".tmp")
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(temp_file, state_path)
    except Exception as exc:
        logger.warning(f"Could not persist pool state to {state_path}: {exc}")


# ── Config Validation & System Service ───────────────────────────────────────

def validate_singbox_config(
    config_file: str,
    sing_box_bin: str = DEFAULT_SING_BOX_BIN,
    timeout: float = 15.0,
    allow_missing_singbox: bool = False,
) -> bool:
    """Validate config using sing-box check if installed, otherwise strict JSON validation.
    
    Fail-closed policy: If sing-box binary is not installed, config writes fail closed
    and raise FileNotFoundError unless explicit test-only override is provided
    via allow_missing_singbox=True or MOSAIC_ALLOW_MISSING_SINGBOX=1.
    """
    try:
        with open(config_file, "r", encoding="utf-8") as f:
            json.load(f)
    except Exception as exc:
        raise ValueError(f"Invalid JSON in candidate pool config: {exc}")

    override = (
        allow_missing_singbox
        or os.environ.get("MOSAIC_ALLOW_MISSING_SINGBOX", "0") == "1"
        or os.environ.get("MOSAIC_TEST_OVERRIDE_SING_BOX", "0") == "1"
    )

    if os.path.exists(sing_box_bin):
        res = subprocess.run(
            [sing_box_bin, "check", "-c", config_file],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if res.returncode != 0:
            raise RuntimeError(f"sing-box check failed ({res.returncode}): {res.stderr or res.stdout}")
        return True
    else:
        if not override:
            raise FileNotFoundError(
                f"sing-box binary not found at '{sing_box_bin}'; failing closed for config validation. "
                f"Set allow_missing_singbox=True or MOSAIC_ALLOW_MISSING_SINGBOX=1 only for test environments."
            )
        logger.warning(
            f"sing-box binary not found at {sing_box_bin}; test-only override active, JSON syntax validation only"
        )
        return True


def restart_pool_service(service_name: str = DEFAULT_SERVICE_NAME, timeout: float = 10.0) -> bool:
    """Restart systemd service when config has changed."""
    if os.environ.get("MOSAIC_NO_RESTART", "0") == "1":
        logger.info(f"Service restart skipped due to MOSAIC_NO_RESTART for {service_name}")
        return False
    try:
        subprocess.run(
            ["systemctl", "restart", service_name],
            check=True,
            timeout=timeout,
            capture_output=True,
            text=True,
        )
        logger.info(f"Service {service_name} restarted successfully")
        return True
    except FileNotFoundError:
        logger.warning("systemctl command not found; service restart skipped")
        return False
    except subprocess.CalledProcessError as exc:
        logger.error(f"Failed to restart {service_name}: rc={exc.returncode} err={exc.stderr}")
        raise RuntimeError(f"Service restart failed for {service_name}: rc={exc.returncode} err={exc.stderr}") from exc
    except subprocess.TimeoutExpired as exc:
        logger.error(f"Timed out restarting {service_name} after {timeout}s")
        raise RuntimeError(f"Service restart timed out for {service_name} after {timeout}s") from exc
    except Exception as exc:
        logger.error(f"Unexpected error restarting {service_name}: {exc}")
        raise RuntimeError(f"Unexpected error restarting {service_name}: {exc}") from exc


# ── Core Harmonizer & Health Checker ─────────────────────────────────────────

def run_health_check(
    config_path: str = DEFAULT_CONFIG_PATH,
    state_path: Optional[str] = None,
    sing_box_bin: str = DEFAULT_SING_BOX_BIN,
    service_name: str = DEFAULT_SERVICE_NAME,
    concurrency: int = DEFAULT_CONCURRENCY,
    timeout: float = DEFAULT_TIMEOUT,
    fail_threshold: int = DEFAULT_FAIL_THRESHOLD,
    restart_service: bool = True,
    dry_run: bool = False,
    own_hosts: Optional[Set[str]] = None,
    allow_missing_singbox: bool = False,
    lock_timeout: float = DEFAULT_LOCK_TIMEOUT,
    verify_http: bool = True,
    verify_http_all: bool = False,
    http_url: str = DEFAULT_FAST_HTTP_URL,
    http_timeout: float = DEFAULT_FAST_HTTP_TIMEOUT,
    http_concurrency: int = DEFAULT_HTTP_CONCURRENCY,
    allow_local_http: bool = False,
    port_pool: Optional[PortPool] = None,
) -> dict:
    """Execute non-destructive pool health verification, candidate synchronization, and config harmonization."""
    start_time = time.monotonic()
    resolved_state_path = resolve_state_path(config_path, state_path)
    active_own_hosts = get_own_hosts(own_hosts)

    lock_file = Path(config_path).with_name(f"{Path(config_path).name}.lock")
    with pool_config_lock(lock_file, timeout=lock_timeout):
        try:
            with open(config_path, "r", encoding="utf-8") as stream:
                config = json.load(stream)
        except Exception as exc:
            raise SystemExit(f"Failed to load pool config: {exc}")

        outbounds_by_tag = {
            item.get("tag"): item
            for item in config.get("outbounds", [])
            if isinstance(item, dict) and item.get("tag")
        }

        urltest_groups = [
            group
            for group in config.get("outbounds", [])
            if isinstance(group, dict) and group.get("type") == "urltest"
        ]

        # Load persistent candidate state
        state = load_pool_state(resolved_state_path)
        candidates: Dict[str, List[str]] = state.setdefault("candidates", {})
        fail_counts: Dict[str, int] = state.setdefault("fail_counts", {})

        # 1. Register & synchronize candidates per group
        for group in urltest_groups:
            gtag = group.get("tag", "")
            if not gtag:
                continue
            group_outbounds = list(group.get("outbounds", []))
            if gtag not in candidates:
                # Seed candidates from current group outbounds
                candidates[gtag] = list(group_outbounds)
            else:
                # Merge any new outbounds added by rebuild_pool_config into candidate pool
                for tag in group_outbounds:
                    if tag not in candidates[gtag]:
                        candidates[gtag].append(tag)

        # 2. Identify strictly valid proxy tags & permanently purge forbidden hosts
        valid_proxy_tags: Set[str] = set()
        forbidden_tags: Set[str] = set()

        for tag, outbound in outbounds_by_tag.items():
            if outbound.get("type") in ("urltest", "direct"):
                continue
            server = outbound.get("server") or outbound.get("server_address")
            if is_forbidden_host(server, own_hosts=active_own_hosts):
                forbidden_tags.add(tag)
            else:
                valid_proxy_tags.add(tag)

        # Clean candidates: remove forbidden tags and any tags completely deleted from config
        for gtag in list(candidates.keys()):
            candidates[gtag] = [
                t for t in candidates[gtag]
                if t in valid_proxy_tags and t not in forbidden_tags
            ]

        for tag in list(fail_counts.keys()):
            if tag not in valid_proxy_tags or tag in forbidden_tags:
                del fail_counts[tag]

        # 3. Compute references (all preserved candidate tags across all urltest groups)
        references = sorted({
            tag
            for tag_list in candidates.values()
            for tag in tag_list
        })

        # 4. Concurrently probe all candidate nodes (transport stage)
        probe_results = probe_candidates_concurrently(
            outbounds_by_tag,
            references,
            concurrency=concurrency,
            timeout=timeout,
            own_hosts=active_own_hosts,
        )

        active_tags: Set[str] = {
            tag
            for group in urltest_groups
            for tag in group.get("outbounds", [])
        }

        # Stage 2: Bounded authenticated HTTP verification for recovery candidates (replacing UNKNOWN-only dead end)
        if verify_http:
            resolved_bin = locate_sing_box(sing_box_bin)
            if resolved_bin and os.path.isfile(resolved_bin):
                http_candidate_tags = [
                    tag for tag in references
                    if verify_http_all or tag not in active_tags or fail_counts.get(tag, 0) > 0
                ]
                # Only probe candidates whose transport is not hard-dead
                http_candidate_tags = [
                    tag for tag in http_candidate_tags
                    if probe_results.get(tag) and probe_results[tag].alive is not False
                ]
                if http_candidate_tags:
                    http_results = probe_candidates_http_concurrently(
                        outbounds_by_tag,
                        http_candidate_tags,
                        sing_box_bin=resolved_bin,
                        http_url=http_url,
                        http_timeout=http_timeout,
                        concurrency=http_concurrency,
                        port_pool=port_pool,
                        allow_local_http=allow_local_http,
                        own_hosts=active_own_hosts,
                    )
                    probe_results.update(http_results)
            elif not allow_missing_singbox and (sing_box_bin != DEFAULT_SING_BOX_BIN or os.environ.get("MOSAIC_SING_BOX")):
                # Explicit sing-box path configured but missing -> record infra failure for recovery candidates
                recovery_tags = [
                    tag for tag in references
                    if verify_http_all or tag not in active_tags or fail_counts.get(tag, 0) > 0
                ]
                for tag in recovery_tags:
                    if probe_results.get(tag) and probe_results[tag].alive is not False:
                        probe_results[tag] = ProbeResult(
                            tag=tag,
                            alive=None,
                            error=f"infra_failure: sing-box binary not found at '{sing_box_bin}'",
                            caveat="infra_failure",
                        )

        # 5. Update consecutive failure counts
        for tag in references:
            res = probe_results.get(tag)
            if res is None:
                continue
            if is_verified_alive(res):
                fail_counts[tag] = 0
            elif is_infra_failure(res):
                # Infra failure unknown: no counters touched
                pass
            elif res.alive is False:
                fail_counts[tag] = min(100, fail_counts.get(tag, 0) + 1)
            else:
                # Explicit unknown state (transport-only TCP, generic UDP response, UDP silence):
                # Preserve existing failure counts without resetting or incrementing.
                pass

        changed = False

        # 6. Harmonize groups: update active outbounds based on fail_threshold and enforce settings
        for group in urltest_groups:
            gtag = group.get("tag", "")
            group_cands = candidates.get(gtag, [])
            old_outbounds = list(group.get("outbounds", []))

            new_outbounds = []
            for tag in group_cands:
                if tag in forbidden_tags:
                    continue
                res = probe_results.get(tag)
                was_active = tag in old_outbounds
                failures = fail_counts.get(tag, 0)

                if was_active:
                    # Active candidate:
                    # Preserve membership on unknown (transport-only TCP, generic UDP, silence, infra failure) or when verified alive.
                    # Prune ONLY if failure count reaches or exceeds threshold.
                    if failures < fail_threshold:
                        new_outbounds.append(tag)
                else:
                    # Previously removed candidate:
                    # NEVER re-add on unknown (transport-only TCP connect, generic UDP response, silence, or infra failure).
                    # Only re-add if explicitly verified alive (is_verified_alive(res) is True) and below threshold.
                    if is_verified_alive(res) and failures < fail_threshold:
                        new_outbounds.append(tag)

            # Safety floor: refuse to empty out a group completely on transient failure
            if not new_outbounds:
                logger.warning(
                    f"All candidates for group '{gtag}' exceeded fail threshold ({fail_threshold}); "
                    f"preserving fallback candidate(s) to avoid empty urltest group"
                )
                fallback = [t for t in old_outbounds if t in valid_proxy_tags and t not in forbidden_tags]
                if not fallback and group_cands:
                    # Pick the candidate with the lowest failure count
                    best = min(group_cands, key=lambda t: fail_counts.get(t, 999))
                    fallback = [best]
                new_outbounds = fallback

            if new_outbounds != old_outbounds:
                group["outbounds"] = new_outbounds
                changed = True

            for key, value in HARMONIZED_GROUP_SETTINGS.items():
                if group.get(key) != value:
                    group[key] = value
                    changed = True

        # 7. Atomic config write and service restart if changed
        if changed and not dry_run:
            cfg_dir = os.path.dirname(config_path) or "."
            original_bytes = None
            if os.path.exists(config_path):
                with open(config_path, "rb") as f:
                    original_bytes = f.read()

            fd, temporary = tempfile.mkstemp(prefix="pool.", dir=cfg_dir, text=True)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    json.dump(config, stream, indent=2, ensure_ascii=False)
                    stream.write("\n")
                validate_singbox_config(
                    temporary,
                    sing_box_bin=sing_box_bin,
                    allow_missing_singbox=allow_missing_singbox,
                )
                os.replace(temporary, config_path)
                logger.info(f"Pool config atomically updated at {config_path}")
            except Exception as exc:
                if os.path.exists(temporary):
                    try:
                        os.unlink(temporary)
                    except Exception:
                        pass
                raise RuntimeError(f"Health update validation failed: {exc}") from exc

            if restart_service:
                try:
                    restart_pool_service(service_name=service_name)
                except Exception as restart_err:
                    logger.error(f"Service restart failed for {service_name}: {restart_err}. Rolling back config...")
                    if original_bytes is not None:
                        rb_fd, rb_temp = tempfile.mkstemp(prefix="pool_rollback.", dir=cfg_dir)
                        try:
                            with os.fdopen(rb_fd, "wb") as rb_stream:
                                rb_stream.write(original_bytes)
                            os.replace(rb_temp, config_path)
                            logger.info(f"Rolled back pool config to previous version at {config_path}")
                            try:
                                restart_pool_service(service_name=service_name)
                            except Exception:
                                pass
                        except Exception as rb_write_err:
                            logger.error(f"Failed to rollback config file: {rb_write_err}")
                            if os.path.exists(rb_temp):
                                try:
                                    os.unlink(rb_temp)
                                except Exception:
                                    pass
                    else:
                        if os.path.exists(config_path):
                            try:
                                os.unlink(config_path)
                            except Exception:
                                pass
                    raise RuntimeError(
                        f"Service restart failed for {service_name} ({restart_err}); config rolled back."
                    ) from restart_err

        # 8. Save updated state (fail counts and candidates)
        if not dry_run:
            save_pool_state(resolved_state_path, state)

    elapsed = time.monotonic() - start_time
    dead_tags = {tag for tag in references if fail_counts.get(tag, 0) >= fail_threshold}
    total_failures = sum(
        1 for tag in references
        if probe_results.get(tag) and probe_results[tag].alive is False
    )
    total_unknown = sum(
        1 for tag in references
        if probe_results.get(tag) and probe_results[tag].alive is not False and not is_verified_alive(probe_results[tag])
    )

    summary = {
        "changed": changed,
        "checked": len(references),
        "dead": len(dead_tags),
        "dead_tags": sorted(dead_tags),
        "total_failures": total_failures,
        "total_unknown": total_unknown,
        "forbidden_purged": len(forbidden_tags),
        "concurrency": min(max(1, concurrency), len(references)) if references else 0,
        "elapsed_seconds": round(elapsed, 3),
        "state_path": str(resolved_state_path),
    }

    # Backward-compatible stdout status line
    print(f"pool_health changed={int(changed)} checked={len(references)} dead={len(dead_tags)}")
    return summary


# ── CLI Interface ────────────────────────────────────────────────────────────

def parse_args(args: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sing-box Pool Health Verifier & Config Harmonizer v4"
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("MOSAIC_POOL_CONFIG", DEFAULT_CONFIG_PATH),
        help=f"Path to pool config.json (default: {DEFAULT_CONFIG_PATH})",
    )
    parser.add_argument(
        "--state",
        default=os.environ.get("MOSAIC_POOL_STATE"),
        help="Path to pool health state file (default: <config_dir>/mosaic_pool_state.json)",
    )
    parser.add_argument(
        "--service",
        default=os.environ.get("MOSAIC_POOL_SERVICE", DEFAULT_SERVICE_NAME),
        help=f"Systemd service name to restart on change (default: {DEFAULT_SERVICE_NAME})",
    )
    parser.add_argument(
        "--sing-box",
        default=os.environ.get("MOSAIC_SING_BOX", DEFAULT_SING_BOX_BIN),
        help=f"Path to sing-box executable for syntax check (default: {DEFAULT_SING_BOX_BIN})",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=int(os.environ.get("MOSAIC_POOL_CONCURRENCY", str(DEFAULT_CONCURRENCY))),
        help=f"Max concurrent probe workers (default: {DEFAULT_CONCURRENCY})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("MOSAIC_POOL_TIMEOUT", str(DEFAULT_TIMEOUT))),
        help=f"Socket probe timeout in seconds (default: {DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        "--fail-threshold",
        type=int,
        default=int(os.environ.get("MOSAIC_POOL_FAIL_THRESHOLD", str(DEFAULT_FAIL_THRESHOLD))),
        help=f"Consecutive failures before deactivating candidate (default: {DEFAULT_FAIL_THRESHOLD})",
    )
    parser.add_argument(
        "--no-restart",
        action="store_true",
        default=bool(os.environ.get("MOSAIC_NO_RESTART", "0") == "1"),
        help="Do not restart systemd service on change",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Probe candidates without modifying config or restarting service",
    )
    parser.add_argument(
        "--allow-missing-singbox",
        action="store_true",
        default=bool(os.environ.get("MOSAIC_ALLOW_MISSING_SINGBOX", "0") == "1"),
        help="Test-only override: allow writing config when sing-box binary is missing",
    )
    parser.add_argument(
        "--lock-timeout",
        type=float,
        default=float(os.environ.get("MOSAIC_POOL_LOCK_TIMEOUT", str(DEFAULT_LOCK_TIMEOUT))),
        help=f"Timeout in seconds for config file lock (default: {DEFAULT_LOCK_TIMEOUT})",
    )
    parser.add_argument(
        "--no-http-verify",
        action="store_true",
        help="Disable HTTP 204 egress candidate recovery verification",
    )
    parser.add_argument(
        "--verify-http-all",
        action="store_true",
        default=bool(os.environ.get("MOSAIC_POOL_HTTP_VERIFY_ALL", "0") == "1"),
        help="HTTP 204 verify ALL candidates each cycle (catches open-port-dead-proxy nodes)",
    )
    parser.add_argument(
        "--http-url",
        default=os.environ.get("MOSAIC_POOL_HTTP_URL", DEFAULT_FAST_HTTP_URL),
        help=f"HTTP target URL for egress check (default: {DEFAULT_FAST_HTTP_URL})",
    )
    parser.add_argument(
        "--http-timeout",
        type=float,
        default=float(os.environ.get("MOSAIC_POOL_HTTP_TIMEOUT", str(DEFAULT_FAST_HTTP_TIMEOUT))),
        help=f"HTTP probe timeout in seconds (default: {DEFAULT_FAST_HTTP_TIMEOUT})",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose debug logging",
    )
    return parser.parse_args(args)


def main(args: Optional[List[str]] = None) -> int:
    parsed = parse_args(args)
    if parsed.verbose:
        logger.setLevel(logging.DEBUG)

    try:
        run_health_check(
            config_path=parsed.config,
            state_path=parsed.state,
            sing_box_bin=parsed.sing_box,
            service_name=parsed.service,
            concurrency=parsed.concurrency,
            timeout=parsed.timeout,
            fail_threshold=parsed.fail_threshold,
            restart_service=not parsed.no_restart,
            dry_run=parsed.dry_run,
            allow_missing_singbox=parsed.allow_missing_singbox,
            lock_timeout=parsed.lock_timeout,
            verify_http=not parsed.no_http_verify,
            verify_http_all=parsed.verify_http_all,
            http_url=parsed.http_url,
            http_timeout=parsed.http_timeout,
        )
        return 0
    except Exception as exc:
        logger.error(f"Pool health check failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
