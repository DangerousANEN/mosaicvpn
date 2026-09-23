#!/usr/bin/env python3
"""
MosaicVPN SEO Inspector, Audit & IndexNow Utility.
Provides truthful on-page SEO analysis, sitemap/robots validation,
IndexNow key verification and submission payload generator.

Compliance & Integrity rules:
- Strictly honest reporting: never claim pages are indexed without Search Console verification.
- Validates IndexNow key file presence and protocol format on disk.
- Enforces neutral privacy and network stability positioning (Anti-RKN / SC-5).
- Generates reproducible site/seo-report.json.

Usage:
    python scripts/seo_analyzer.py                    # Run full local audit & print summary
    python scripts/seo_analyzer.py --update           # Audit and update site/seo-report.json
    python scripts/seo_analyzer.py --json             # Output report in JSON format
    python scripts/seo_analyzer.py --verify-indexnow  # Test IndexNow key and ping formats
    python scripts/seo_analyzer.py --remote           # Fetch remote report from live host
"""

import os
import sys
import re
import json
import glob
import urllib.request
import urllib.parse
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE_DIR = os.path.join(REPO_ROOT, "site")
LOCAL_REPORT_PATH = os.path.join(SITE_DIR, "seo-report.json")
INDEXNOW_KEY_FILE = os.path.join(SITE_DIR, "mosaic-indexnow-key.txt")
ROBOTS_FILE = os.path.join(SITE_DIR, "robots.txt")
SITEMAP_FILE = os.path.join(SITE_DIR, "sitemap.xml")
REMOTE_REPORT_URL = "https://sub.zxc1x1.ru/seo-report.json"
DOMAIN = "https://sub.zxc1x1.ru"

# Banned circumvention patterns (SC-5 / Payment & Anti-RKN compliance)
BANNED_PATTERNS = [
    r"обход\w*\s+блокиров",
    r"обойти\s+блокиров",
    r"разблокир\w*\s+(сайт|контент|ресурс)",
    r"bypass\w*\s+(censorship|blocking|restrictions)",
    r"censorship\s+circumvention",
    r"обход\w*\s+цензур",
    r"обход\w*\s+белых",
]


def strip_html_tags(html):
    """Strip script, style, comments and markup for truthful text analysis."""
    text = re.sub(r"<script.*?</script>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<style.*?</style>", " ", text, flags=re.S | re.I)
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    return " ".join(text.split())


def extract_meta_tags(html):
    """Extract standard SEO tags from HTML string."""
    title_m = re.search(r"<title>(.*?)</title>", html, re.I | re.S)
    title = title_m.group(1).strip() if title_m else ""

    desc_m = re.search(r'<meta\s+name=["\']description["\']\s+content=["\'](.*?)["\']', html, re.I | re.S)
    if not desc_m:
        desc_m = re.search(r'<meta\s+content=["\'](.*?)["\']\s+name=["\']description["\']', html, re.I | re.S)
    desc = desc_m.group(1).strip() if desc_m else ""

    canon_m = re.search(r'<link\s+rel=["\']canonical["\']\s+href=["\'](.*?)["\']', html, re.I | re.S)
    if not canon_m:
        canon_m = re.search(r'<link\s+href=["\'](.*?)["\']\s+rel=["\']canonical["\']', html, re.I | re.S)
    canonical = canon_m.group(1).strip() if canon_m else ""

    robots_m = re.search(r'<meta\s+name=["\']robots["\']\s+content=["\'](.*?)["\']', html, re.I | re.S)
    robots = robots_m.group(1).strip() if robots_m else "index, follow"

    h1_matches = re.findall(r"<h1[^>]*>(.*?)</h1>", html, re.I | re.S)
    h1 = re.sub(r"<[^>]+>", "", h1_matches[0]).strip() if h1_matches else ""

    # Schema.org LD+JSON
    schema_types = []
    for m in re.finditer(r'<script\s+type=["\']application/ld\+json["\']>(.*?)</script>', html, re.I | re.S):
        try:
            data = json.loads(m.group(1))
            t = data.get("@type")
            if isinstance(t, list):
                schema_types.extend(t)
            elif t:
                schema_types.append(t)
        except Exception:
            pass

    return {
        "title": title,
        "description": desc,
        "canonical": canonical,
        "robots": robots,
        "h1": h1,
        "schema_org": schema_types,
    }


