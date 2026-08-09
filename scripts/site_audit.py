"""Site compliance audit against docs/SITE_COMPLIANCE.md (SC-1..SC-6).

Checks the local files by default; pass a base URL to also verify the live
deployment. Exit code is non-zero when any criterion fails, so this can gate
a deploy.
"""
import os
import re
import sys
import glob
import json
import urllib.error
import urllib.request

SITE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "site")
BASE_URL = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else None

# Pages the compliance doc requires (section 4).
REQUIRED = ["contacts.html", "offer.html", "privacy.html", "refund.html", "terms.html"]
INDEX = "index.html"

# Phrases that frame the service around circumventing blocks (SC-5). The payment
# provider treats that framing as a risk category.
BANNED_PATTERNS = [
    r"обход\w*\s+блокиров",
    r"обойти\s+блокиров",
    r"разблокир\w*\s+(сайт|контент|ресурс)",
    r"bypass\w*\s+(censorship|blocking|restrictions)",
    r"censorship\s+circumvention",
]

# Requisites that must appear on the legal pages (SC-6).
INN = "545113651604"
FIO = "Липский"

results = []


def record(cid, name, ok, detail=""):
    results.append({"id": cid, "name": name, "ok": ok, "detail": detail})


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def strip_tags(html):
    """Text content only — banned phrases in markup or scripts are not user-visible."""
    html = re.sub(r"<script.*?</script>", " ", html, flags=re.S | re.I)
    html = re.sub(r"<style.*?</style>", " ", html, flags=re.S | re.I)
    html = re.sub(r"<!--.*?-->", " ", html, flags=re.S)
    return re.sub(r"<[^>]+>", " ", html)


def main():
    files = {os.path.basename(p): p for p in glob.glob(os.path.join(SITE_DIR, "*.html"))}

    # SC-1: every required page exists (and is served, when a base URL is given).
    missing = [p for p in REQUIRED if p not in files]
    record("SC-1", "Required pages exist", not missing,
           f"missing: {missing}" if missing else f"{len(REQUIRED)} pages present")

    if BASE_URL:
        bad = []
        for page in REQUIRED + [INDEX]:
            url = f"{BASE_URL}/{page}"
            try:
                with urllib.request.urlopen(url, timeout=15) as r:
                    if r.status != 200:
                        bad.append(f"{page}={r.status}")
            except urllib.error.HTTPError as e:
                bad.append(f"{page}={e.code}")
            except Exception as e:
                bad.append(f"{page}={type(e).__name__}")
        record("SC-1-live", "Pages return HTTP 200", not bad,
               f"failures: {bad}" if bad else f"{len(REQUIRED) + 1} pages OK")

    # SC-2: the footer of every page links to all the others.
    broken = []
    for page in REQUIRED + [INDEX]:
        if page not in files:
            continue
        html = read(files[page])
        for target in REQUIRED:
            if target == page:
                continue
            if not re.search(rf'href="[^"]*{re.escape(target)}"', html):
                broken.append(f"{page}!->{target}")
    record("SC-2", "Every page links to the others", not broken,
           f"missing links: {broken[:8]}" if broken else "cross-links complete")

    # SC-3: no internal link points at a file that does not exist.
    dead = []
    for page, path in files.items():
        for href in re.findall(r'href="([^"#?]+)"', read(path)):
            if href.startswith(("http://", "https://", "mailto:", "tel:", "//", "#")):
                continue
            target = os.path.basename(href.split("?")[0])
            if target and target.endswith(".html") and target not in files:
                dead.append(f"{page}->{href}")
    record("SC-3", "No internal link 404s", not dead,
           f"dead: {dead[:8]}" if dead else "all internal links resolve")

    # SC-4: the service card carries composition, price and terms.
    if INDEX in files:
        text = strip_tags(read(files[INDEX]))
        has_price = bool(re.search(r"\d+[\s\u00a0]*(₽|руб)", text))
        has_terms = bool(re.search(r"услов|тариф|состав|подписк", text, re.I))
        record("SC-4", "Service card has price and terms", has_price and has_terms,
               f"price={has_price} terms={has_terms}")
    else:
        record("SC-4", "Service card has price and terms", False, "index.html missing")

    # SC-5: no page frames the service as circumventing blocks.
    hits = []
    for page, path in files.items():
        text = strip_tags(read(path))
        for pat in BANNED_PATTERNS:
            for m in re.finditer(pat, text, re.I):
                snippet = text[max(0, m.start() - 40):m.end() + 40].strip()
                snippet = re.sub(r"\s+", " ", snippet)
                hits.append(f"{page}: …{snippet}…")
    record("SC-5", "No block-circumvention framing", not hits,
           f"{len(hits)} hit(s): {hits[:4]}" if hits else "wording is neutral")

    # SC-6: real requisites present on the legal pages.
    need = ["contacts.html", "offer.html", "privacy.html"]
    lacking = []
    for page in need:
        if page not in files:
            lacking.append(f"{page}=absent")
            continue
        html = read(files[page])
        if INN not in html or FIO not in html:
            lacking.append(f"{page}(inn={INN in html},fio={FIO in html})")
    placeholders = [p for p, path in files.items()
                    if "ТРЕБУЕТСЯ ОТ ВЛАДЕЛЬЦА" in read(path)]
    record("SC-6", "Real requisites, no placeholders",
           not lacking and not placeholders,
           f"lacking={lacking} placeholders={placeholders}"
           if (lacking or placeholders) else "INN + name on all legal pages")

    # Report
    width = max(len(r["name"]) for r in results)
    print(f"{'ID':<10}{'CRITERION':<{width + 2}}RESULT   DETAIL")
    for r in results:
        mark = "PASS" if r["ok"] else "FAIL"
        print(f"{r['id']:<10}{r['name']:<{width + 2}}{mark:<9}{r['detail']}")

    failed = [r["id"] for r in results if not r["ok"]]
    print()
    if failed:
        print(f"FAILED: {', '.join(failed)}")
    else:
        print(f"All {len(results)} criteria pass.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
