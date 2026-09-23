#!/usr/bin/env python3
"""
scripts/seo_sandbox_test.py
===========================
Playwright DOM-level test suite for MosaicVPN SEO, mobile responsiveness,
layout overflow, and interactive components.

Executes EXCLUSIVELY inside the Docker container `Developer-sandbox`.
- Isolated temporary directory in container.
- Dynamic random available port (bind to port 0).
- Dedicated process tracking & clean shutdown of its own server only.
- Genuine Playwright DOM interactions (form selection, button clicks, async data render).
- Mobile (375x812) and Desktop (1280x800) layout overflow checks (scrollWidth <= innerWidth).
- Real-time console error & pageerror event capture (assert 0 unhandled errors).
- Screenshot capture with exact container paths and sizes reported.
"""

import sys
import os
import time
import json
import socket
import shutil
import tempfile
import subprocess
from pathlib import Path

CONTAINER_NAME = "Developer-sandbox"
DEFAULT_HOST_REPO = Path(__file__).resolve().parent.parent

def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def run_in_container_direct(workdir_path):
    """Executes the Playwright suite inside Developer-sandbox."""
    from playwright.sync_api import sync_playwright

    print(f"\n======================================================================")
    print(f"      PLAYWRIGHT DOM & LAYOUT VERIFICATION IN {CONTAINER_NAME}")
    print(f"======================================================================")
    print(f"Working directory: {workdir_path}")

    site_dir = os.path.join(workdir_path, "site")
    screenshots_dir = os.path.join(workdir_path, "screenshots")
    os.makedirs(screenshots_dir, exist_ok=True)

    if not os.path.isdir(site_dir):
        print(f"[FAIL] site directory not found at {site_dir}")
        sys.exit(1)

    # 1. Allocate dynamic port and start server
    port = find_free_port()
    print(f"[*] Allocated dynamic isolated port: {port}")

    server_cmd = [sys.executable, "-m", "http.server", str(port), "--directory", site_dir]
    server_proc = subprocess.Popen(
        server_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    print(f"[*] Started local http.server (PID: {server_proc.pid}) on 127.0.0.1:{port}")

    # Wait for server readiness
    server_ready = False
    base_url = f"http://127.0.0.1:{port}"
    for _ in range(30):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                server_ready = True
                break
        except (OSError, ConnectionRefusedError):
            time.sleep(0.1)

    if not server_ready:
        print("[FAIL] HTTP server failed to bind within 3 seconds")
        server_proc.terminate()
        sys.exit(1)

    evidence = {
        "container": CONTAINER_NAME,
        "port": port,
        "server_pid": server_proc.pid,
        "viewports_tested": ["mobile (375x812)", "desktop (1280x800)"],
        "pages_tested": [],
        "dom_interactions": [],
        "screenshots": [],
        "console_errors": [],
        "overflow_issues": [],
        "all_passed": True
    }

    try:
        with sync_playwright() as p:
            # Launch Google Chrome with headless container flags
            chrome_path = "/usr/bin/google-chrome"
            if not os.path.exists(chrome_path):
                chrome_path = None

            launch_args = ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"]
            browser = p.chromium.launch(
                executable_path=chrome_path,
                headless=True,
                args=launch_args
            )
            print(f"[*] Playwright launched Chrome ({chrome_path or 'bundled'}) headlessly")

            viewports = {
                "desktop": {"width": 1280, "height": 800},
                "mobile": {"width": 375, "height": 812}
            }

            test_targets = [
                {
                    "path": "/seo-panel.html",
                    "name": "seo-panel",
                    "title_substr": "SEO",
                    "check_dom": True
                },
                {
                    "path": "/index.html",
                    "name": "landing",
                    "title_substr": "MosaicVPN",
                    "check_dom": True
                },
                {
                    "path": "/manual.html",
                    "name": "manual",
                    "title_substr": "сторонних",
                    "check_dom": True
                },
                {
                    "path": "/blog/vpn-podkluchen-no-interneta-net.html",
                    "name": "blog-troubleshooting",
                    "title_substr": "VPN подключен",
                    "check_dom": True
                },
                {
                    "path": "/blog/index.html",
                    "name": "blog-hub",
                    "title_substr": "Блог",
                    "check_dom": True
                }
            ]

            for target in test_targets:
                page_name = target["name"]
                target_url = f"{base_url}{target['path']}"
                print(f"\n--- Testing Target: {target['path']} ---")

                for vp_name, vp_size in viewports.items():
                    context = browser.new_context(
                        viewport=vp_size,
                        user_agent=(
                            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                            "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                            if vp_name == "mobile" else
                            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                            "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
                        )
                    )
                    page = context.new_page()

                    # Console message & Page Error capture
                    page_console_errors = []
                    page_errors = []

                    def handle_console(msg):
                        if msg.type == "error":
                            page_console_errors.append(f"[{msg.type}] {msg.text}")
                    page.on("console", handle_console)

                    def handle_pageerror(err):
                        page_errors.append(str(err))
                    page.on("pageerror", handle_pageerror)

                    # Navigate
                    resp = page.goto(target_url, wait_until="networkidle", timeout=15000)
                    status = resp.status if resp else 0
                    if status != 200:
                        print(f"  [FAIL] HTTP status {status} for {target['path']}")
                        evidence["all_passed"] = False
                    else:
                        print(f"  [PASS] {vp_name.upper()} ({vp_size['width']}x{vp_size['height']}) -> HTTP 200 OK")

                    # Title assertion
                    title = page.title()
                    assert target["title_substr"] in title, f"Title mismatch: got '{title}'"

                    # Real Layout Overflow DOM Check
                    overflow_eval = page.evaluate('''() => {
                        const docWidth = document.documentElement.scrollWidth;
                        const winWidth = window.innerWidth;
                        const overflowing = [];
                        const elements = document.querySelectorAll('*');
                        for (const el of elements) {
                            const rect = el.getBoundingClientRect();
                            if (rect.right > winWidth + 1.5 || rect.width > winWidth + 1.5) {
                                overflowing.push({
                                    tag: el.tagName.toLowerCase(),
                                    id: el.id || null,
                                    className: typeof el.className === 'string' ? el.className.trim() : null,
                                    width: Math.round(rect.width),
                                    right: Math.round(rect.right),
                                    winWidth: winWidth
                                });
                                if (overflowing.length >= 3) break;
                            }
                        }
                        return {
                            docScrollWidth: docWidth,
                            windowWidth: winWidth,
                            hasOverflow: docWidth > winWidth + 1.5,
                            overflowElements: overflowing
                        };
                    }''')

                    if overflow_eval["hasOverflow"]:
                        print(f"  [FAIL] Layout overflow detected in {vp_name}: "
                              f"docScrollWidth={overflow_eval['docScrollWidth']} > windowWidth={overflow_eval['windowWidth']}")
                        print(f"         Culprit elements: {overflow_eval['overflowElements']}")
                        evidence["overflow_issues"].append({
                            "page": target["path"],
                            "viewport": vp_name,
                            "details": overflow_eval
                        })
                        evidence["all_passed"] = False
                    else:
                        print(f"  [PASS] Layout overflow check {vp_name}: scrollWidth={overflow_eval['docScrollWidth']}px <= winWidth={overflow_eval['windowWidth']}px (no horizontal scrollbar)")

                    # Check for console errors
                    if page_console_errors or page_errors:
                        print(f"  [FAIL] Uncaught JS/Console errors in {vp_name}: {page_console_errors + page_errors}")
                        evidence["console_errors"].append({
                            "page": target["path"],
                            "viewport": vp_name,
                            "errors": page_console_errors + page_errors
                        })
                        evidence["all_passed"] = False
                    else:
                        print(f"  [PASS] Console/Pageerror logs {vp_name}: 0 errors detected")

                    # Target-specific genuine DOM interactions
                    if target["name"] == "seo-panel" and vp_name == "desktop":
                        # 1. Verify dynamic table rendering from seo-report.json
                        page.wait_for_selector("#pages-body tr", timeout=5000)
                        row_count = page.locator("#pages-body tr").count()
                        print(f"  [PASS] DOM interaction: table populated with {row_count} pages from seo-report.json")

                        # 2. Verify score and breakdown box
                        stat_health = page.locator("#stat-health").text_content()
                        stat_indexnow = page.locator("#stat-indexnow").text_content()
                        stat_compliance = page.locator("#stat-compliance").text_content()
                        breakdown_items = page.locator("#breakdown-box .breakdown-item").count()

                        print(f"  [PASS] DOM values: Health={stat_health}, IndexNow='{stat_indexnow}', Compliance='{stat_compliance}', BreakdownItems={breakdown_items}")
                        assert stat_health == "99/100", f"Expected 99/100, got {stat_health}"
                        assert "Готов" in stat_indexnow, f"IndexNow badge should indicate readiness, got {stat_indexnow}"
                        assert breakdown_items == 6, f"Expected 6 breakdown items, got {breakdown_items}"
                        assert "SC-5 PASS" not in stat_compliance, f"Compliance badge should not claim unsupported legal guarantees"

                        # 3. Perform genuine user interaction with the IndexNow generator
                        select_locator = page.locator("#indexnow-url-select")
                        select_locator.select_option("https://sub.zxc1x1.ru/blog/vless-reality-vs-openvpn.html")
                        page.click("button:has-text('Сформировать IndexNow пинг')")

                        # Verify result container became visible and has generated endpoints
                        page.wait_for_selector("#indexnow-result", state="visible", timeout=3000)
                        links_html = page.locator("#indexnow-links").inner_html()
                        assert "bing.com/indexnow" in links_html, "Bing ping missing from generated DOM"
                        assert "yandex.com/indexnow" in links_html, "Yandex ping missing from generated DOM"
                        assert "mosaic-indexnow-key" in links_html, "IndexNow key missing from generated DOM"

                        json_text = page.locator("#indexnow-json").text_content()
                        assert "api.indexnow.org/indexnow" in json_text, "Curl command missing from generated DOM"
                        assert "sub.zxc1x1.ru" in json_text, "Host missing from generated payload in DOM"
                        assert "mosaic-indexnow-key" in json_text, "IndexNow key missing from generated payload in DOM"
                        assert "vless-reality-vs-openvpn.html" in json_text, "Selected URL missing from generated payload in DOM"
                        print("  [PASS] DOM interaction: IndexNow generator select + click + payload verification SUCCESS")

                        evidence["dom_interactions"].append("seo-panel: async table load, stat asserts, form select & ping generation")

                    elif target["name"] == "manual" and vp_name == "desktop":
                        # Verify authoritative support links and absence of @mosaic_support_bot
                        html_content = page.content()
                        assert "@mosaic_support_bot" not in html_content, "Disallowed handle @mosaic_support_bot found in manual.html"
                        assert "t.me/mosaicsup" in html_content, "Authoritative support link @mosaicsup missing from manual.html"
                        print("  [PASS] DOM content: Verified authoritative support links, 0 ungrounded bot handles")
                        evidence["dom_interactions"].append("manual: support link verification")

                    elif target["name"] == "blog-troubleshooting" and vp_name == "desktop":
                        # Verify absence of blanket 60s/90s TLS drift assertions
                        html_content = page.content()
                        assert "более чем на 90 секунд" not in html_content, "Blanket 90s assertion found in blog post"
                        assert "более чем на 60 секунд" not in html_content, "Blanket 60s assertion found in blog post"
                        
                        # Verify Schema.org structured data scripts
                        schema_scripts = page.locator("script[type='application/ld+json']").all_text_contents()
                        assert len(schema_scripts) >= 1, "Schema.org LD+JSON missing"
                        types = []
                        for script_text in schema_scripts:
                            try:
                                obj = json.loads(script_text)
                                if isinstance(obj, dict):
                                    if "@graph" in obj:
                                        for item in obj["@graph"]:
                                            if isinstance(item, dict) and "@type" in item:
                                                types.append(item["@type"])
                                    elif "@type" in obj:
                                        types.append(obj["@type"])
                            except Exception:
                                pass

                        assert "TechArticle" in types and "FAQPage" in types, f"Unexpected schema types: {types}"
                        print(f"  [PASS] DOM structured data: Verified valid schema.org types {types}")
                        evidence["dom_interactions"].append("blog-troubleshooting: schema verification & blanket claim absence")

                    # Capture visual screenshot
                    ss_path = os.path.join(screenshots_dir, f"{page_name}_{vp_name}.png")
                    page.screenshot(path=ss_path, full_page=True)
                    ss_size = os.path.getsize(ss_path)
                    print(f"  [PASS] Screenshot captured: {ss_path} ({ss_size / 1024:.1f} KB)")
                    evidence["screenshots"].append({
                        "file": os.path.basename(ss_path),
                        "path": ss_path,
                        "size_bytes": ss_size,
                        "viewport": vp_name
                    })

                    context.close()

            browser.close()

    finally:
        # Strict process cleanup: terminate ONLY our own server process
        if server_proc and server_proc.poll() is None:
            print(f"[*] Stopping dedicated server (PID: {server_proc.pid})...")
            server_proc.terminate()
            try:
                server_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server_proc.kill()
            print(f"[*] Dedicated server PID {server_proc.pid} cleanly stopped")

    # Save evidence json
    evidence_file = os.path.join(workdir_path, "sandbox_qa_evidence.json")
    with open(evidence_file, "w", encoding="utf-8") as f:
        json.dump(evidence, f, indent=2, ensure_ascii=False)
    print(f"\n[*] Full QA evidence report written to: {evidence_file}")
    
    if not evidence["all_passed"]:
        print("\n[FAIL] Some Playwright assertions or layout checks failed.")
        sys.exit(1)
    else:
        print("\n[ALL PASS] Every DOM, layout, overflow, and console assertion passed successfully!")

def main():
    # If invoked with --in-container, run directly
    if "--in-container" in sys.argv:
        idx = sys.argv.index("--in-container")
        workdir = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else "/tmp"
        run_in_container_direct(workdir)
        return

    # Check if we are already inside the container
    if os.path.exists("/.dockerenv") or os.environ.get("CONTAINER_NAME") == CONTAINER_NAME:
        # Running inside container directly
        temp_dir = tempfile.mkdtemp(prefix="mosaic-qa-")
        try:
            # Copy site and scripts to temp_dir
            shutil.copytree(DEFAULT_HOST_REPO / "site", os.path.join(temp_dir, "site"))
            shutil.copytree(DEFAULT_HOST_REPO / "scripts", os.path.join(temp_dir, "scripts"))
            run_in_container_direct(temp_dir)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)
        return

    # Host execution: Orchestrate through Developer-sandbox
    print(f"[*] Dispatching test execution to Docker container: {CONTAINER_NAME}")
    temp_id = f"mosaic-qa-{int(time.time())}"
    container_temp = f"/tmp/{temp_id}"

    # 1. Create directory in container
    subprocess.run(
        ["docker", "exec", CONTAINER_NAME, "mkdir", "-p", container_temp],
        check=True
    )

    try:
        # 2. Copy site and scripts to container temp directory
        print(f"[*] Syncing site and scripts to {CONTAINER_NAME}:{container_temp}...")
        subprocess.run(
            ["docker", "cp", str(DEFAULT_HOST_REPO / "site"), f"{CONTAINER_NAME}:{container_temp}/site"],
            check=True
        )
        subprocess.run(
            ["docker", "cp", str(DEFAULT_HOST_REPO / "scripts"), f"{CONTAINER_NAME}:{container_temp}/scripts"],
            check=True
        )

        # 3. Execute seo_sandbox_test.py inside Developer-sandbox
        print(f"[*] Executing Playwright test suite in {CONTAINER_NAME}...")
        result = subprocess.run(
            [
                "docker", "exec", CONTAINER_NAME,
                "python3", f"{container_temp}/scripts/seo_sandbox_test.py",
                "--in-container", container_temp
            ]
        )

        # Copy evidence and screenshots back to host if requested
        host_results = DEFAULT_HOST_REPO / "site-qa-results"
        os.makedirs(host_results, exist_ok=True)
        subprocess.run(
            ["docker", "cp", f"{CONTAINER_NAME}:{container_temp}/sandbox_qa_evidence.json", str(host_results / "sandbox_qa_evidence.json")],
            check=False
        )
        subprocess.run(
            ["docker", "cp", f"{CONTAINER_NAME}:{container_temp}/screenshots", str(host_results / "screenshots")],
            check=False
        )
        print(f"[*] Copied test evidence and screenshots to host: {host_results}")

        if result.returncode != 0:
            print(f"[FAIL] Container execution exited with code {result.returncode}")
            sys.exit(result.returncode)

    finally:
        # 4. Clean up container temporary files with root privileges
        print(f"[*] Cleaning up temporary directory in {CONTAINER_NAME}:{container_temp}...")
        subprocess.run(
            ["docker", "exec", "-u", "0", CONTAINER_NAME, "rm", "-rf", container_temp],
            check=False
        )

if __name__ == "__main__":
    main()
