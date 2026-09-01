#!/usr/bin/env python3
"""MosaicVPN direct-node collector.

The collector never transports customer traffic. It only downloads public configuration
feeds, verifies a bounded candidate set, and stores internal node metadata in PostgreSQL.
User-facing manifests later receive selected configurations directly; source URLs and
administrative metadata are never exposed by the API.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

import psycopg2
from psycopg2.extras import Json
import requests

SING_BOX = os.environ.get('MOSAIC_SING_BOX_BIN', '/usr/local/bin/sing-box')
CONNECT_TIMEOUT = float(os.environ.get('MOSAIC_POOL_CONNECT_TIMEOUT', '3.5'))
HTTP_TIMEOUT = float(os.environ.get('MOSAIC_POOL_HTTP_TIMEOUT', '12'))
# A node is eligible for a smart group only while the health result is fresh.
# Repeated probe failures disable it until a later successful check rehabilitates it.
HEALTH_TTL_HOURS = max(1, int(os.environ.get('MOSAIC_POOL_HEALTH_TTL_HOURS', '6')))
FAILURE_DISABLE_THRESHOLD = max(1, int(os.environ.get('MOSAIC_POOL_FAILURE_DISABLE_THRESHOLD', '3')))
USER_AGENT = 'MosaicVPNPoolCollector/1.0'

SOURCES = [
    ('verified-all', None, 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/singbox.json'),
    ('verified-de', 'DE', 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/singbox-DE.json'),
    ('verified-nl', 'NL', 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/singbox-NL.json'),
    ('verified-us', 'US', 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/singbox-US.json'),
    ('verified-fr', 'FR', 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/singbox-FR.json'),
    ('verified-ca', 'CA', 'https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/by-country/singbox-CA.json'),
    ('raw-vless-fallback', None, 'https://raw.githubusercontent.com/zengfr/free-vpn-subscribe/main/vpn_sub_raw_vless.txt'),
]
SUPPORTED_TYPES = {'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'hysteria2'}

@dataclass
class Node:
    source_name: str
    source_url: str
    country_code: str | None
    protocol: str
    address: str
    port: int | None
    config: dict
    fingerprint: str
    tcp_ok: bool | None = None
    latency_ms: int | None = None
    proxy_ok: bool | None = None
    speed_mbps: float | None = None
    jitter_ms: float | None = None
    packet_loss: float | None = None


def pg_connect():
    password_path = os.environ.get('MOSAIC_PG_PASSWORD_FILE')
    if not password_path:
        raise RuntimeError('MOSAIC_PG_PASSWORD_FILE is required')
    password = Path(password_path).read_text(encoding='utf-8').strip()
    return psycopg2.connect(
        host=os.environ.get('MOSAIC_PG_HOST', '127.0.0.1'),
        port=int(os.environ.get('MOSAIC_PG_PORT', '6767')),
        user=os.environ.get('MOSAIC_PG_USER', 'postgres'),
        dbname=os.environ.get('MOSAIC_PG_DATABASE', 'postgres'),
        password=password,
        connect_timeout=10,
    )


def fingerprint(config):
    raw = json.dumps(config, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def node_from_singbox(source_name, source_url, country, outbound):
    if not isinstance(outbound, dict):
        return None
    protocol = str(outbound.get('type') or '').lower()
    if protocol not in SUPPORTED_TYPES:
        return None
    address = outbound.get('server') or outbound.get('server_address')
    port = outbound.get('server_port') or outbound.get('port')
    if not isinstance(address, str) or not address or not isinstance(port, int) or not (1 <= port <= 65535):
        return None
    config = dict(outbound)
    config['tag'] = 'mosaic-' + fingerprint(config)[:12]
    return Node(source_name, source_url, country, protocol, address, port, config, fingerprint(config))


def node_from_uri(source_name, source_url, country, raw):
    raw = raw.strip()
    if not raw or '://' not in raw:
        return None
    parsed = urllib.parse.urlsplit(raw)
    protocol = parsed.scheme.lower()
    if protocol not in SUPPORTED_TYPES or not parsed.hostname or not parsed.port:
        return None
    # URI fallback is retained in a neutral serialised form. Rich sing-box feeds are preferred.
    config = {'type': protocol, 'uri': raw, 'tag': 'mosaic-' + hashlib.sha256(raw.encode()).hexdigest()[:12]}
    return Node(source_name, source_url, country, protocol, parsed.hostname, parsed.port, config, fingerprint(config))


def fetch_source(source):
    source_name, country, url = source
    response = requests.get(url, headers={'User-Agent': USER_AGENT}, timeout=20)
    response.raise_for_status()
    body = response.text
    nodes = []
    try:
        payload = response.json()
        for outbound in payload.get('outbounds', []) if isinstance(payload, dict) else []:
            node = node_from_singbox(source_name, url, country, outbound)
            if node:
                nodes.append(node)
    except (ValueError, AttributeError):
        for line in body.splitlines():
            node = node_from_uri(source_name, url, country, line)
            if node:
                nodes.append(node)
    return nodes


def tcp_probe(node):
    samples = []
    attempts = 3
    for _ in range(attempts):
        started = time.monotonic()
        try:
            with socket.create_connection((node.address, node.port), timeout=CONNECT_TIMEOUT):
                samples.append(max(1.0, (time.monotonic() - started) * 1000))
        except OSError:
            pass
    node.tcp_ok = bool(samples)
    node.packet_loss = round((attempts - len(samples)) / attempts, 3)
    node.latency_ms = int(statistics.median(samples)) if samples else None
    node.jitter_ms = round(statistics.pstdev(samples), 2) if len(samples) > 1 else (0.0 if samples else None)
    return node


def proxy_probe(node):
    """Perform a bounded real HTTP probe through one sing-box outbound.

    URI-only fallback nodes are intentionally not executed: they require a protocol
    parser before a safe sing-box config can be built. They can still be normalised
    and tracked, but will not be published until a rich config source provides them.
    """
    if not node.tcp_ok or 'uri' in node.config or not Path(SING_BOX).exists():
        node.proxy_ok = False
        return node
    # Reserve an OS-assigned ephemeral port. Fingerprint-derived ports collided
    # under concurrent probes and produced false failures.
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    config = {
        'log': {'level': 'error'},
        'inbounds': [{'type': 'socks', 'tag': 'probe-in', 'listen': '127.0.0.1', 'listen_port': port}],
        'outbounds': [node.config, {'type': 'direct', 'tag': 'direct'}],
        'route': {'final': node.config['tag']},
    }
    with tempfile.TemporaryDirectory(prefix='mosaic-pool-') as tmp:
        path = Path(tmp) / 'config.json'
        path.write_text(json.dumps(config), encoding='utf-8')
        check = subprocess.run([SING_BOX, 'check', '-c', str(path)], capture_output=True, text=True, timeout=15)
        if check.returncode != 0:
            node.proxy_ok = False
            return node
        proc = subprocess.Popen([SING_BOX, 'run', '-c', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 4.0
            while time.monotonic() < deadline:
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.15):
                        break
                except OSError:
                    if proc.poll() is not None:
                        break
                    time.sleep(0.05)
            curl = subprocess.run(
                ['curl', '--silent', '--show-error', '--max-time', str(HTTP_TIMEOUT), '--socks5-hostname', f'127.0.0.1:{port}',
                 '--output', '/dev/null', '--write-out', '%{http_code}|%{time_total}|%{speed_download}', 'https://www.cloudflare.com/cdn-cgi/trace'],
                capture_output=True, text=True, timeout=HTTP_TIMEOUT + 3,
            )
            parts = curl.stdout.strip().split('|')
            if curl.returncode == 0 and len(parts) == 3 and parts[0] == '200':
                node.proxy_ok = True
                elapsed_ms = int(float(parts[1]) * 1000)
                node.latency_ms = min(node.latency_ms or elapsed_ms, elapsed_ms)
                node.speed_mbps = round(float(parts[2]) * 8 / 1_000_000, 3)
            else:
                node.proxy_ok = False
        except (subprocess.SubprocessError, ValueError):
            node.proxy_ok = False
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
    return node


def upsert_nodes(nodes):
    conn = pg_connect()
    try:
        with conn.cursor() as cur:
            for node in nodes:
                cur.execute("""
                    INSERT INTO mosaic_nodes(source_url,source_name,fingerprint,protocol,address,port,country_code,config,
                        tcp_ok,tls_ok,proxy_ok,latency_ms,speed_mbps,success_rate,last_checked_at,last_success_at,failure_count,enabled)
                    VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,NULL,%s,%s,%s,%s,now(),CASE WHEN %s THEN now() ELSE NULL END,
                        CASE WHEN %s THEN 0 ELSE 1 END,true)
                    ON CONFLICT(fingerprint) DO UPDATE SET
                      source_url=excluded.source_url,source_name=excluded.source_name,country_code=COALESCE(excluded.country_code,mosaic_nodes.country_code),
                      config=excluded.config,tcp_ok=excluded.tcp_ok,proxy_ok=excluded.proxy_ok,latency_ms=excluded.latency_ms,
                      speed_mbps=excluded.speed_mbps,last_checked_at=now(),last_success_at=CASE WHEN excluded.proxy_ok THEN now() ELSE mosaic_nodes.last_success_at END,
                      success_rate=CASE WHEN excluded.proxy_ok
                        THEN LEAST(1.0, COALESCE(mosaic_nodes.success_rate, 0.70) * 0.80 + 0.20)
                        ELSE GREATEST(0.0, COALESCE(mosaic_nodes.success_rate, 0.70) * 0.80)
                      END,
                      failure_count=CASE WHEN excluded.proxy_ok THEN 0 ELSE mosaic_nodes.failure_count+1 END,
                      enabled=CASE WHEN excluded.proxy_ok THEN true WHEN mosaic_nodes.failure_count+1 >= %s THEN false ELSE mosaic_nodes.enabled END,updated_at=now()
                """, (node.source_url, node.source_name, node.fingerprint, node.protocol, node.address, node.port, node.country_code,
                      Json(node.config), node.tcp_ok, node.proxy_ok, node.latency_ms, node.speed_mbps,
                      0.70 if node.proxy_ok else 0.0, bool(node.proxy_ok), bool(node.proxy_ok), FAILURE_DISABLE_THRESHOLD))
            # Retain bounded history: dead records have no routing value and used
            # to grow forever across frequently-changing public feeds.
            cur.execute("""DELETE FROM mosaic_nodes
                           WHERE enabled=false AND last_checked_at < now() - interval '21 days'""")
            # Group membership is rebuilt from fresh, directly tested nodes only.
            # "owned" is intentionally excluded: it belongs to the legacy owned-node path.
            GROUP_IDS = ('all','germany','canada','min_latency','max_speed','stable','allowlist',
                        'netherlands','usa','great-britain','france','russia','free-lte',
                        'auto-de','auto-ca','auto-nl','auto-us','auto-gb','auto-fr','auto-ru')
            cur.execute("DELETE FROM mosaic_group_nodes WHERE group_id IN %s", (GROUP_IDS,))
            # Auto-seed per-country groups for every country with >= 5 live
            # nodes, capped at 40 members each (priority by latency).
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'auto-' || lower(country_code), id,
                       row_number() OVER (PARTITION BY country_code ORDER BY latency_ms NULLS LAST)
                FROM (
                    SELECT id, country_code, latency_ms,
                           count(*) OVER (PARTITION BY country_code) AS cc_total
                    FROM mosaic_nodes
                    WHERE enabled AND proxy_ok=true AND country_code IS NOT NULL
                      AND last_checked_at >= now() - make_interval(hours => %s)
                ) ranked
                WHERE cc_total >= 5
                ORDER BY country_code, latency_ms NULLS LAST
            """, (HEALTH_TTL_HOURS,))
            # Free LTE / mobile-whitelist group: Reality VLESS nodes whose
            # config or source hints at mobile/TSPU friendliness.
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'free-lte',id,row_number() OVER (ORDER BY success_rate DESC, latency_ms NULLS LAST)
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok=true AND protocol='vless'
                  AND (lower(config::text) LIKE '%%reality%%')
                  AND (lower(source_name) LIKE '%%whitelist%%'
                       OR lower(source_name) LIKE '%%rus%%'
                       OR lower(config::text) LIKE '%%gosuslugi%%'
                       OR lower(config::text) LIKE '%%sberbank%%'
                       OR lower(config::text) LIKE '%%vk.com%%')
                  AND last_checked_at >= now() - make_interval(hours => %s)
                ORDER BY success_rate DESC, latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'all',id,row_number() OVER (ORDER BY latency_ms NULLS LAST, last_success_at DESC NULLS LAST)
                FROM mosaic_nodes WHERE enabled AND proxy_ok=true AND last_checked_at >= now() - make_interval(hours => %s) ORDER BY latency_ms NULLS LAST LIMIT 80
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'germany',id,row_number() OVER (ORDER BY latency_ms NULLS LAST, success_rate DESC, last_success_at DESC NULLS LAST)
                FROM mosaic_nodes WHERE enabled AND proxy_ok=true AND country_code='DE' AND last_checked_at >= now() - make_interval(hours => %s) ORDER BY latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'canada',id,row_number() OVER (ORDER BY latency_ms NULLS LAST, success_rate DESC, last_success_at DESC NULLS LAST)
                FROM mosaic_nodes WHERE enabled AND proxy_ok=true AND country_code='CA' AND last_checked_at >= now() - make_interval(hours => %s) ORDER BY latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'min_latency',id,row_number() OVER (ORDER BY latency_ms NULLS LAST)
                FROM mosaic_nodes WHERE enabled AND proxy_ok=true AND last_checked_at >= now() - make_interval(hours => %s) ORDER BY latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'max_speed',id,row_number() OVER (ORDER BY speed_mbps DESC NULLS LAST, latency_ms NULLS LAST)
                FROM mosaic_nodes WHERE enabled AND proxy_ok=true AND last_checked_at >= now() - make_interval(hours => %s) ORDER BY speed_mbps DESC NULLS LAST, latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'stable',id,row_number() OVER (ORDER BY success_rate DESC, failure_count ASC, latency_ms NULLS LAST, last_success_at DESC NULLS LAST)
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok=true AND failure_count=0 AND success_rate >= 0.85
                  AND last_checked_at >= now() - make_interval(hours => %s)
                ORDER BY success_rate DESC, latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
            cur.execute("""
                INSERT INTO mosaic_group_nodes(group_id,node_id,priority)
                SELECT 'allowlist',id,row_number() OVER (ORDER BY success_rate DESC, latency_ms NULLS LAST)
                FROM mosaic_nodes
                WHERE enabled AND proxy_ok=true AND protocol='vless' AND lower(config::text) LIKE '%%reality%%'
                  AND last_checked_at >= now() - make_interval(hours => %s)
                ORDER BY success_rate DESC, latency_ms NULLS LAST LIMIT 40
            """, (HEALTH_TTL_HOURS,))
        conn.commit()
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--limit', type=int, default=240, help='Maximum deduplicated candidates to TCP probe.')
    parser.add_argument('--probe-limit', type=int, default=40, help='Maximum TCP-live rich configs to HTTP-probe.')
    parser.add_argument('--workers', type=int, default=32)
    parser.add_argument('--full-probe', action='store_true')
    args = parser.parse_args()

    imported = []
    # Fetch independent sources concurrently so one 20 s timeout cannot stall all
    # remaining feeds. The small fixed pool bounds response bodies held in RAM.
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(SOURCES))) as source_pool:
        jobs = {source_pool.submit(fetch_source, source): source for source in SOURCES}
        for future in concurrent.futures.as_completed(jobs):
            source = jobs[future]
            try:
                imported.extend(future.result())
            except Exception as exc:
                print(f'source_failed={source[0]} reason={type(exc).__name__}')
    unique = {}
    for node in imported:
        existing = unique.get(node.fingerprint)
        # General feed is fetched first. Prefer a duplicate from a validated
        # country shard because it supplies the region required by smart groups.
        if existing is None or (existing.country_code is None and node.country_code is not None):
            unique[node.fingerprint] = node
    # Probe country shards first so regional groups are not starved by the
    # large all-verified feed; then fill remaining slots with global candidates.
    # Randomise within priority tiers. A deterministic fingerprint cap repeatedly
    # tested the same nodes and permanently starved the tail of large feeds.
    regional = [n for n in unique.values() if n.country_code is not None]
    global_nodes = [n for n in unique.values() if n.country_code is None]
    random.SystemRandom().shuffle(regional)
    random.SystemRandom().shuffle(global_nodes)
    candidates = (regional + global_nodes)[:max(1, args.limit)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(args.workers, 64))) as pool:
        checked = list(pool.map(tcp_probe, candidates))
    if args.full_probe:
        rich_live = [node for node in checked if node.tcp_ok and 'uri' not in node.config][:max(0, args.probe_limit)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            probed = list(pool.map(proxy_probe, rich_live))
        by_fp = {node.fingerprint: node for node in probed}
        checked = [by_fp.get(node.fingerprint, node) for node in checked]
    else:
        for node in checked:
            node.proxy_ok = False
    upsert_nodes(checked)
    print(f'imported={len(imported)} unique={len(unique)} tcp_alive={sum(1 for n in checked if n.tcp_ok)} proxy_ok={sum(1 for n in checked if n.proxy_ok)}')

if __name__ == '__main__':
    main()
