"""
mosaic_pool_collector.py — MosaicVPN Direct Pool Collector & Health Checker v3.

Архитектура v3:
- Fair Stratified Allocation: равномерный пул по странам (DE, NL, US, FR, CA, GB, SG, JP, PL, FI)
- Расширение источников: Au1rxx (all + 10 стран) + Zengfr (VLESS, Trojan, SS)
- Защита: изоляция своего сервера (5.175.188.152, *.zxc1x1.ru), отсечение xhttp/splithttp
- 2-этапный HTTP+Throughput тест:
    1) Быстрый Cloudflare 204 (max-time 4s)
    2) Замер скорости (100KB с speed.cloudflare.com) + извлечение cf-meta-country (реальный exit-country)
- PortPool: потокобезопасное выделение локальных портов без коллизий
- Uptime-бонус стабильности: EWMA success_rate, failure count cooldown
- Изоляция зомби-процессов: гарантированный proc.kill() + proc.wait()
"""

import argparse
import asyncio
import base64
import contextlib
import dataclasses
from dataclasses import dataclass, field
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from typing import Optional, List, Dict, Set, Tuple

import psycopg2
from psycopg2.extras import Json

try:
    import httpx
    _HAS_HTTPX = True
except ImportError:
    _HAS_HTTPX = False

try:
    import icmplib
    _HAS_ICMP = True
except ImportError:
    _HAS_ICMP = False


# ── Configuration Constants ──────────────────────────────────────────────────

HEALTH_TTL_HOURS = int(os.environ.get('MOSAIC_POOL_HEALTH_TTL_HOURS', '6'))
STALE_PURGE_DAYS = int(os.environ.get('MOSAIC_POOL_STALE_PURGE_DAYS', '30'))
FAILURE_DISABLE_THRESHOLD = int(os.environ.get('MOSAIC_POOL_FAILURE_THRESHOLD', '3'))

CONNECT_TIMEOUT = 2.0
TCP_SAMPLES = 3

FAST_HTTP_TIMEOUT = 4
THROUGHPUT_TIMEOUT = 8
FAST_HTTP_URL = 'https://cp.cloudflare.com/generate_204'
THROUGHPUT_URL = 'https://speed.cloudflare.com/__down?bytes=102400'  # 100 KB payload

USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
SING_BOX = '/usr/local/bin/sing-box'

OWN_HOSTS = {
    '5.175.188.152',
    'sub.zxc1x1.ru',
    'panel.zxc1x1.ru',
    'zxc1x1.ru',
}

# Scoring Weights
W_LATENCY    = 0.30
W_JITTER     = 0.15
W_LOSS       = 0.15
W_THROUGHPUT = 0.20
W_STABILITY  = 0.20

LAT_REF_MS    = 600
JITTER_REF_MS = 150
LOSS_REF_PCT  = 50.0
SPEED_REF_MBPS = 15.0

