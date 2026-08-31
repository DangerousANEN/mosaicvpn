#!/usr/bin/env python3
"""Rebuild /etc/sing-box-pool/config.json from fresh DB data.

Run after the collector finishes to keep the live proxy pool in sync
with healthcheck results.  Safe to invoke from a systemd ExecStartPost
or a cron job.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

POOL_CONFIG = Path('/etc/sing-box-pool/config.json')
POOL_SERVICE = 'sing-box-pool'


def pg_connect():
    import psycopg2
    pw_file = os.environ.get('MOSAIC_PG_PASSWORD_FILE', '/etc/mosaic-bot.pg.pass')
    password = Path(pw_file).read_text('utf-8').strip()
    return psycopg2.connect(
        host=os.environ.get('MOSAIC_PG_HOST', '127.0.0.1'),
        port=int(os.environ.get('MOSAIC_PG_PORT', '6767')),
        user=os.environ.get('MOSAIC_PG_USER', 'postgres'),
        dbname=os.environ.get('MOSAIC_PG_DATABASE', 'postgres'),
        password=password,
        connect_timeout=10,
    )


def main():
    conn = pg_connect()
    cur = conn.cursor()

    # ── 1. Fetch all live outbounds ──────────────────────────────
    cur.execute("""
        SELECT id, config, country_code, latency_ms, success_rate, speed_mbps
        FROM mosaic_nodes
        WHERE enabled AND proxy_ok
          AND last_checked_at >= now() - interval '24 hours'
        ORDER BY latency_ms NULLS LAST, success_rate DESC
    """)
    rows = cur.fetchall()
    if not rows:
        print('WARN: no live nodes found, keeping existing config')
        return

    # Build outbound objects with deterministic tags
    outbounds = []
    tag_by_id = {}
    by_country = {}  # country_code -> [tag]

    for node_id, config, cc, latency, srate, speed in rows:
        if not isinstance(config, dict):
            config = json.loads(config) if isinstance(config, str) else config
        tag = config.get('tag', f'pool-{len(outbounds)}')
        # Ensure unique tags
        if tag in tag_by_id.values():
            tag = f'{tag}-{len(outbounds)}'
        config['tag'] = tag
        tag_by_id[node_id] = tag
        outbounds.append(config)

        if cc:
            by_country.setdefault(cc.upper(), []).append(tag)

    # ── 2. Build urltest groups ──────────────────────────────────
    all_tags = [o['tag'] for o in outbounds]
    urltest_groups = []

    # Regional groups (rg-all, rg-eu, rg-us, rg-as)
    eu_countries = {'DE', 'NL', 'FR', 'GB', 'FI', 'SE', 'NO', 'PL', 'CZ', 'AT', 'CH', 'BE', 'IT', 'ES', 'PT', 'IE', 'DK', 'LT', 'LV', 'EE', 'RO', 'BG', 'HR', 'SK', 'SI', 'HU'}
    us_countries = {'US', 'CA'}
    as_countries = {'JP', 'SG', 'KR', 'HK', 'TW', 'IN', 'AU', 'NZ'}

    eu_tags = [t for cc in eu_countries for t in by_country.get(cc, [])]
    us_tags = [t for cc in us_countries for t in by_country.get(cc, [])]
    as_tags = [t for cc in as_countries for t in by_country.get(cc, [])]

    urltest_base = {
        'interval': '5m',
        'tolerance': 100,
        'url': 'https://www.gstatic.com/generate_204',
        'idle_timeout': '10m',
    }

    urltest_groups.append({
        **urltest_base,
        'type': 'urltest', 'tag': 'rg-all',
        'outbounds': all_tags[:80],
    })
    if eu_tags:
        urltest_groups.append({
            **urltest_base,
            'type': 'urltest', 'tag': 'rg-eu',
            'outbounds': eu_tags[:40],
        })
    if us_tags:
        urltest_groups.append({
            **urltest_base,
            'type': 'urltest', 'tag': 'rg-us',
            'outbounds': us_tags[:40],
        })
    if as_tags:
        urltest_groups.append({
            **urltest_base,
            'type': 'urltest', 'tag': 'rg-as',
            'outbounds': as_tags[:40],
        })

    # Whitelist group — nodes with Reality
    cur.execute("""
        SELECT config->>'tag' FROM mosaic_nodes
        WHERE enabled AND proxy_ok AND protocol='vless'
          AND lower(config::text) LIKE '%%reality%%'
          AND last_checked_at >= now() - interval '24 hours'
        ORDER BY success_rate DESC, latency_ms NULLS LAST
        LIMIT 20
    """)
    wl_tags = [r[0] for r in cur.fetchall() if r[0] in set(all_tags)]
    if wl_tags:
        urltest_groups.append({
            **urltest_base,
            'type': 'urltest', 'tag': 'auto-whitelist',
            'outbounds': wl_tags,
            'url': 'https://yandex.ru/generate_204',
        })

    # Per-country auto groups (only for countries with 3+ nodes)
    for cc, tags in sorted(by_country.items()):
        if len(tags) >= 3:
            group_tag = f'auto-{cc.lower()}'
            url = 'https://yandex.ru/generate_204' if cc == 'RU' else 'https://www.gstatic.com/generate_204'
            urltest_groups.append({
                **urltest_base,
                'type': 'urltest', 'tag': group_tag,
                'outbounds': tags[:40],
                'url': url,
            })

    # ── 3. Build inbounds (one SOCKS per regional group) ─────────
    port_map = {
        'rg-all': 10080,
        'rg-eu': 10081,
        'rg-us': 10082,
        'rg-as': 10083,
    }
    inbounds = []
    for group in urltest_groups:
        tag = group['tag']
        if tag in port_map:
            inbounds.append({
                'type': 'socks',
                'tag': f'rg-in-{tag.replace("rg-", "")}',
                'listen': '0.0.0.0',
                'listen_port': port_map[tag],
            })

    # ── 4. Build route rules ─────────────────────────────────────
    route_rules = []
    for inb in inbounds:
        group_tag = inb['tag'].replace('rg-in-', 'rg-')
        route_rules.append({
            'inbound': [inb['tag']],
            'outbound': group_tag,
        })

    # ── 5. Assemble config ───────────────────────────────────────
    config = {
        'log': {'level': 'warning'},
        'inbounds': inbounds,
        'outbounds': outbounds + urltest_groups + [
            {'type': 'direct', 'tag': 'direct'},
            {'type': 'direct', 'tag': 'direct-out'},
        ],
        'route': {
            'rules': route_rules,
            'final': 'rg-all',
            'auto_detect_interface': True,
        },
    }

    # ── 6. Validate ──────────────────────────────────────────────
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        tmp_path = f.name

    check = subprocess.run(
        ['/usr/local/bin/sing-box', 'check', '-c', tmp_path],
        capture_output=True, text=True, timeout=15,
    )
    if check.returncode != 0:
        print(f'ERROR: sing-box check failed: {check.stderr}')
        os.unlink(tmp_path)
        return

    # ── 7. Write and restart ─────────────────────────────────────
    # Backup old config
    if POOL_CONFIG.exists():
        POOL_CONFIG.rename(POOL_CONFIG.with_suffix('.json.prev'))

    import shutil
    shutil.move(tmp_path, str(POOL_CONFIG))
    POOL_CONFIG.chmod(0o644)

    # Restart sing-box-pool
    subprocess.run(['systemctl', 'restart', POOL_SERVICE], check=True, timeout=10)

    # Stats
    total_outbounds = len(outbounds)
    total_groups = len(urltest_groups)
    country_groups = sum(1 for g in urltest_groups if g['tag'].startswith('auto-'))
    print(f'OK: outbounds={total_outbounds} urltest_groups={total_groups} '
          f'country_groups={country_groups} countries={list(by_country.keys())}')

    cur.close()
    conn.close()


if __name__ == '__main__':
    main()
