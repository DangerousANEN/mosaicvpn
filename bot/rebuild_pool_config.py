#!/opt/mosaic-bot/venv/bin/python
"""rebuild_pool_config.py — Rebuild /etc/sing-box-pool/config.json from DB v3.

Changes in v3:
- interrupt_exist_connections: false across ALL urltest groups (CRITICAL for stability!)
- interval: 3m, tolerance: 50
- Strict exclusion of own server (5.175.188.152, *.zxc1x1.ru)
- Strict exclusion of xhttp / splithttp
- Inbounds bound strictly to 127.0.0.1 (ports 10080-10083)
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

POOL_CONFIG  = Path('/etc/sing-box-pool/config.json')
POOL_SERVICE = 'sing-box-pool'
SING_BOX     = '/usr/local/bin/sing-box'

HEALTH_TTL_HOURS = int(os.environ.get('MOSAIC_POOL_HEALTH_TTL_HOURS', '6'))

OWN_HOSTS = {
    '5.175.188.152',
    'sub.zxc1x1.ru',
    'panel.zxc1x1.ru',
    'zxc1x1.ru',
}

def is_forbidden_host(host: str) -> bool:
    if not host:
        return True
    h = host.lower()
    return h in OWN_HOSTS or any(h.endswith('.' + o) for o in OWN_HOSTS)

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
    cur  = conn.cursor()

    # ── 1. Fetch all live outbounds ordered by composite_score ───────────────
    cur.execute("""
        SELECT id, config, COALESCE(exit_country_code, country_code) as cc,
               latency_ms, success_rate, speed_mbps,
               COALESCE(composite_score, 0) AS score
        FROM mosaic_nodes
        WHERE enabled AND proxy_ok
          AND last_checked_at >= now() - make_interval(hours => %s)
        ORDER BY COALESCE(composite_score, 0) DESC NULLS LAST, latency_ms ASC NULLS LAST
    """, (HEALTH_TTL_HOURS,))
    rows = cur.fetchall()

    if not rows:
        print('WARN: no live nodes found; keeping existing config')
        cur.close()
        conn.close()
        return

    outbounds  = []
    tag_by_id  = {}
    tag_set    = set()
    by_country: dict[str, list[str]] = {}

    for node_id, config, cc, latency, srate, speed, score in rows:
        if not isinstance(config, dict):
            config = json.loads(config) if isinstance(config, str) else {}

        # Protocol & transport safety check
        ob_type = str(config.get('type') or '').lower()
        if ob_type not in {'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'hysteria2'}:
            continue
        transport = config.get('transport')
        if isinstance(transport, dict):
            ttype = str(transport.get('type') or '').lower()
            if ttype in ('xhttp', 'splithttp'):
                continue
        server = config.get('server') or config.get('server_address')
        if is_forbidden_host(server):
            continue

        tag = config.get('tag', f'pool-{len(outbounds)}')
        if tag in tag_set:
            tag = f'{tag}-{len(outbounds)}'
        config['tag'] = tag
        tag_set.add(tag)
        tag_by_id[node_id] = tag
        outbounds.append(config)
        if cc:
            by_country.setdefault(cc.upper(), []).append(tag)

    # ── 2. Build urltest groups ───────────────────────────────────────────────
    all_tags = [o['tag'] for o in outbounds]

    eu_countries = {'DE','NL','FR','GB','FI','SE','NO','PL','CZ','AT','CH',
                    'BE','IT','ES','PT','IE','DK','LT','LV','EE','RO','BG',
                    'HR','SK','SI','HU'}
    us_countries = {'US', 'CA'}
    as_countries = {'JP', 'SG', 'KR', 'HK', 'TW', 'IN', 'AU', 'NZ'}

    eu_tags = [t for cc in eu_countries for t in by_country.get(cc, [])]
    us_tags = [t for cc in us_countries for t in by_country.get(cc, [])]
    as_tags = [t for cc in as_countries for t in by_country.get(cc, [])]

    urltest_base = {
        'interval': '3m',
        'tolerance': 50,
        'url': 'https://www.gstatic.com/generate_204',
        'idle_timeout': '10m',
        'interrupt_exist_connections': False,
    }

    urltest_groups = []
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

    # Reality VLESS group
    cur.execute("""
        SELECT config->>'tag'
        FROM mosaic_nodes
        WHERE enabled AND proxy_ok AND protocol = 'vless'
          AND lower(config::text) LIKE '%%reality%%'
          AND last_checked_at >= now() - make_interval(hours => %s)
        ORDER BY COALESCE(composite_score, 0) DESC NULLS LAST
        LIMIT 20
    """, (HEALTH_TTL_HOURS,))
    wl_tags = [r[0] for r in cur.fetchall() if r[0] in tag_set]
    if wl_tags:
        urltest_groups.append({
            **urltest_base,
            'type': 'urltest', 'tag': 'auto-whitelist',
            'outbounds': wl_tags,
            'url': 'https://yandex.ru/generate_204',
        })

    # Per-country auto groups (≥3 nodes, ≤40 members)
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

    # ── 3. Build inbounds (loopback only) ─────────────────────────────────────
    port_map = {
        'rg-all': 10080,
        'rg-eu':  10081,
        'rg-us':  10082,
        'rg-as':  10083,
    }
    inbounds = []
    for group in urltest_groups:
        tag = group['tag']
        if tag in port_map:
            in_tag = f'rg-in-{tag.replace("rg-", "")}'
            inbounds.append({
                'type': 'socks',
                'tag': in_tag,
                'listen': '127.0.0.1',
                'listen_port': port_map[tag],
            })

    # ── 4. Build route rules ──────────────────────────────────────────────────
    route_rules = []
    for inb in inbounds:
        group_tag = inb['tag'].replace('rg-in-', 'rg-')
        route_rules.append({
            'inbound': [inb['tag']],
            'outbound': group_tag,
        })

    # ── 5. Assemble config ────────────────────────────────────────────────────
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

    # ── 6. Validate ───────────────────────────────────────────────────────────
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        tmp_path = f.name

    check = subprocess.run(
        [SING_BOX, 'check', '-c', tmp_path],
        capture_output=True, text=True, timeout=15,
    )
    if check.returncode != 0:
        print(f'ERROR: sing-box check failed:\n{check.stderr}', file=sys.stderr)
        os.unlink(tmp_path)
        cur.close()
        conn.close()
        sys.exit(1)

    # ── 7. Atomic write and restart ───────────────────────────────────────────
    import shutil
    if POOL_CONFIG.exists():
        POOL_CONFIG.rename(POOL_CONFIG.with_suffix('.json.prev'))
    shutil.move(tmp_path, str(POOL_CONFIG))
    POOL_CONFIG.chmod(0o644)

    subprocess.run(['systemctl', 'restart', POOL_SERVICE], check=True, timeout=10)

    total_outbounds   = len(outbounds)
    total_groups      = len(urltest_groups)
    country_groups    = sum(1 for g in urltest_groups if g['tag'].startswith('auto-'))
    countries_present = sorted(by_country)
    print(
        f'OK: outbounds={total_outbounds} urltest_groups={total_groups} '
        f'country_groups={country_groups} countries={countries_present} '
        f'health_ttl_hours={HEALTH_TTL_HOURS}'
    )

    cur.close()
    conn.close()


if __name__ == '__main__':
    main()
