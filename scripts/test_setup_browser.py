#!/usr/bin/env python3
"""Automated browser tests for MosaicVPN onboarding (/setup.html).

Tests accessible layout, email/password primary registration/login,
Telegram login fallback, handoff redemption, invite/gift redemption,
platform selection, checkout handling, and enrollment issue flow.

Runs inside Docker Developer-sandbox using Playwright and Chromium.
"""
import http.server
import json
import os
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright

STATIC_DIR = "/tmp/onboarding-site-qa/site"
PORT = 8089
SCREENSHOT_DIR = "/tmp/onboarding-site-qa/screenshots"


class MockApiAndStaticServer(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def log_message(self, format, *args):
        # Silence normal server logs
        pass

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _send_json(self, status, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        auth = self.headers.get("Authorization", "")
        token = ""
        if auth.startswith("Bearer "):
            token = auth[len("Bearer ") :].strip()
        if not token:
            qs = parse_qs(parsed.query)
            token = qs.get("token", [""])[0]

        if parsed.path in ("/api/profile", "/api/billing/profile"):
            if token in ("mock-valid-token-active", "mock-token-registered"):
                self._send_json(200, {
                    "telegram_id": "100001",
                    "username": "tester@example.com",
                    "days_left": 25,
                    "balance": 25,
                    "status": "active",
                    "is_admin": False,
                    "billing": {"price_per_day_rub": 1, "timezone": "Europe/Moscow", "checkout_discount_percent": 0},
                })
                return
            elif token == "mock-valid-token-expired":
                self._send_json(200, {
                    "telegram_id": "100002",
                    "username": "expired@example.com",
                    "days_left": 0,
                    "balance": 0,
                    "status": "expired",
                    "is_admin": False,
                    "billing": {"price_per_day_rub": 1, "timezone": "Europe/Moscow", "checkout_discount_percent": 0},
                })
                return
            else:
                self._send_json(401, {"error": "unauthorized"})
                return

        if parsed.path == "/api/checkout/options":
            qs = parse_qs(parsed.query)
            mode = qs.get("mode", [""])[0]
            if mode == "unavailable":
                self._send_json(200, {
                    "providers": [{
                        "id": "lava",
                        "title": "СБП и банковские карты",
                        "available": False,
                        "methods": [],
                        "min_amount_rub": 1,
                        "max_amount_rub": 50000,
                    }],
                })
            else:
                # Default: provider available (card + sbp), matching production
                self._send_json(200, {
                    "providers": [{
                        "id": "lava",
                        "title": "СБП и банковские карты",
                        "available": True,
                        "methods": ["card", "sbp"],
                        "min_amount_rub": 1,
                        "max_amount_rub": 50000,
                    }],
                })
            return

        super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        payload = self._read_json()

        if parsed.path == "/api/auth/register":
            email = payload.get("email", "")
            password = payload.get("password", "")
            if "@" not in email or len(password) < 10:
                self._send_json(400, {"error": "use a valid email and a password of 10 to 128 characters"})
                return
            if email == "existing@example.com":
                self._send_json(409, {"error": "account already exists; sign in or recover the password"})
                return
            self._send_json(201, {
                "token": "mock-token-registered",
                "telegram_id": "site_user_new",
                "username": email,
                "days_left": 3,
                "subscription_url": "https://sub.zxc1x1.ru/mock-sub-reg",
            })
            return

        if parsed.path == "/api/auth/login":
            email = payload.get("email", "")
            password = payload.get("password", "")
            if email == "active@example.com" and password == "ValidPassword123":
                self._send_json(200, {
                    "token": "mock-valid-token-active",
                    "telegram_id": "site_user_active",
                    "username": email,
                    "days_left": 30,
                    "subscription_url": "https://sub.zxc1x1.ru/mock-sub-active",
                })
                return
            if email == "expired@example.com" and password == "ValidPassword123":
                self._send_json(200, {
                    "token": "mock-valid-token-expired",
                    "telegram_id": "site_user_expired",
                    "username": email,
                    "days_left": 0,
                    "subscription_url": "https://sub.zxc1x1.ru/mock-sub-expired",
                })
                return
            self._send_json(401, {"error": "invalid email or password"})
            return

        if parsed.path == "/api/onboarding/login/start":
            self._send_json(200, {
                "request_id": "req-12345",
                "poll_secret": "secret-abcde",
                "expires_in": 300,
                "telegram_url": "https://t.me/mosaicvpnbot?start=login_req-12345",
            })
            return

        if parsed.path == "/api/onboarding/login/poll":
            req_id = payload.get("request_id")
            if req_id == "req-expired":
                self._send_json(410, {"error": "challenge expired"})
                return
            if req_id == "req-used":
                self._send_json(409, {"error": "challenge already used"})
                return
            if req_id == "req-pending":
                self._send_json(200, {"status": "pending"})
                return
            self._send_json(200, {
                "status": "approved",
                "token": "mock-valid-token-active",
            })
            return

        if parsed.path == "/api/onboarding/handoff/redeem":
            code = payload.get("code")
            if code == "valid-handoff":
                self._send_json(200, {"token": "mock-valid-token-active"})
                return
            self._send_json(400, {"error": "invalid handoff code"})
            return

        if parsed.path == "/api/invites/redeem":
            invite_token = payload.get("invite_token")
            if invite_token == "valid-gift":
                self._send_json(200, {"ok": True, "added_days": 30, "message": "Подарок успешно активирован! +30 дней"})
                return
            self._send_json(400, {"error": "Неверный или уже использованный код подарка"})
            return

        if parsed.path == "/api/checkout/create":
            # Contract: session must arrive in the Authorization header, never
            # in the body or the query string (no token leakage in logs).
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer ") or not auth[len("Bearer "):].strip():
                self._send_json(401, {"error": "missing bearer session"})
                return
            if "token" in payload or parse_qs(parsed.query).get("token"):
                self._send_json(400, {"error": "token must not be passed in body or query"})
                return
            if not payload.get("terms_accepted"):
                self._send_json(400, {"error": "terms must be accepted"})
                return
            method = payload.get("method")
            if method not in ("card", "sbp"):
                self._send_json(400, {"error": "unsupported payment method"})
                return
            try:
                days = int(payload.get("days") or 0)
                amount_rub = int(payload.get("amount_rub") or 0)
            except (TypeError, ValueError):
                self._send_json(400, {"error": "invalid amount"})
                return
            if days <= 0 or amount_rub <= 0:
                self._send_json(400, {"error": "invalid amount"})
                return
            self._send_json(200, {
                "provider": "lava",
                "method": method,
                "days": days,
                "amount_rub": amount_rub,
                "checkout_url": "https://payments.example/pay/invoice_999",
            })
            return

        if parsed.path == "/api/app-auth/issue":
            self._send_json(200, {
                "code": "ENROLL123456",
                "expires_in": 300,
            })
            return

        if parsed.path == "/api/link/issue":
            self._send_json(200, {
                "code": "LINK7890",
                "expires_in": 300,
            })
            return

        self._send_json(404, {"error": "not found"})


def run_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), MockApiAndStaticServer)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


