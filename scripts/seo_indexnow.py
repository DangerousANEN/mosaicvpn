#!/usr/bin/env python3
"""
MosaicVPN IndexNow Submission & Verification Tool.
Enables instant notification to search engines (Bing, Yandex, Seznam, Naver)
when URLs are created, updated, or deleted.

Compliance & Security:
- Verifies local key file: site/mosaic-indexnow-key.txt
- Uses standard IndexNow keyLocation parameter
- Never discloses private server tokens or customer keys
- Supports dry-run testing and batch URL submission

Usage:
    python scripts/seo_indexnow.py --verify
    python scripts/seo_indexnow.py --dry-run
    python scripts/seo_indexnow.py --submit https://sub.zxc1x1.ru/blog/
    python scripts/seo_indexnow.py --submit-all
"""

import os
import sys
import re
import json
import argparse
import urllib.request
import urllib.parse
import urllib.error
import xml.etree.ElementTree as ET


def validate_urls(urls):
    """Reject invalid or off-host submissions before contacting the provider."""
    unique = list(dict.fromkeys(urls))
    if not unique or len(unique) > 10000:
        raise ValueError("IndexNow requires 1 to 10000 unique URLs per request")
    for value in unique:
        parsed = urllib.parse.urlsplit(value)
        if (parsed.scheme not in ("http", "https") or parsed.hostname != DOMAIN
                or parsed.username is not None or parsed.password is not None
                or parsed.port is not None or parsed.fragment
                or any(c.isspace() or ord(c) < 32 for c in value)):
            raise ValueError("Submission URL must be an absolute same-host HTTP(S) URL without credentials or fragment")
    return unique


def verify_remote_key(key):
    """Ownership requires exact public content, not merely a local file."""
    url = f"{HOST_URL}/mosaic-indexnow-key.txt"
    with urllib.request.urlopen(url, timeout=15) as response:
        if response.getcode() != 200 or response.geturl() != url:
            raise ValueError("Public key URL must return HTTP 200 without redirect")
        if response.read(1024).decode("utf-8").strip() != key:
            raise ValueError("Public key content does not match the local key")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE_DIR = os.path.join(REPO_ROOT, "site")
KEY_FILE = os.path.join(SITE_DIR, "mosaic-indexnow-key.txt")
SITEMAP_FILE = os.path.join(SITE_DIR, "sitemap.xml")

DOMAIN = "sub.zxc1x1.ru"
HOST_URL = f"https://{DOMAIN}"
INDEXNOW_API = "https://api.indexnow.org/indexnow"


def read_key():
    """Read and validate the IndexNow key from the local static key file."""
    if not os.path.isfile(KEY_FILE):
        raise FileNotFoundError(f"IndexNow key file missing at: {KEY_FILE}")
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        key = f.read().strip()
    if len(key) < 8 or len(key) > 128:
        raise ValueError(f"IndexNow key length must be 8-128 chars, found {len(key)}")
    if not re.match(r"^[a-zA-Z0-9-]+$", key):
        raise ValueError("IndexNow key must contain only alphanumeric characters and hyphens")
    return key


def get_sitemap_urls():
    """Retrieve all URLs listed in the XML sitemap."""
    if not os.path.isfile(SITEMAP_FILE):
        return []
    root = ET.parse(SITEMAP_FILE).getroot()
    return [element.text.strip() for element in root.iter()
            if element.tag.rsplit("}", 1)[-1] == "loc" and element.text]


def verify_setup():
    """Verify local files and display IndexNow diagnostics."""
    print("=" * 65)
    print("           INDEXNOW PROTOCOL DIAGNOSTIC & VERIFICATION")
    print("=" * 65)
    try:
        key = read_key()
        key_loc = f"{HOST_URL}/mosaic-indexnow-key.txt"
        print(f"[OK] Key File:           {KEY_FILE}")
        print(f"[OK] Key Content:        {key}")
        print(f"[OK] Key Location URL:   {key_loc}")
        print(f"[OK] Key Length:         {len(key)} chars (Valid)")

        urls = get_sitemap_urls()
        print(f"[OK] Sitemap Found:      {len(urls)} URLs ready for submission")

        print("\nSample GET Ping URL (Bing/Microsoft):")
        bing_ping = f"https://www.bing.com/indexnow?url={urllib.parse.quote(HOST_URL + '/')}&key={key}&keyLocation={urllib.parse.quote(key_loc)}"
        print(f"  {bing_ping}")

        print("\nSample GET Ping URL (Yandex):")
        yandex_ping = f"https://yandex.com/indexnow?url={urllib.parse.quote(HOST_URL + '/')}&key={key}&keyLocation={urllib.parse.quote(key_loc)}"
        print(f"  {yandex_ping}")

        print("\nNginx Route Requirement:")
        print("  Ensure /mosaic-indexnow-key.txt is served statically with 200 OK:")
        print("  location = /mosaic-indexnow-key.txt { root /etc/letsencrypt/landing; }")
        print("=" * 65)
        return True
    except Exception as e:
        print(f"[ERROR] Verification failed: {e}")
        print("=" * 65)
        return False


def submit_urls(urls, dry_run=False):
    """Submit a batch of URLs to the IndexNow API."""
    urls = validate_urls(urls)
    key = read_key()
    key_loc = f"{HOST_URL}/mosaic-indexnow-key.txt"

    payload = {
        "host": DOMAIN,
        "key": key,
        "keyLocation": key_loc,
        "urlList": urls,
    }

    payload_bytes = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")

    print(f"Preparing IndexNow submission for {len(urls)} URL(s)...")
    if dry_run:
        print("[DRY-RUN] Would send POST request to:", INDEXNOW_API)
        print("[DRY-RUN] Headers: Content-Type: application/json; charset=utf-8")
        print("[DRY-RUN] Payload:")
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return True

    try:
        verify_remote_key(key)
        req = urllib.request.Request(
            INDEXNOW_API,
            data=payload_bytes,
            headers={
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "MosaicVPN-IndexNow-Bot/1.0",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            status_code = resp.getcode()
            if status_code == 200:
                print("[RECEIVED] URLs received; crawling and indexing are not guaranteed")
                return True
            if status_code == 202:
                print("[PENDING] URLs received; ownership key validation pending")
                return True
            print(f"[UNEXPECTED] HTTP {status_code}; submission not confirmed")
            return False
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"[HTTP {e.code}] Submission failed: {body}")
        return False
    except Exception as e:
        print(f"[NETWORK ERROR] Could not contact {INDEXNOW_API}: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="MosaicVPN IndexNow Submission & Verification Tool")
    parser.add_argument("--verify", action="store_true", help="Verify local IndexNow key file and configuration")
    parser.add_argument("--dry-run", action="store_true", help="Show payload and pings without contacting API")
    parser.add_argument("--submit", type=str, help="Submit a specific URL")
    parser.add_argument("--submit-all", action="store_true", help="Submit all URLs from sitemap.xml")

    args = parser.parse_args()

    if args.verify or (not args.submit and not args.submit_all and not args.dry_run):
        ok = verify_setup()
        sys.exit(0 if ok else 1)

    if args.dry_run and not args.submit and not args.submit_all:
        urls = get_sitemap_urls()[:3]
        submit_urls(urls, dry_run=True)
        sys.exit(0)

    urls = []
    if args.submit:
        urls = [args.submit]
    elif args.submit_all:
        urls = get_sitemap_urls()

    if not urls:
        print("[WARN] No URLs selected for submission.")
        sys.exit(1)

    ok = submit_urls(urls, dry_run=args.dry_run)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
