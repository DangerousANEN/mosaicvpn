#!/usr/bin/env python3
"""
MosaicVPN SEO Inspector & Audit Utility.
Reads live or local seo-report.json and provides structured insights for agents & humans.
Usage:
    python scripts/seo_analyzer.py [--remote] [--json]
"""

import sys
import json
import urllib.request

LOCAL_REPORT_PATH = "site/seo-report.json"
REMOTE_REPORT_URL = "https://sub.zxc1x1.ru/seo-report.json"

def get_report(remote=False):
    if remote:
        try:
            req = urllib.request.Request(REMOTE_REPORT_URL, headers={"User-Agent": "MosaicVPN-SEO-Agent/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode('utf-8'))
        except Exception as e:
            print(f"[WARN] Remote fetch failed ({e}), falling back to local file...", file=sys.stderr)

    with open(LOCAL_REPORT_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def print_summary(data):
    summary = data.get("summary", {})
    print("=" * 60)
    print("           MOSAICVPN SEO & INDEXING INTELLIGENCE")
    print("=" * 60)
    print(f"Domain:            {data.get('domain')}")
    print(f"Health Score:      {data.get('health_score')}%")
    print(f"Total Pages:       {summary.get('total_pages')}")
    print(f"In Sitemap:        {summary.get('indexed_in_sitemap')}")
    print(f"Canonical Cover:   {summary.get('canonical_coverage')}")
    print(f"Anti-RKN Check:    {summary.get('anti_rkn_compliance')}")
    print(f"Robots Disallow:   {summary.get('disallowed_in_robots')} paths")
    print(f"Active Clusters:   {len(data.get('keyword_clusters', []))}")
    print("-" * 60)
    print("PAGES AUDIT:")
    for p in data.get("pages", []):
        url = p.get("url")
        prio = p.get("priority")
        h1 = p.get("h1") or p.get("title")
        schemas = ",".join(p.get("schema_org", []))
        print(f"  [{prio}] {url:<45} | {h1[:30]:<30} | {schemas}")

    print("-" * 60)
    print("ACTIVE SEARCH CLUSTERS (Yandex & Google Target):")
    for c in data.get("keyword_clusters", []):
        cname = c.get("cluster_name")
        target = c.get("target_url")
        queries = len(c.get("queries", []))
        print(f"  * {cname:<25} ({queries} queries) -> {target}")
    print("=" * 60)

def main():
    remote = "--remote" in sys.argv
    as_json = "--json" in sys.argv
    data = get_report(remote=remote)

    if as_json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print_summary(data)

if __name__ == "__main__":
    main()