# Multi-country verified feeds + high-quality protocol sources
SOURCES = [
    ('verified-all', None, 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/singbox.json'),
    ('verified-de', 'DE', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-DE.json'),
    ('verified-nl', 'NL', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-NL.json'),
    ('verified-us', 'US', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-US.json'),
    ('verified-fr', 'FR', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-FR.json'),
    ('verified-ca', 'CA', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-CA.json'),
    ('verified-gb', 'GB', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-GB.json'),
    ('verified-fi', 'FI', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-FI.json'),
    ('verified-pl', 'PL', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-PL.json'),
    ('verified-sg', 'SG', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-SG.json'),
    ('verified-jp', 'JP', 'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/by-country/singbox-JP.json'),
    ('raw-vless', None, 'https://raw.githubusercontent.com/zengfr/free-vpn-subscribe/main/vpn_sub_raw_vless.txt'),
    ('raw-trojan', None, 'https://raw.githubusercontent.com/zengfr/free-vpn-subscribe/main/vpn_sub_raw_trojan.txt'),
    ('raw-ss', None, 'https://raw.githubusercontent.com/zengfr/free-vpn-subscribe/main/vpn_sub_raw_shadowsocks.txt'),
    ('vestranet-vless', None, 'https://raw.githubusercontent.com/MustafaBaqer/VestraNet-Nodes/main/protocols/vless.txt'),
    ('vestranet-trojan', None, 'https://raw.githubusercontent.com/MustafaBaqer/VestraNet-Nodes/main/protocols/trojan.txt'),
    ('solovyov-adaptive', None, 'https://raw.githubusercontent.com/solovyov-jenya2004/all_subs/main/final_sorted'),
    ('epodonios-vless', None, 'https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/Splitted-By-Protocol/vless.txt'),
]

SUPPORTED_TYPES = {'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'hysteria2'}


# ── Data Classes ─────────────────────────────────────────────────────────────

@dataclass
class Node:
    source_name: str
    source_url: str
    country_code: Optional[str]
    protocol: str
    address: str
    port: Optional[int]
    config: dict
    fingerprint: str
    # Phase 2: TCP probe
    tcp_ok: Optional[bool] = None
    latency_ms: Optional[int] = None
    jitter_ms: Optional[int] = None
    # Phase 3: ICMP loss (optional)
    loss_pct: Optional[float] = None
    # Phase 4: HTTP proxy probe
    proxy_ok: Optional[bool] = None
    exit_country_code: Optional[str] = None
    speed_mbps: Optional[float] = None
    tls_ok: Optional[bool] = None
    # Scoring
    composite_score: Optional[float] = None
    # Carried from DB on upsert
    success_rate: Optional[float] = None


# ── Port Pool ────────────────────────────────────────────────────────────────

class PortPool:
    """Thread-safe pool of local SOCKS listener ports (23100-23199)."""

    def __init__(self, base: int = 23100, count: int = 100):
        self._available = list(range(base, base + count))
        self._lock = threading.Lock()

    @contextlib.contextmanager
    def acquire(self):
        with self._lock:
            if not self._available:
                raise RuntimeError('PortPool exhausted — reduce concurrent proxy workers')
            port = self._available.pop()
        try:
            yield port
        finally:
            with self._lock:
                self._available.append(port)


_PORT_POOL = PortPool(base=23100, count=100)


# ── Database Helpers ─────────────────────────────────────────────────────────

def pg_connect():
    password_path = os.environ.get('MOSAIC_PG_PASSWORD_FILE', '/etc/mosaic-bot.pg.pass')
    if not os.path.exists(password_path):
        raise RuntimeError(f'Password file not found: {password_path}')
    password = Path(password_path).read_text(encoding='utf-8').strip()
    return psycopg2.connect(
        host=os.environ.get('MOSAIC_PG_HOST', '127.0.0.1'),
        port=int(os.environ.get('MOSAIC_PG_PORT', '6767')),
        user=os.environ.get('MOSAIC_PG_USER', 'postgres'),
        dbname=os.environ.get('MOSAIC_PG_DATABASE', 'postgres'),
        password=password,
        connect_timeout=10,
    )


def fingerprint(config: dict) -> str:
    raw = json.dumps(config, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


# ── Node Parsers ─────────────────────────────────────────────────────────────

def is_forbidden_host(host: str) -> bool:
    if not host:
        return True
    host_lower = host.lower()
    return host_lower in OWN_HOSTS or any(host_lower.endswith('.' + h) for h in OWN_HOSTS)


def node_from_singbox(source_name: str, source_url: str, country: Optional[str], outbound: dict) -> Optional[Node]:
    if not isinstance(outbound, dict):
        return None
    protocol = str(outbound.get('type') or '').lower()
    if protocol not in SUPPORTED_TYPES:
        return None

    # Reject proprietary xhttp/splithttp
    transport = outbound.get('transport')
    if isinstance(transport, dict):
        ttype = str(transport.get('type') or '').lower()
        if ttype in ('xhttp', 'splithttp'):
            return None

    address = outbound.get('server') or outbound.get('server_address')
    port = outbound.get('server_port') or outbound.get('port')
    if not isinstance(address, str) or not address:
        return None
    if not isinstance(port, int) or not (1 <= port <= 65535):
        return None

    if is_forbidden_host(address):
        return None

    config = dict(outbound)
    fp = fingerprint(config)
    config['tag'] = 'mosaic-' + fp[:12]
    return Node(source_name, source_url, country, protocol, address, port, config, fp)


def parse_uri_to_singbox(raw: str, tag: str) -> Optional[dict]:
    """Parse raw vless/trojan/ss URI into sing-box outbound config."""
    raw = raw.strip()
    if not raw or '://' not in raw:
        return None

    parsed = urllib.parse.urlsplit(raw)
    scheme = parsed.scheme.lower()
    if is_forbidden_host(parsed.hostname):
        return None

    query = urllib.parse.parse_qs(parsed.query)
    q = {k: v[0] for k, v in query.items()}

    ttype = (q.get('type') or 'tcp').lower()
    if ttype in ('xhttp', 'splithttp'):
        return None

    if scheme == 'vless':
        uuid = parsed.username
        host = parsed.hostname
        port = parsed.port
        if not uuid or not host or not port:
            return None

        security = q.get('security', 'none').lower()
        sni = q.get('sni') or q.get('peer') or host
        fp_tls = q.get('fp', 'chrome')
        pbk = q.get('pbk')
        sid = q.get('sid', '')
        flow = q.get('flow', '')

        outbound = {
            'type': 'vless',
            'tag': tag,
            'server': host,
            'server_port': port,
            'uuid': uuid,
        }
        if flow:
            outbound['flow'] = flow

        if security == 'reality' and pbk:
            outbound['tls'] = {
                'enabled': True,
                'server_name': sni,
                'utls': {'enabled': True, 'fingerprint': fp_tls or 'chrome'},
                'reality': {
                    'enabled': True,
                    'public_key': pbk,
                    'short_id': sid,
                },
            }
        elif security == 'tls':
            tls = {
                'enabled': True,
                'server_name': sni,
                'utls': {'enabled': True, 'fingerprint': fp_tls or 'chrome'},
            }
            if q.get('allowInsecure') in ('1', 'true') or q.get('insecure') in ('1', 'true'):
                tls['insecure'] = True
            outbound['tls'] = tls

        if ttype == 'ws':
            outbound['transport'] = {
                'type': 'ws',
                'path': q.get('path') or '/',
                'headers': {'Host': q.get('host') or sni},
            }
        elif ttype == 'grpc':
            outbound['transport'] = {
                'type': 'grpc',
                'service_name': q.get('serviceName') or '',
            }
        elif ttype == 'httpupgrade':
            outbound['transport'] = {
                'type': 'httpupgrade',
                'path': q.get('path') or '/',
                'host': q.get('host') or sni,
            }
        return outbound

    elif scheme == 'trojan':
        password = parsed.username
        host = parsed.hostname
        port = parsed.port
        if not password or not host or not port:
            return None
        sni = q.get('sni') or host
        outbound = {
            'type': 'trojan',
            'tag': tag,
            'server': host,
            'server_port': port,
            'password': password,
            'tls': {
                'enabled': True,
                'server_name': sni,
            }
        }
        if q.get('allowInsecure') in ('1', 'true') or q.get('insecure') in ('1', 'true'):
            outbound['tls']['insecure'] = True
        if ttype == 'ws':
            outbound['transport'] = {
                'type': 'ws',
                'path': q.get('path') or '/',
                'headers': {'Host': q.get('host') or sni},
            }
        elif ttype == 'grpc':
            outbound['transport'] = {
                'type': 'grpc',
                'service_name': q.get('serviceName') or '',
            }
        return outbound

    elif scheme == 'ss':
        netloc = parsed.netloc
        import base64
        if '@' in netloc:
            userinfo, hostport = netloc.split('@', 1)
            try:
                padded = userinfo + '=' * (-len(userinfo) % 4)
                decoded = base64.b64decode(padded).decode('utf-8')
                if ':' in decoded:
                    method, password = decoded.split(':', 1)
                else:
                    method, password = userinfo.split(':', 1)
            except Exception:
                if ':' in userinfo:
                    method, password = userinfo.split(':', 1)
                else:
                    return None
            if ':' in hostport:
                host, port_str = hostport.split(':', 1)
                port = int(port_str)
            else:
                return None
        else:
            try:
                padded = netloc + '=' * (-len(netloc) % 4)
                decoded = base64.b64decode(padded).decode('utf-8')
                if '@' in decoded and ':' in decoded:
                    up, hp = decoded.split('@', 1)
                    method, password = up.split(':', 1)
                    host, port_str = hp.split(':', 1)
                    port = int(port_str)
                else:
                    return None
            except Exception:
                return None

        return {
            'type': 'shadowsocks',
            'tag': tag,
            'server': host,
            'server_port': port,
            'method': method,
            'password': password,
        }

    return None


def node_from_uri(source_name: str, source_url: str, country: Optional[str], raw: str) -> Optional[Node]:
    raw = raw.strip()
    if not raw or '://' not in raw:
        return None
    # Preliminary tag for fp calculation
    dummy_tag = 'mosaic-tmp'
    config = parse_uri_to_singbox(raw, dummy_tag)
    if not config:
        return None

    fp = fingerprint(config)
    real_tag = 'mosaic-' + fp[:12]
    config['tag'] = real_tag

    # If country is None, attempt regex from fragment e.g. #DE-Frankfurt
    if country is None:
        parsed = urllib.parse.urlsplit(raw)
        frag = urllib.parse.unquote(parsed.fragment or '').upper()
        for cc_candidate in ('DE', 'NL', 'US', 'FR', 'CA', 'GB', 'FI', 'PL', 'SG', 'JP', 'RU'):
            if re.search(r'\b' + cc_candidate + r'\b', frag):
                country = cc_candidate
                break

    return Node(
        source_name=source_name,
        source_url=source_url,
        country_code=country,
        protocol=config['type'],
        address=config['server'],
        port=config['server_port'],
        config=config,
        fingerprint=fp,
    )


# ── Phase 0: Parallel Source Fetch ───────────────────────────────────────────

def _parse_nodes(source_name: str, source_url: str, country: Optional[str], body: str, json_payload=None) -> list:
    nodes = []
    if json_payload is not None:
        for outbound in (json_payload.get('outbounds', []) if isinstance(json_payload, dict) else []):
            node = node_from_singbox(source_name, source_url, country, outbound)
            if node:
                nodes.append(node)
    else:
        # Check if the body is a base64-encoded subscription
        clean_body = body.strip()
        if clean_body and '\n' not in clean_body and '://' not in clean_body:
            try:
                decoded = base64.b64decode(clean_body).decode('utf-8', errors='ignore')
                if '://' in decoded:
                    body = decoded
            except Exception:
                pass
        for line in body.splitlines():
            line = line.strip()
            if line:
                node = node_from_uri(source_name, source_url, country, line)
                if node:
                    nodes.append(node)
    return nodes


if _HAS_HTTPX:
    async def _fetch_one_async(client: 'httpx.AsyncClient', source: Tuple[str, Optional[str], str]) -> list:
        source_name, country, url = source
        resp = await client.get(url, headers={'User-Agent': USER_AGENT})
        resp.raise_for_status()
        body = resp.text
        json_payload = None
        try:
            json_payload = resp.json()
        except Exception:
            pass
        return _parse_nodes(source_name, url, country, body, json_payload)

    async def _fetch_all_async(sources: list) -> list:
        limits = httpx.Limits(max_keepalive_connections=4, max_connections=len(sources))
        async with httpx.AsyncClient(
            limits=limits,
            timeout=httpx.Timeout(connect=10.0, read=25.0, write=10.0, pool=5.0),
            follow_redirects=True,
        ) as client:
            tasks = [_fetch_one_async(client, s) for s in sources]
            results = await asyncio.gather(*tasks, return_exceptions=True)
        nodes = []
        for source, result in zip(sources, results):
            if isinstance(result, Exception):
                print(f'source_failed={source[0]} reason={type(result).__name__}: {result}')
            else:
                nodes.extend(result)
        return nodes

    def fetch_all_sources(sources: list) -> list:
        return asyncio.run(_fetch_all_async(sources))

else:
    import concurrent.futures
    import urllib.request

    def _fetch_one_sync(source: Tuple[str, Optional[str], str]) -> list:
        source_name, country, url = source
        req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
        with urllib.request.urlopen(req, timeout=25) as resp:
            data = resp.read()
            # Handle BOM and encoding
            body = data.decode('utf-8-sig', errors='ignore')
            json_payload = None
            try:
                json_payload = json.loads(body)
            except Exception:
                pass
            return _parse_nodes(source_name, url, country, body, json_payload)

    def fetch_all_sources(sources: list) -> list:
        nodes = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(sources)) as pool:
            futures = {pool.submit(_fetch_one_sync, s): s for s in sources}
            for fut in concurrent.futures.as_completed(futures):
                source = futures[fut]
                try:
                    nodes.extend(fut.result())
                except Exception as exc:
                    print(f'source_failed={source[0]} reason={type(exc).__name__}: {exc}')
        return nodes


# ── Phase 1: Stratified Candidate Allocation ──────────────────────────────────

def stratify_candidates(nodes: list, total_limit: int = 500) -> list:
    """Fair Stratified Allocation: guarantees healthy quota for each target country."""
    unique: Dict[str, Node] = {}
    for node in nodes:
        existing = unique.get(node.fingerprint)
        if existing is None or (existing.country_code is None and node.country_code is not None):
            unique[node.fingerprint] = node

    by_country: Dict[str, List[Node]] = {}
    other_nodes: List[Node] = []

    priority_countries = {'DE', 'NL', 'US', 'FR', 'CA', 'GB', 'FI', 'PL', 'SG', 'JP'}
    for cc in priority_countries:
        by_country[cc] = []

    for node in unique.values():
        cc = (node.country_code or '').upper()
        if cc in priority_countries:
            by_country[cc].append(node)
        else:
            other_nodes.append(node)

    selected: List[Node] = []
    # Quota per priority country
    per_country_quota = max(25, total_limit // (len(priority_countries) + 2))
    for cc, cnodes in by_country.items():
        selected.extend(cnodes[:per_country_quota])

    remaining_budget = max(0, total_limit - len(selected))
    if remaining_budget > 0:
        # Fill remainder from other and unallocated priority nodes
        overflow = []
        for cc, cnodes in by_country.items():
            overflow.extend(cnodes[per_country_quota:])
        overflow.extend(other_nodes)
        selected.extend(overflow[:remaining_budget])

    return selected


# ── Phase 2: Multi-sample TCP Probe ──────────────────────────────────────────

def tcp_probe(node: Node, samples: int = TCP_SAMPLES) -> Node:
    """Take multi-sample TCP RTT; compute p50 latency and RFC-approximated jitter."""
    rtts = []
    for _ in range(samples):
        t0 = time.monotonic()
        try:
            with socket.create_connection((node.address, node.port), timeout=CONNECT_TIMEOUT):
                pass
            rtts.append((time.monotonic() - t0) * 1000)
        except OSError:
            break
    if not rtts:
        node.tcp_ok = False
        node.latency_ms = None
        node.jitter_ms = None
        return node

    node.tcp_ok = True
    rtts_s = sorted(rtts)
    node.latency_ms = max(1, int(rtts_s[len(rtts_s) // 2]))
    node.jitter_ms = max(0, int(max(rtts) - min(rtts))) if len(rtts) > 1 else 0
    return node


# ── Phase 3: ICMP Loss Probe ──────────────────────────────────────────────────

def icmp_probe(node: Node) -> Node:
    if not _HAS_ICMP or not node.tcp_ok:
        return node
    try:
        host = icmplib.ping(node.address, count=3, interval=0.2, timeout=1.5, privileged=False)
        node.loss_pct = round((1.0 - host.packet_loss) * 100, 1)
    except Exception:
        node.loss_pct = None
    return node


# ── Phase 4: 2-Stage HTTP + Throughput Proxy Probe ────────────────────────────

def proxy_probe(node: Node) -> Node:
    """2-Stage HTTP verification:
    1. Fast 204 check via Cloudflare cp.cloudflare.com (max 4s)
    2. Speed download (100 KB) + cf-meta-country detection via speed.cloudflare.com
    """
    if not node.tcp_ok or not Path(SING_BOX).exists():
        node.proxy_ok = False
        return node

    with _PORT_POOL.acquire() as port:
        config = {
            'log': {'level': 'error'},
            'inbounds': [{'type': 'socks', 'tag': 'probe-in',
                          'listen': '127.0.0.1', 'listen_port': port}],
            'outbounds': [node.config, {'type': 'direct', 'tag': 'direct'}],
            'route': {'final': node.config['tag']},
        }
        with tempfile.TemporaryDirectory(prefix='mosaic-probe-') as tmp:
            path = Path(tmp) / 'config.json'
            path.write_text(json.dumps(config), encoding='utf-8')

            # Check config syntax
            check = subprocess.run(
                [SING_BOX, 'check', '-c', str(path)],
                capture_output=True, text=True, timeout=10,
            )
            if check.returncode != 0:
                node.proxy_ok = False
                return node

            proc = subprocess.Popen(
                [SING_BOX, 'run', '-c', str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                time.sleep(0.6)  # bind listen port

                # Stage 1: Fast 204 connectivity test
                stage1 = subprocess.run(
                    [
                        'curl', '--silent', '--show-error',
                        '--max-time', str(FAST_HTTP_TIMEOUT),
                        '--socks5-hostname', f'127.0.0.1:{port}',
                        '--output', '/dev/null',
                        '--write-out', '%{http_code}|%{time_connect}',
                        FAST_HTTP_URL,
                    ],
                    capture_output=True, text=True,
                    timeout=FAST_HTTP_TIMEOUT + 2,
                )
                parts1 = stage1.stdout.strip().split('|')
                if stage1.returncode != 0 or len(parts1) < 2 or parts1[0] not in ('200', '204'):
                    node.proxy_ok = False
                    return node

                # Node is fundamentally alive
                node.proxy_ok = True
                connect_ms = int(float(parts1[1]) * 1000)
                node.latency_ms = min(node.latency_ms or connect_ms, connect_ms)

                # Stage 2: Throughput + exit country identification
                stage2 = subprocess.run(
                    [
                        'curl', '--silent', '--show-error',
                        '--max-time', str(THROUGHPUT_TIMEOUT),
                        '--socks5-hostname', f'127.0.0.1:{port}',
                        '--output', '/dev/null',
                        '--write-out', '%{http_code}|%{speed_download}',
                        '--dump-header', str(Path(tmp) / 'headers.txt'),
                        THROUGHPUT_URL,
                    ],
                    capture_output=True, text=True,
                    timeout=THROUGHPUT_TIMEOUT + 2,
                )
                parts2 = stage2.stdout.strip().split('|')
                if stage2.returncode == 0 and len(parts2) == 2 and parts2[0] == '200':
                    speed_bps = float(parts2[1])
                    node.speed_mbps = round(speed_bps * 8 / 1_000_000, 3)

                    # Parse exit country from headers
                    header_file = Path(tmp) / 'headers.txt'
                    if header_file.exists():
                        for hline in header_file.read_text(encoding='utf-8', errors='ignore').splitlines():
                            if hline.lower().startswith('cf-meta-country:'):
                                node.exit_country_code = hline.split(':', 1)[1].strip().upper()
                                break
                else:
                    node.speed_mbps = 0.5  # fallback reasonable default for working 204

            except (subprocess.SubprocessError, ValueError):
                node.proxy_ok = False
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

    return node


# ── Phase 5: Composite Scoring ────────────────────────────────────────────────

def score_node(node: Node) -> float:
    """Composite Score: [0.0, 1.0]. Higher is better."""
    if not node.proxy_ok:
        return 0.0

    # Latency: 10ms -> 1.0, 100ms -> 0.70, 300ms -> 0.30, 600ms+ -> 0.0
    if node.latency_ms is not None and node.latency_ms > 0:
        lat_score = max(0.0, 1.0 - math.log1p(node.latency_ms) / math.log1p(LAT_REF_MS))
    else:
        lat_score = 0.0

    # Jitter
    sr = float(node.success_rate or 0.70)
    if node.jitter_ms is not None:
        jitter_score = max(0.0, 1.0 - node.jitter_ms / JITTER_REF_MS)
    else:
        jitter_score = min(1.0, sr * 1.1)

    # Loss
    if node.loss_pct is not None:
        loss_score = max(0.0, 1.0 - node.loss_pct / LOSS_REF_PCT)
    else:
        loss_score = max(0.0, min(1.0, (sr - 0.4) * 2.0))

    # Throughput
    if node.speed_mbps is not None and node.speed_mbps > 0.001:
        speed_score = min(1.0, node.speed_mbps / SPEED_REF_MBPS)
    else:
        speed_score = 0.15

    stability_score = sr

    score = (
        W_LATENCY    * lat_score      +
        W_JITTER     * jitter_score   +
        W_LOSS       * loss_score     +
        W_THROUGHPUT * speed_score    +
        W_STABILITY  * stability_score
    )
    return round(max(0.0, min(1.0, score)), 5)


# ── Phase 6: DB Upsert, Stratified Group Rebuild, Stale Purge ─────────────────

GROUP_IDS = (
    'all', 'germany', 'canada', 'min_latency', 'max_speed', 'stable', 'allowlist',
    'compatibility', 'netherlands', 'usa', 'great-britain', 'france', 'russia', 'free-lte',
    'auto-de', 'auto-ca', 'auto-nl', 'auto-us', 'auto-gb', 'auto-fr', 'auto-ru',
    'auto-pl', 'auto-fi', 'auto-sg', 'auto-jp', 'auto-whitelist',
)


def upsert_nodes(nodes: list) -> dict:
    conn = pg_connect()
    try:
        with conn.cursor() as cur:
            for node in nodes:
                # Prefer detected exit country over source-declared
                effective_country = node.exit_country_code or node.country_code

                cur.execute(
                    'SELECT success_rate FROM mosaic_nodes WHERE fingerprint=%s',
                    (node.fingerprint,)
                )
                row = cur.fetchone()
                if row and row[0] is not None:
                    node.success_rate = float(row[0])
                else:
                    node.success_rate = 0.70

                node.composite_score = score_node(node)

                cur.execute("""
                    INSERT INTO mosaic_nodes(
                        source_url, source_name, fingerprint, protocol, address, port,
                        country_code, exit_country_code, config, tcp_ok, tls_ok, proxy_ok,
                        latency_ms, jitter_ms, loss_pct, speed_mbps, composite_score,
                        success_rate, last_checked_at, last_success_at,
                        failure_count, enabled, probe_version
                    ) VALUES (
                        %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,NULL,%s,%s,%s,%s,%s,%s,%s,
                        now(),
                        CASE WHEN %s THEN now() ELSE NULL END,
                        CASE WHEN %s THEN 0 ELSE 1 END,
                        true, 3
                    )
                    ON CONFLICT(fingerprint) DO UPDATE SET
                        source_url       = excluded.source_url,
                        source_name      = excluded.source_name,
                        country_code     = COALESCE(excluded.country_code, mosaic_nodes.country_code),
                        exit_country_code= COALESCE(excluded.exit_country_code, mosaic_nodes.exit_country_code),
                        config           = excluded.config,
                        tcp_ok           = excluded.tcp_ok,
                        proxy_ok         = excluded.proxy_ok,
                        latency_ms       = excluded.latency_ms,
                        jitter_ms        = excluded.jitter_ms,
                        loss_pct         = excluded.loss_pct,
                        speed_mbps       = excluded.speed_mbps,
                        composite_score  = excluded.composite_score,
                        probe_version    = 3,
                        last_checked_at  = now(),
                        last_success_at  = CASE WHEN excluded.proxy_ok THEN now()
                                                ELSE mosaic_nodes.last_success_at END,
                        success_rate = CASE
                            WHEN excluded.proxy_ok
                            THEN LEAST(1.0, COALESCE(mosaic_nodes.success_rate, 0.70) * 0.85 + 0.15)
                            ELSE GREATEST(0.0, COALESCE(mosaic_nodes.success_rate, 0.70) * 0.85)
                        END,
                        failure_count = CASE WHEN excluded.proxy_ok THEN 0
                                             ELSE mosaic_nodes.failure_count + 1 END,
                        enabled = CASE
                            WHEN excluded.proxy_ok THEN true
                            WHEN mosaic_nodes.failure_count + 1 >= %s THEN false
                            ELSE mosaic_nodes.enabled
                        END,
                        updated_at = now()
                """, (
                    node.source_url, node.source_name, node.fingerprint,
                    node.protocol, node.address, node.port,
                    effective_country, node.exit_country_code,
                    Json(node.config), node.tcp_ok, node.proxy_ok,
                    node.latency_ms, node.jitter_ms, node.loss_pct,
                    node.speed_mbps, node.composite_score,
                    1.0 if node.proxy_ok else 0.0,
                    bool(node.proxy_ok), bool(node.proxy_ok),
                    FAILURE_DISABLE_THRESHOLD,
                ))

            # Query all valid group_ids from DB to avoid any foreign key mismatch
            cur.execute('SELECT id FROM mosaic_groups WHERE enabled IS TRUE')
            valid_group_ids = tuple(row[0] for row in cur.fetchall())
            if valid_group_ids:
                cur.execute('DELETE FROM mosaic_group_nodes WHERE group_id IN %s', (valid_group_ids,))

            # Auto country groups (partitioned, top 40 each, strictly matching existing groups)
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                SELECT 'auto-' || lower(country_code), id, rnk
                FROM (
                    SELECT id, country_code,
                           row_number() OVER (PARTITION BY country_code ORDER BY composite_score DESC NULLS LAST, latency_ms ASC) AS rnk
                    FROM mosaic_nodes
                    WHERE enabled AND proxy_ok = true AND country_code IS NOT NULL
                      AND last_checked_at >= now() - make_interval(hours => %s)
                ) ranked
                WHERE rnk <= 40
                  AND ('auto-' || lower(country_code)) IN (SELECT id FROM mosaic_groups WHERE enabled IS TRUE)
            """, (HEALTH_TTL_HOURS,))

            # Named country groups (prioritize TCP / port 443 over UDP/Hysteria2)
            for group_id, cc in [
                ('germany', 'DE'), ('netherlands', 'NL'), ('usa', 'US'),
                ('canada', 'CA'), ('france', 'FR'), ('great-britain', 'GB')
            ]:
                cur.execute("""
                    INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                    SELECT %s, id, row_number() OVER (
                        ORDER BY (CASE WHEN protocol = 'hysteria2' THEN 1 ELSE 0 END),
                                 (CASE WHEN (config->>'server_port' = '443' OR config->>'port' = '443') THEN 0 ELSE 1 END),
                                 composite_score DESC NULLS LAST, latency_ms ASC
                    )
                    FROM mosaic_nodes
                    WHERE enabled AND proxy_ok = true AND country_code = %s
                      AND last_checked_at >= now() - make_interval(hours => %s)
                    LIMIT 40
                """, (group_id, cc, HEALTH_TTL_HOURS))

            # Top 80 'all' group
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                SELECT 'all', id, row_number() OVER (
                    ORDER BY (CASE WHEN protocol = 'hysteria2' THEN 1 ELSE 0 END),
                             (CASE WHEN (config->>'server_port' = '443' OR config->>'port' = '443') THEN 0 ELSE 1 END),
                             composite_score DESC NULLS LAST
                )
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok = true
                  AND last_checked_at >= now() - make_interval(hours => %s)
                LIMIT 80
            """, (HEALTH_TTL_HOURS,))

            # Quality groups
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                SELECT 'min_latency', id, row_number() OVER (
                    ORDER BY (CASE WHEN protocol = 'hysteria2' THEN 1 ELSE 0 END),
                             (CASE WHEN (config->>'server_port' = '443' OR config->>'port' = '443') THEN 0 ELSE 1 END),
                             latency_ms ASC NULLS LAST, composite_score DESC
                )
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok = true AND latency_ms > 0
                  AND last_checked_at >= now() - make_interval(hours => %s)
                LIMIT 40
            """, (HEALTH_TTL_HOURS,))

            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                SELECT 'max_speed', id, row_number() OVER (
                    ORDER BY (CASE WHEN protocol = 'hysteria2' THEN 1 ELSE 0 END),
                             (CASE WHEN (config->>'server_port' = '443' OR config->>'port' = '443') THEN 0 ELSE 1 END),
                             speed_mbps DESC NULLS LAST, composite_score DESC
                )
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok = true
                  AND last_checked_at >= now() - make_interval(hours => %s)
                LIMIT 40
            """, (HEALTH_TTL_HOURS,))

            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                SELECT 'stable', id, row_number() OVER (
                    ORDER BY (CASE WHEN protocol = 'hysteria2' THEN 1 ELSE 0 END),
                             (CASE WHEN (config->>'server_port' = '443' OR config->>'port' = '443') THEN 0 ELSE 1 END),
                             composite_score DESC NULLS LAST
                )
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok = true
                  AND failure_count = 0 AND success_rate >= 0.85
                  AND last_checked_at >= now() - make_interval(hours => %s)
                LIMIT 40
            """, (HEALTH_TTL_HOURS,))

            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                SELECT 'allowlist', id, row_number() OVER (ORDER BY composite_score DESC NULLS LAST)
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok = true AND protocol = 'vless'
                  AND lower(config::text) LIKE '%%reality%%'
                  AND (config->>'server_port' = '443' OR config->>'port' = '443')
                  AND last_checked_at >= now() - make_interval(hours => %s)
                LIMIT 40
            """, (HEALTH_TTL_HOURS,))

            if 'compatibility' in valid_group_ids:
                cur.execute("""
                    INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                    SELECT 'compatibility', id, row_number() OVER (ORDER BY composite_score DESC NULLS LAST)
                    FROM mosaic_nodes
                    WHERE enabled AND proxy_ok = true AND protocol = 'vless'
                      AND lower(config::text) LIKE '%%reality%%'
                      AND (config->>'server_port' = '443' OR config->>'port' = '443')
                      AND last_checked_at >= now() - make_interval(hours => %s)
                    LIMIT 40
                """, (HEALTH_TTL_HOURS,))

            if 'auto-whitelist' in valid_group_ids:
                cur.execute("""
                    INSERT INTO mosaic_group_nodes(group_id, node_id, priority)
                    SELECT 'auto-whitelist', id, row_number() OVER (ORDER BY composite_score DESC NULLS LAST)
                    FROM mosaic_nodes
                    WHERE enabled AND proxy_ok = true AND protocol = 'vless'
                      AND lower(config::text) LIKE '%%reality%%'
                      AND (config->>'server_port' = '443' OR config->>'port' = '443')
                      AND last_checked_at >= now() - make_interval(hours => %s)
                    LIMIT 40
                """, (HEALTH_TTL_HOURS,))

            # Purge permanently dead nodes
            cur.execute("""
                DELETE FROM mosaic_nodes
                WHERE NOT enabled
                  AND failure_count >= %s
                  AND (last_success_at IS NULL OR last_success_at < now() - make_interval(days => %s))
            """, (FAILURE_DISABLE_THRESHOLD, STALE_PURGE_DAYS))
            purged = cur.rowcount

        conn.commit()
        return {'purged': purged}
    finally:
        conn.close()


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    import concurrent.futures

    parser = argparse.ArgumentParser(description='MosaicVPN pool collector v3')
    parser.add_argument('--limit', type=int, default=500,
                        help='Max candidates to TCP-probe after stratification')
    parser.add_argument('--probe-limit', type=int, default=80,
                        help='Max TCP-live configs to HTTP-probe')
    parser.add_argument('--workers', type=int, default=48,
                        help='TCP probe thread workers')
    parser.add_argument('--proxy-workers', type=int, default=6,
                        help='Concurrent sing-box proxy probe workers')
    parser.add_argument('--full-probe', action='store_true',
                        help='Run HTTP proxy probes')
    parser.add_argument('--icmp', action='store_true',
                        help='Enable ICMP loss probes')
    args = parser.parse_args()

    t0 = time.monotonic()
    print('phase=fetch')
    all_nodes = fetch_all_sources(SOURCES)

    print('phase=dedup')
    candidates = stratify_candidates(all_nodes, total_limit=args.limit)
    print(f'imported={len(all_nodes)} stratified_candidates={len(candidates)}')

    print('phase=tcp_probe')
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        checked = list(pool.map(tcp_probe, candidates))
    tcp_alive = [n for n in checked if n.tcp_ok]
    print(f'tcp_alive={len(tcp_alive)}')

    if args.icmp and _HAS_ICMP:
        print('phase=icmp_probe')
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            checked = list(pool.map(icmp_probe, checked))

    if args.full_probe:
        print('phase=proxy_probe')
        # Stratify HTTP probe targets across countries as well
        tcp_live_by_cc: Dict[str, List[Node]] = {}
        for n in tcp_alive:
            tcp_live_by_cc.setdefault((n.country_code or 'OTHER').upper(), []).append(n)

        probe_targets = []
        target_quota = max(10, args.probe_limit // max(1, len(tcp_live_by_cc)))
        for cc, cnodes in tcp_live_by_cc.items():
            probe_targets.extend(cnodes[:target_quota])
        if len(probe_targets) < args.probe_limit:
            rem = [n for n in tcp_alive if n not in probe_targets]
            probe_targets.extend(rem[:args.probe_limit - len(probe_targets)])

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.proxy_workers) as pool:
            probed = list(pool.map(proxy_probe, probe_targets))
        by_fp = {n.fingerprint: n for n in probed}
        checked = [by_fp.get(n.fingerprint, n) for n in checked]
        proxy_ok_count = sum(1 for n in checked if n.proxy_ok)
        print(f'proxy_ok={proxy_ok_count}')
    else:
        for node in checked:
            node.proxy_ok = False

    print('phase=upsert')
    stats = upsert_nodes(checked)

    elapsed = time.monotonic() - t0
    print(
        f'done elapsed_s={elapsed:.1f} '
        f'imported={len(all_nodes)} candidates={len(candidates)} '
        f'tcp_alive={len(tcp_alive)} '
        f'proxy_ok={sum(1 for n in checked if n.proxy_ok)} '
        f'purged_stale={stats["purged"]}'
    )


if __name__ == '__main__':
    main()