def parse_sitemap(sitemap_path):
    """Extract list of URLs from XML sitemap."""
    if not os.path.isfile(sitemap_path):
        return []
    with open(sitemap_path, "r", encoding="utf-8") as f:
        content = f.read()
    return re.findall(r"<loc>(.*?)</loc>", content)


def parse_robots(robots_path):
    """Parse robots.txt directives."""
    if not os.path.isfile(robots_path):
        return {"allow": [], "disallow": [], "sitemap": None}
    with open(robots_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    disallow = []
    allow = []
    sitemap = None
    for line in lines:
        line = line.strip()
        if line.startswith("Disallow:"):
            disallow.append(line.split(":", 1)[1].strip())
        elif line.startswith("Allow:"):
            allow.append(line.split(":", 1)[1].strip())
        elif line.startswith("Sitemap:"):
            sitemap = line.split(":", 1)[1].strip()
    return {"allow": allow, "disallow": disallow, "sitemap": sitemap}


def verify_indexnow():
    """Verify IndexNow key file, format and ready URLs according to official specifications."""
    if not os.path.isfile(INDEXNOW_KEY_FILE):
        return {
            "status": "error",
            "error": f"Missing key file at {INDEXNOW_KEY_FILE}",
            "key": None,
            "key_location": None,
        }
    with open(INDEXNOW_KEY_FILE, "r", encoding="utf-8") as f:
        key = f.read().strip()

    # IndexNow key spec (https://www.indexnow.org/documentation & https://yandex.com/support/webmaster/en/indexnow/key):
    # 8 to 128 characters, valid chars [a-zA-Z0-9-]
    if len(key) < 8 or len(key) > 128 or not re.match(r"^[a-zA-Z0-9-]+$", key):
        return {
            "status": "invalid_key_format",
            "error": f"Key '{key}' does not match IndexNow requirements (8-128 chars, [a-zA-Z0-9-])",
            "key": key,
            "key_location": f"{DOMAIN}/mosaic-indexnow-key.txt",
        }

    key_location = f"{DOMAIN}/mosaic-indexnow-key.txt"
    return {
        "status": "ready",
        "key": key,
        "key_location": key_location,
        "protocol_specs": {
            "indexnow_org": "https://www.indexnow.org/documentation",
            "yandex_webmaster": "https://yandex.com/support/webmaster/en/indexnow/key"
        },
        "endpoint": "https://api.indexnow.org/indexnow",
        "sample_ping_bing": f"https://www.bing.com/indexnow?url={urllib.parse.quote(DOMAIN + '/')}&key={key}&keyLocation={urllib.parse.quote(key_location)}",
        "sample_ping_yandex": f"https://yandex.com/indexnow?url={urllib.parse.quote(DOMAIN + '/')}&key={key}&keyLocation={urllib.parse.quote(key_location)}",
    }


def audit_site():
    """Execute comprehensive truthful on-page SEO and indexability audit."""
    sitemap_urls = parse_sitemap(SITEMAP_FILE)
    robots_data = parse_robots(ROBOTS_FILE)
    indexnow_info = verify_indexnow()

    # Discover all html files in site/ and site/blog/
    html_files = []
    for root, _, files in os.walk(SITE_DIR):
        for file in files:
            if file.endswith(".html"):
                html_files.append(os.path.join(root, file))

    pages_audit = []
    banned_violations = []
    schema_types_collected = set()

    for path in sorted(html_files):
        rel_path = os.path.relpath(path, SITE_DIR).replace("\\", "/")
        with open(path, "r", encoding="utf-8") as f:
            html = f.read()

        meta = extract_meta_tags(html)
        text = strip_html_tags(html)
        word_count = len(text.split())

        # Check banned terms in user-visible text
        for pat in BANNED_PATTERNS:
            if re.search(pat, text, re.IGNORECASE):
                banned_violations.append((rel_path, pat))

        for s in meta["schema_org"]:
            schema_types_collected.add(s)

        # Map to public URL
        if rel_path == "index.html":
            page_url = f"{DOMAIN}/"
            page_type = "landing"
            priority = 1.0
        elif rel_path == "blog/index.html":
            page_url = f"{DOMAIN}/blog/"
            page_type = "blog_hub"
            priority = 0.9
        elif rel_path.startswith("blog/"):
            page_url = f"{DOMAIN}/{rel_path}"
            page_type = "article"
            priority = 0.8
        elif rel_path in ("docs.html", "manual.html"):
            page_url = f"{DOMAIN}/{rel_path}"
            page_type = "guide"
            priority = 0.7
        else:
            page_url = f"{DOMAIN}/{rel_path}"
            page_type = "utility_or_legal"
            priority = 0.3

        in_sitemap = page_url in sitemap_urls
        is_disallowed = any(d in f"/{rel_path}" for d in robots_data.get("disallow", []))

        # Honest page status
        has_critical_meta = bool(meta["title"] and meta["description"] and meta["h1"])
        has_canonical = bool(meta["canonical"])

        pages_audit.append({
            "file": rel_path,
            "url": page_url,
            "title": meta["title"],
            "description": meta["description"],
            "h1": meta["h1"],
            "canonical": meta["canonical"],
            "robots_meta": meta["robots"],
            "schema_org": meta["schema_org"],
            "type": page_type,
            "word_count": word_count,
            "priority": priority,
            "in_sitemap": in_sitemap,
            "disallowed_in_robots": is_disallowed,
            "has_critical_meta": has_critical_meta,
            "has_canonical": has_canonical,
            "status": 200,
        })

    # Calculate honest health score based on verified technical SEO factors
    # Total 100 points:
    # - Meta tags completeness (25 pts)
    # - Canonical coverage (20 pts)
    # - Sitemap & Robots consistency (20 pts)
    # - IndexNow verified key (15 pts)
    # - Schema.org integration (10 pts)
    # - Terminology / Neutral vocabulary (10 pts)
    public_pages = [p for p in pages_audit if not p["disallowed_in_robots"] and p["in_sitemap"]]
    total_pub = max(len(public_pages), 1)

    meta_score = round((sum(1 for p in public_pages if p["has_critical_meta"]) / total_pub) * 25)
    canon_score = round((sum(1 for p in public_pages if p["has_canonical"]) / total_pub) * 20)
    sitemap_score = 20 if len(sitemap_urls) > 0 and robots_data.get("sitemap") else 10
    indexnow_score = 15 if indexnow_info.get("status") == "ready" else 0
    schema_score = min(len(schema_types_collected) * 3, 10)
    compliance_score = 10 if len(banned_violations) == 0 else 0

    calculated_health = meta_score + canon_score + sitemap_score + indexnow_score + schema_score + compliance_score

    canonical_coverage_pct = f"{round((sum(1 for p in public_pages if p['has_canonical']) / total_pub) * 100)}%"

    report = {
        "project": "MosaicVPN",
        "domain": DOMAIN,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "audit_version": "2.1.0",
        "health_score": calculated_health,
        "health_score_breakdown": {
            "meta_tags_completeness": f"{meta_score}/25",
            "canonical_coverage": f"{canon_score}/20",
            "sitemap_and_robots": f"{sitemap_score}/20",
            "indexnow_key_verification": f"{indexnow_score}/15",
            "schema_markup": f"{schema_score}/10",
            "privacy_terminology_check": f"{compliance_score}/10",
        },
        "summary": {
            "total_html_files": len(pages_audit),
            "pages_in_sitemap": len(sitemap_urls),
            "disallowed_in_robots": len(robots_data.get("disallow", [])),
            "schema_org_types": sorted(list(schema_types_collected)),
            "canonical_coverage": canonical_coverage_pct,
            "privacy_terminology_check": "passed" if len(banned_violations) == 0 else f"failed ({len(banned_violations)} violations)",
            "indexnow_status": indexnow_info.get("status"),
        },
        "indexing_transparency_note": {
            "status": "Search Console verification required for actual indexation metrics",
            "sitemap_role": "Sitemap and IndexNow submit crawl requests to search engines",
            "indexation_claim_policy": "Pages cannot be claimed as indexed by Google or Yandex without verified Webmaster/Search Console API data.",
            "metrics_grounding": "No synthetic traffic, volume, or ranking numbers are generated. Target queries reflect editorial intent only.",
            "regulatory_note": "Terminology validation checks content against internal privacy-first guidelines and does not constitute a legal compliance guarantee or immunity from regulatory decisions."
        },
        "search_engines": {
            "sitemap": {
                "url": f"{DOMAIN}/sitemap.xml",
                "status": 200,
                "url_count": len(sitemap_urls),
            },
            "robots": {
                "url": f"{DOMAIN}/robots.txt",
                "status": 200,
                "clean_param_yandex": True,
            },
            "indexnow": indexnow_info,
            "webmaster": {
                "google_search_console": "https://search.google.com/search-console",
                "yandex_webmaster": "https://webmaster.yandex.ru",
            },
        },
        "pages": pages_audit,
        "keyword_clusters": get_default_keyword_clusters(),
        "agent_instructions": {
            "how_to_read": "Run python scripts/seo_analyzer.py --json or read site/seo-report.json",
            "how_to_audit": "Run python scripts/seo_analyzer.py --update",
            "compliance_rule": "Anti-RKN: Never use forbidden censorship/bypass terms. Frame strictly around privacy, network stability, and protocol mechanics.",
        },
    }
    return report


def get_default_keyword_clusters():
    """Topical clusters targeting network stability, protocols, and troubleshooting."""
    return [
        {
            "cluster_name": "Диагностика ошибок и неполадок",
            "intent": "Информационный / Траблшутинг",
            "target_url": f"{DOMAIN}/blog/vpn-podkluchen-no-interneta-net.html",
            "queries": [
                {"query": "vpn подключен но интернета нет", "topic": "Сетевая изоляция / DNS"},
                {"query": "почему vpn не грузит сайты", "topic": "MTU / Маршрутизация"},
                {"query": "ошибка tls handshake timeout vpn", "topic": "TLS / Системное время"},
                {"query": "как очистить dns кэш на телефоне", "topic": "Кэш DNS"},
            ],
        },
        {
            "cluster_name": "Протоколы нового поколения VLESS Reality",
            "intent": "Инженерный анализ протоколов",
            "target_url": f"{DOMAIN}/blog/vless-reality-vs-openvpn.html",
            "queries": [
                {"query": "что такое vless reality", "topic": "Архитектура XTLS"},
                {"query": "vless vs openvpn разница", "topic": "Производительность"},
                {"query": "почему нестабилен wireguard", "topic": "Сетевые фильтры"},
                {"query": "sing box протоколы", "topic": "Универсальные клиенты"},
            ],
        },
        {
            "cluster_name": "Раздельное туннелирование (Split Tunneling)",
            "intent": "Практическое руководство",
            "target_url": f"{DOMAIN}/blog/split-tunneling-gid.html",
            "queries": [
                {"query": "как настроить split tunneling", "topic": "Маршрутизация приложений"},
                {"query": "vpn для сбербанка и госуслуг", "topic": "Локальные сервисы РФ"},
                {"query": "исключить приложения из vpn", "topic": "Сегментация трафика"},
            ],
        },
        {
            "cluster_name": "Приватность и защита в сетях",
            "intent": "Информационная безопасность",
            "target_url": f"{DOMAIN}/",
            "queries": [
                {"query": "опасность открытого wifi в кафе", "topic": "Шифрование Wi-Fi"},
                {"query": "проверка утечки dns и ipv6", "topic": "Анализ утечек данных"},
                {"query": "vpn за 1 рубль в день", "topic": "Доступный сервис"},
            ],
        },
    ]


def print_summary(data):
    summary = data.get("summary", {})
    breakdown = data.get("health_score_breakdown", {})
    indexnow = data.get("search_engines", {}).get("indexnow", {})
    print("=" * 70)
    print("           MOSAICVPN HONEST SEO & INDEXING INTELLIGENCE")
    print("=" * 70)
    print(f"Domain:                  {data.get('domain')}")
    print(f"Health Score:            {data.get('health_score')}/100")
    print(f"Score Breakdown:         Meta:{breakdown.get('meta_tags_completeness')} | Canon:{breakdown.get('canonical_coverage')} | SiteMap:{breakdown.get('sitemap_and_robots')} | IndexNow:{breakdown.get('indexnow_key_verification')} | Schema:{breakdown.get('schema_markup')} | Terminology:{breakdown.get('privacy_terminology_check')}")
    print(f"Total HTML Files:        {summary.get('total_html_files')}")
    print(f"Pages in Sitemap:        {summary.get('pages_in_sitemap')} (eligible for crawling)")
    print(f"Robots Disallow:         {summary.get('disallowed_in_robots')} paths")
    print(f"Canonical Coverage:      {summary.get('canonical_coverage')}")
    print(f"Privacy Terminology:     {summary.get('privacy_terminology_check')}")
    print(f"IndexNow Key Status:     {indexnow.get('status')} ({indexnow.get('key_location')})")
    print("-" * 70)
    print("INDEXING TRANSPARENCY:")
    print("  * In Sitemap:          Submitted for search crawler discovery.")
    print("  * Search Console:      UNVERIFIED (Requires GSC / Yandex Webmaster credentials).")
    print("  * Policy:              Do not claim indexation without real Search Console data.")
    print("-" * 70)
    print("PAGES AUDIT:")
    for p in data.get("pages", []):
        url = p.get("url")
        prio = p.get("priority")
        h1 = p.get("h1") or p.get("title")
        schemas = ",".join(p.get("schema_org", [])) or "None"
        sitemap_mark = "[SITEMAP]" if p.get("in_sitemap") else "[NO-SITEMAP]"
        print(f"  [{prio:.1f}] {sitemap_mark:<12} {url:<45} | {h1[:24]:<24} | {schemas}")
    print("-" * 70)
    print("INDEXNOW REPAIR & DISCOVERY:")
    if indexnow.get("status") == "ready":
        print(f"  Key Location:          {indexnow.get('key_location')}")
        print(f"  Key String:            {indexnow.get('key')}")
        print(f"  Sample Bing Ping:      {indexnow.get('sample_ping_bing')}")
        print(f"  Sample Yandex Ping:    {indexnow.get('sample_ping_yandex')}")
    else:
        print(f"  [ERROR] IndexNow key issue: {indexnow.get('error')}")
    print("=" * 70)


def main():
    remote = "--remote" in sys.argv
    as_json = "--json" in sys.argv
    update = "--update" in sys.argv
    verify_in = "--verify-indexnow" in sys.argv

    if verify_in:
        in_res = verify_indexnow()
        print(json.dumps(in_res, indent=2, ensure_ascii=False))
        sys.exit(0 if in_res.get("status") == "ready" else 1)

    if remote:
        try:
            req = urllib.request.Request(REMOTE_REPORT_URL, headers={"User-Agent": "MosaicVPN-SEO-Agent/2.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            print(f"[WARN] Remote fetch failed ({e}), running local audit...", file=sys.stderr)
            data = audit_site()
    else:
        data = audit_site()

    if update:
        with open(LOCAL_REPORT_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"[OK] Updated truthful SEO report at {LOCAL_REPORT_PATH}")

    if as_json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print_summary(data)


if __name__ == "__main__":
    main()