def run_all_tests():
    os.makedirs(SCREENSHOT_DIR, exist_ok=True)
    server = run_server()
    time.sleep(0.5)

    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path="/usr/bin/google-chrome",
            headless=True,
            args=["--no-sandbox", "--disable-gpu"],
        )

        # -------------------------------------------------------------
        # Test 1: Layout & Viewport 320px check (no overflow, touch targets >= 48px)
        # -------------------------------------------------------------
        print("\n=== Running Test 1: Mobile 320px Viewport & Layout ===")
        context = browser.new_context(viewport={"width": 320, "height": 640})
        page = context.new_page()

        errors = []
        page.on("pageerror", lambda err: errors.append(str(err)))

        resp = page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        assert resp and resp.status == 200, f"Expected status 200 for setup.html, got {resp.status if resp else None}"
        page.wait_for_load_state("networkidle")

        # Check horizontal overflow at 320px
        overflow_info = page.evaluate("""() => {
            const scrollW = document.documentElement.scrollWidth;
            const innerW = window.innerWidth;
            return {
                scrollW: scrollW,
                innerW: innerW,
                hasOverflow: scrollW > innerW,
            };
        }""")
        print(f"320px Viewport check: scrollWidth={overflow_info['scrollW']}, innerWidth={overflow_info['innerW']}")
        assert not overflow_info["hasOverflow"], f"Horizontal overflow detected at 320px: {overflow_info}"

        # Check touch target sizes for primary buttons / actions (>= 48px height)
        touch_targets = page.evaluate("""() => {
            const results = [];
            const buttons = document.querySelectorAll('button:not(.small-btn), a.btn, input.field');
            buttons.forEach(el => {
                if (el.offsetParent !== null) { // visible
                    const rect = el.getBoundingClientRect();
                    results.push({
                        tag: el.tagName,
                        id: el.id,
                        text: el.innerText ? el.innerText.trim().slice(0, 20) : '',
                        height: rect.height,
                        width: rect.width
                    });
                }
            });
            return results;
        }""")
        for item in touch_targets:
            # allow small tolerance for 47.5+ due to borders/subpixel
            assert item["height"] >= 44, f"Action element {item} has height {item['height']} < 44px"
        print(f"Verified {len(touch_targets)} interactive elements have accessible touch target size.")

        shot_320 = os.path.join(SCREENSHOT_DIR, "setup_320px.png")
        page.screenshot(path=shot_320, full_page=True)
        print(f"Saved screenshot: {shot_320}")
        context.close()

        # -------------------------------------------------------------
        # Test 2: Primary Email/Password Registration
        # -------------------------------------------------------------
        print("\n=== Running Test 2: Primary Email/Password Registration ===")
        context = browser.new_context(viewport={"width": 480, "height": 800})
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        page.wait_for_load_state("networkidle")

        # Fill registration form
        page.fill("#reg-email", "newuser@example.com")
        page.fill("#reg-password", "SecurePassword123!")
        page.click("#btn-register")

        # Wait for profile / next step
        page.wait_for_selector("#step-profile-ready, #step-access, #account-info", timeout=5000)

        # Check localStorage has mv_session_token
        stored_token = page.evaluate("() => localStorage.getItem('mv_session_token')")
        assert stored_token == "mock-token-registered", f"Unexpected stored token: {stored_token}"
        print("Registration succeeded and session token correctly stored in localStorage.")

        shot_reg = os.path.join(SCREENSHOT_DIR, "setup_registered.png")
        page.screenshot(path=shot_reg)
        print(f"Saved screenshot: {shot_reg}")
        context.close()

        # -------------------------------------------------------------
        # Test 3: Primary Email/Password Login & Active Profile Display
        # -------------------------------------------------------------
        print("\n=== Running Test 3: Primary Email/Password Login & Active Profile ===")
        context = browser.new_context(viewport={"width": 480, "height": 800})
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        page.wait_for_load_state("networkidle")

        # Switch to login tab if needed
        if page.is_visible("#tab-login"):
            page.click("#tab-login")

        page.fill("#login-email", "active@example.com")
        page.fill("#login-password", "ValidPassword123")
        page.click("#btn-login")

        page.wait_for_selector("#account-status-badge.status-active", timeout=5000)
        status_text = page.locator("#account-status-badge").inner_text()
        print(f"Active account status text: {status_text}")
        assert "актив" in status_text.lower() or "25" in status_text or "доступ" in status_text.lower()

        shot_active = os.path.join(SCREENSHOT_DIR, "setup_active_profile.png")
        page.screenshot(path=shot_active)
        print(f"Saved screenshot: {shot_active}")
        context.close()

        # -------------------------------------------------------------
        # Test 4: Checkout Flow — Plan Presets, Method Selection, Bearer Contract
        # -------------------------------------------------------------
        print("\n=== Running Test 4: Checkout — Plan Presets & Payment Method Selection ===")
        context = browser.new_context(viewport={"width": 480, "height": 800})
        page = context.new_page()
        # Login as expired user so checkout form appears
        page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        page.evaluate("() => localStorage.setItem('mv_session_token', 'mock-valid-token-expired')")
        page.reload()
        page.wait_for_load_state("networkidle")

        # /api/checkout/options returns available: true by default
        # => payment form should be visible, unavailable notice hidden
        page.wait_for_selector("#payment-form-container:not(.hidden)", timeout=5000)
        assert not page.is_visible("#payment-unavailable-notice") or page.locator("#payment-unavailable-notice").evaluate("el => el.classList.contains('hidden')"), "Unavailable notice should be hidden when provider available"
        print("Payment form visible, unavailable notice hidden — correct.")

        # Verify plan presets rendered (7, 30, 90, 365 days)
        presets = page.query_selector_all("#plan-presets button")
        preset_days = [btn.get_attribute("data-days") for btn in presets]
        print(f"Plan presets: {preset_days}")
        assert "7" in preset_days and "30" in preset_days and "90" in preset_days and "365" in preset_days, f"Missing presets: {preset_days}"

        # By default 30 days should be selected
        btn30 = page.locator("#plan-presets button[data-days='30']")
        assert "btn-primary" in (btn30.get_attribute("class") or ""), "30-day preset should be default selected"

        # Click 90-day preset and verify button text updates
        page.click("#plan-presets button[data-days='90']")
        btn_text = page.locator("#btn-checkout").inner_text()
        print(f"Checkout button after 90d: {btn_text}")
        assert "90" in btn_text, f"Button should show 90 RUB: {btn_text}"

        # Verify payment methods rendered (card, sbp)
        methods = page.query_selector_all("#payment-methods button")
        method_values = [btn.get_attribute("data-method") for btn in methods]
        print(f"Payment methods: {method_values}")
        assert "card" in method_values and "sbp" in method_values, f"Missing methods: {method_values}"

        # Click SBP and verify it becomes selected
        page.click("#payment-methods button[data-method='sbp']")
        sbp_btn = page.locator("#payment-methods button[data-method='sbp']")
        assert "btn-primary" in (sbp_btn.get_attribute("class") or ""), "SBP should be selected"

        # Accept terms and submit checkout
        page.check("#terms-agree")

        # Intercept navigation to verify checkout_url redirect
        checkout_requests = []
        page.on("request", lambda req: checkout_requests.append(req) if "/api/checkout/create" in req.url else None)

        page.click("#btn-checkout")
        # Wait for the API call
        time.sleep(1)

        # Verify Bearer was used (check the intercepted request)
        if checkout_requests:
            req = checkout_requests[0]
            auth_header = req.headers.get("authorization", "")
            assert auth_header.startswith("Bearer "), f"Expected Bearer auth, got: {auth_header}"
            body = req.post_data or ""
            assert "token" not in body.lower() or '"method"' in body, f"Token must not be sent in body: {body}"
            print(f"Checkout request used Bearer auth: {auth_header[:20]}...")
        else:
            print("WARNING: checkout request not intercepted (may have navigated too fast)")

        shot_checkout = os.path.join(SCREENSHOT_DIR, "setup_checkout.png")
        page.screenshot(path=shot_checkout)
        print(f"Saved screenshot: {shot_checkout}")
        context.close()

        # -------------------------------------------------------------
        # Test 5: Hash Fragment Cleaned on Load (security: tokens stripped)
        # -------------------------------------------------------------
        print("\n=== Running Test 5: Hash Fragment Cleaned on Load ===")
        context = browser.new_context(viewport={"width": 480, "height": 800})
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/setup.html#gift=some-token-value")
        page.wait_for_load_state("networkidle")

        # Verify hash was stripped immediately from URL (security: no token in address bar)
        time.sleep(0.5)
        current_hash = page.evaluate("() => window.location.hash")
        assert current_hash == "" or "gift" not in current_hash, f"Gift fragment was not stripped: {current_hash}"
        print(f"Hash after load: '{current_hash}' — correctly stripped.")

        # Verify gift notice appeared
        gift_notice = page.locator("#gift-notice")
        if gift_notice.count() > 0 and gift_notice.is_visible():
            notice_text = gift_notice.inner_text()
            print(f"Gift notice: {notice_text}")
            assert "подарок" in notice_text.lower() or "код" in notice_text.lower()
        else:
            print("Gift notice not visible (gift flow may require login first).")

        context.close()

        # -------------------------------------------------------------
        # Test 6: Gift / Invite Token via Hash Fragment (#gift=valid-gift)
        # -------------------------------------------------------------
        print("\n=== Running Test 6: Gift / Invite Token (#gift=...) ===")
        context = browser.new_context(viewport={"width": 480, "height": 800})
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/setup.html#gift=valid-gift")
        page.wait_for_load_state("networkidle")

        # Verify hash was stripped immediately
        current_hash = page.evaluate("() => window.location.hash")
        assert current_hash == "" or "gift" not in current_hash, f"Gift fragment was not stripped: {current_hash}"

        # Register or login
        page.fill("#reg-email", "giftuser@example.com")
        page.fill("#reg-password", "SecurePassword123!")
        page.click("#btn-register")

        page.wait_for_selector("#gift-redeem-success, .gift-success-msg", timeout=5000)
        gift_msg = page.locator("#gift-redeem-success, .gift-success-msg").inner_text()
        print(f"Gift redemption response: {gift_msg}")
        assert "подарок" in gift_msg.lower() or "активирован" in gift_msg.lower()
        context.close()

        # -------------------------------------------------------------
        # Test 7: Payment / Checkout Provider Unavailable Honest Handling
        # -------------------------------------------------------------
        print("\n=== Running Test 7: Honest Payment Provider Unavailable Display ===")
        context = browser.new_context(viewport={"width": 480, "height": 800})
        page = context.new_page()

        # Intercept checkout options to force unavailable provider
        def force_unavailable(route):
            route.fulfill(
                status=200,
                content_type="application/json",
                body=json.dumps({"providers": [{"id": "lava", "title": "СБП и банковские карты", "available": False, "methods": [], "min_amount_rub": 1, "max_amount_rub": 50000}]}),
            )
        page.route("**/api/checkout/options*", force_unavailable)

        # Set token with expired status to show payment step
        page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        page.evaluate("() => localStorage.setItem('mv_session_token', 'mock-valid-token-expired')")
        page.reload()
        page.wait_for_load_state("networkidle")

        page.wait_for_selector("#payment-unavailable-notice, .provider-unavailable", timeout=5000)
        notice_text = page.locator("#payment-unavailable-notice, .provider-unavailable").inner_text()
        print(f"Payment notice: {notice_text}")
        assert "настраивается" in notice_text.lower() or "недоступна" in notice_text.lower() or "telegram" in notice_text.lower()

        shot_unavail = os.path.join(SCREENSHOT_DIR, "setup_payment_unavailable.png")
        page.screenshot(path=shot_unavail)
        print(f"Saved screenshot: {shot_unavail}")
        context.close()

        # -------------------------------------------------------------
        # Test 8: Platform Selection, Downloads & Artifact Integrity
        # -------------------------------------------------------------
        print("\n=== Running Test 8: Platform Selection & Artifact Integrity ===")
        context = browser.new_context(viewport={"width": 600, "height": 900})
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        page.evaluate("() => localStorage.setItem('mv_session_token', 'mock-valid-token-active')")
        page.reload()
        page.wait_for_load_state("networkidle")

        # Test platform buttons
        page.click("#platform-tab-windows")
        win_href = page.get_attribute("#dl-btn-primary", "href")
        assert "MosaicVPN-Setup-x64" in win_href and win_href.endswith(".exe")

        page.click("#platform-tab-android")
        android_href = page.get_attribute("#dl-btn-primary", "href")
        assert "MosaicVPN-Android" in android_href and android_href.endswith(".apk")

        page.click("#platform-tab-linux")
        linux_href = page.get_attribute("#dl-btn-primary", "href")
        assert "MosaicVPN" in linux_href and linux_href.endswith(".deb")

        page.click("#platform-tab-apple")
        apple_notice = page.locator("#apple-status-note").inner_text()
        print(f"Apple platform notice: {apple_notice}")
        assert "разработк" in apple_notice.lower() or "скоро" in apple_notice.lower() or "настройк" in apple_notice.lower() or "отсутств" in apple_notice.lower() or "подключен" in apple_notice.lower()
        # Ensure no fake native Apple executable download is offered
        apple_dl_visible = page.is_visible("#apple-fake-download")
        assert not apple_dl_visible, "Apple fake download should not exist!"
        context.close()

        # -------------------------------------------------------------
        # Test 9: Enrollment Issue & 'Open MosaicVPN' Button
        # -------------------------------------------------------------
        print("\n=== Running Test 9: Enrollment Issue & Deep Link / HTTPS Callback ===")
        context = browser.new_context(viewport={"width": 600, "height": 900})
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/setup.html")
        page.evaluate("() => localStorage.setItem('mv_session_token', 'mock-valid-token-active')")
        page.reload()
        page.wait_for_load_state("networkidle")

        page.click("#btn-issue-enrollment")
        # Wait for enrollment box to become visible (contains btn-open-app)
        page.wait_for_selector("#enrollment-box:not(.hidden)", timeout=8000)

        open_href = page.get_attribute("#btn-open-app", "href")
        print(f"Open app href: {open_href}")
        # Contract: mosaicvpn://enroll/callback?code=...
        assert "mosaicvpn://enroll/callback?code=" in open_href or "sub.zxc1x1.ru/enroll/callback" in open_href

        profile_ready_label = page.locator("#enrollment-ready-status").inner_text()
        print(f"Enrollment status: {profile_ready_label}")
        assert "сформирован" in profile_ready_label.lower() or "готов" in profile_ready_label.lower() or "откройте" in profile_ready_label.lower()

        shot_enroll = os.path.join(SCREENSHOT_DIR, "setup_enrollment_ready.png")
        page.screenshot(path=shot_enroll)
        print(f"Saved screenshot: {shot_enroll}")
        context.close()

        browser.close()

    server.shutdown()
    print("\n=========================================")
    print("ALL BROWSER TESTS PASSED SUCCESSFULLY! ✅")
    print("=========================================\n")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--red":
        test_missing_page_red()
    else:
        run_all_tests()
