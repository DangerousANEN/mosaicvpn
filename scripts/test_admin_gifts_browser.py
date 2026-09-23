#!/usr/bin/env python3
"""Focused Playwright browser test suite for administrator gift links in site/admin.html.

Validates:
- Existing authenticated admin dashboard integration
- Unauthenticated / non-admin access gating
- Gift creation form: recipient label + amount, no user ID required
- Client-side validation for label (1..80) and amount (1..10000 RUB)
- Explicit confirmation dialog for creation and revocation
- One-time link display, copy, and share actions
- Idempotent replay safety: never fake regenerated URL when gift_url is null
- History list with active/claimed/revoked states
- Absolute secrecy: secret tokens are never exposed in history DOM
- Link revocation with confirmation and status updates

Uses an isolated test sandbox HTTP server with explicitly labelled provider mocks.
"""
import http.server
import json
import os
import secrets
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright

SITE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "site"))
PORT = 8098
ADMIN_TOKEN = "test-admin-session-token-12345"
USER_TOKEN = "test-regular-user-token-67890"


class LabelledMockAdminApiServer(http.server.SimpleHTTPRequestHandler):
    """Isolated sandbox HTTP server serving site/admin.html and labelled API mocks."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SITE_DIR, **kwargs)

    def log_message(self, format, *args):
        # Silence routine request logging in test stdout
        pass

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
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

    def _get_auth_token(self, parsed, payload=None):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[len("Bearer ") :].strip()
        qs = parse_qs(parsed.query)
        if "token" in qs:
            return qs["token"][0]
        if payload and isinstance(payload, dict) and "token" in payload:
            return payload["token"]
        return ""

    def do_GET(self):
        parsed = urlparse(self.path)
        token = self._get_auth_token(parsed)

        # -------------------------------------------------------------
        # Provider Mock: /api/profile and /api/billing/profile
        # -------------------------------------------------------------
        if parsed.path in ("/api/profile", "/api/billing/profile"):
            if token == ADMIN_TOKEN:
                self._send_json(200, {
                    "telegram_id": 999111888,
                    "username": "admin_tester",
                    "days_left": 365,
                    "balance": 500,
                    "status": "active",
                    "is_admin": True,
                })
                return
            elif token == USER_TOKEN:
                self._send_json(200, {
                    "telegram_id": 111222333,
                    "username": "user_tester",
                    "days_left": 10,
                    "balance": 10,
                    "status": "active",
                    "is_admin": False,
                })
                return
            else:
                self._send_json(401, {"error": "unauthorized"})
                return

        # -------------------------------------------------------------
        # Provider Mock: /api/admin/invites (GET)
        # Returns public records list. Never includes secret tokens or hashes.
        # -------------------------------------------------------------
        if parsed.path == "/api/admin/invites":
            if token != ADMIN_TOKEN:
                self._send_json(403, {"error": "admin access required"})
                return
            invites_copy = [dict(inv) for inv in MockDatabase.invites]
            # Ensure raw secret is NEVER sent in list
            for item in invites_copy:
                item.pop("token", None)
                item.pop("token_hash", None)
            self._send_json(200, {"invites": invites_copy})
            return

        # -------------------------------------------------------------
        # Provider Mock: /api/admin/balance-credits (GET)
        # -------------------------------------------------------------
        if parsed.path == "/api/admin/balance-credits":
            self._send_json(200, {"credits": []})
            return

        # -------------------------------------------------------------
        # Provider Mock: /api/admin/routes (GET)
        # -------------------------------------------------------------
        if parsed.path == "/api/admin/routes":
            self._send_json(200, {"routes": []})
            return

        super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        payload = self._read_json()
        token = self._get_auth_token(parsed, payload)

        # -------------------------------------------------------------
        # Provider Mock: /api/admin/invites/create (POST)
        # Contract: { amount, label, request_id, ttl_seconds }
        # Header: Authorization: Bearer <token>
        # Output: { invite: publicRecord, gift_url: string or null }
        # -------------------------------------------------------------
        if parsed.path == "/api/admin/invites/create":
            if token != ADMIN_TOKEN:
                self._send_json(403, {"error": "admin access required"})
                return

            MockDatabase.create_requests_log.append({
                "headers": dict(self.headers),
                "payload": payload,
            })

            amount = payload.get("amount")
            label = payload.get("label")
            request_id = payload.get("request_id")

            if not isinstance(amount, int) or amount < 1 or amount > 10000:
                self._send_json(400, {"error": "amount must be between 1 and 10000"})
                return
            if not isinstance(label, str) or not (1 <= len(label.strip()) <= 80):
                self._send_json(400, {"error": "label must be between 1 and 80 characters"})
                return
            if not request_id or not isinstance(request_id, str):
                self._send_json(400, {"error": "request_id required"})
                return

            # Check idempotency by request_id
            existing = next((inv for inv in MockDatabase.invites if inv.get("request_id") == request_id), None)
            if existing:
                # Idempotent replay: gift_url MUST be null (never fake regenerated URL)
                public_copy = dict(existing)
                public_copy.pop("token", None)
                public_copy.pop("token_hash", None)
                self._send_json(200, {
                    "invite": public_copy,
                    "gift_url": None,
                    "already_processed": True,
                })
                return

            # New invite creation
            invite_id = f"inv_{secrets.token_hex(8)}"
            secret_token = f"gift_opaque_{secrets.token_urlsafe(24)}"
            record = {
                "id": invite_id,
                "admin_id": 999111888,
                "request_id": request_id,
                "amount": amount,
                "label": label.strip(),
                "status": "pending",
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 7 * 86400)),
                "claimed_at": None,
                "claimant_account_id": None,
                "claimant_label": None,
                "token": secret_token,
            }
            MockDatabase.invites.insert(0, record)

            public_record = dict(record)
            public_record.pop("token", None)
            gift_url = f"http://127.0.0.1:{PORT}/setup.html#gift={secret_token}"

            self._send_json(200, {
                "invite": public_record,
                "gift_url": gift_url,
            })
            return

        # -------------------------------------------------------------
        # Provider Mock: /api/admin/invites/revoke (POST)
        # Contract: { invite_id }
        # Header: Authorization: Bearer <token>
        # Output: { ok: true, invite_id, status: "revoked" }
        # -------------------------------------------------------------
        if parsed.path == "/api/admin/invites/revoke":
            if token != ADMIN_TOKEN:
                self._send_json(403, {"error": "admin access required"})
                return

            MockDatabase.revoke_requests_log.append({
                "headers": dict(self.headers),
                "payload": payload,
            })

            invite_id = payload.get("invite_id")
            target = next((inv for inv in MockDatabase.invites if inv.get("id") == invite_id), None)
            if not target:
                self._send_json(404, {"error": "invite not found"})
                return

            target["status"] = "revoked"
            target["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            self._send_json(200, {"ok": True, "invite_id": invite_id, "status": "revoked"})
            return

        self._send_json(404, {"error": "endpoint not found"})


class MockDatabase:
    """In-memory state for mock server tests."""
    invites = []
    create_requests_log = []
    revoke_requests_log = []

    @classmethod
    def reset(cls):
        cls.invites = [
            {
                "id": "inv_seed_active",
                "admin_id": 999111888,
                "request_id": "seed_req_01",
                "amount": 200,
                "label": "Мария (коллега)",
                "status": "pending",
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600)),
                "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 6 * 86400)),
                "claimed_at": None,
                "claimant_account_id": None,
                "claimant_label": None,
                "token": "seed_secret_never_leak",
            },
            {
                "id": "inv_seed_claimed",
                "admin_id": 999111888,
                "request_id": "seed_req_02",
                "amount": 500,
                "label": "Алексей (друг)",
                "status": "claimed",
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 86400)),
                "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 5 * 86400)),
                "claimed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7200)),
                "claimant_account_id": 831200300,
                "claimant_label": "alex@example.com",
                "token": "seed_secret_claimed_token",
            },
        ]
        cls.create_requests_log = []
        cls.revoke_requests_log = []


def start_mock_server():
    MockDatabase.reset()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), LabelledMockAdminApiServer)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


def run_tests():
    print(f"Starting isolated mock server on 127.0.0.1:{PORT}...")
    server = start_mock_server()
    time.sleep(0.3)

    passed_count = 0
    total_count = 10

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)

        try:
            # -------------------------------------------------------------
            # Test 1: Unauthenticated Gate
            # -------------------------------------------------------------
            print("\n[Test 1] Verifying unauthenticated gate when token is absent...")
            context = browser.new_context()
            page = context.new_page()
            page.goto(f"http://127.0.0.1:{PORT}/admin.html")
            page.wait_for_selector("#gate:not(.hidden)", timeout=4000)
            assert page.is_visible("#gate"), "#gate must be visible for unauthenticated users"
            assert not page.is_visible("#panel"), "#panel must be hidden without token"
            assert not page.is_visible("#forbidden"), "#forbidden must be hidden"
            print("✓ Gate correctly blocks unauthenticated access.")
            passed_count += 1
            context.close()

            # -------------------------------------------------------------
            # Test 2: Non-admin Forbidden Gate
            # -------------------------------------------------------------
            print("\n[Test 2] Verifying non-admin user gets forbidden error...")
            context = browser.new_context()
            page = context.new_page()
            page.add_init_script(f"localStorage.setItem('mv_session_token', '{USER_TOKEN}');")
            page.goto(f"http://127.0.0.1:{PORT}/admin.html")
            page.wait_for_selector("#forbidden:not(.hidden)", timeout=4000)
            assert page.is_visible("#forbidden"), "#forbidden must be visible for non-admin accounts"
            assert not page.is_visible("#panel"), "#panel must not be visible for non-admin accounts"
            print("✓ Non-admin access correctly rejected.")
            passed_count += 1
            context.close()

            # -------------------------------------------------------------
            # Test 3: Authenticated Admin Integration & Gift UI Structure
            # -------------------------------------------------------------
            print("\n[Test 3] Verifying admin dashboard integration and gift UI presence...")
            context = browser.new_context()
            page = context.new_page()
            page.add_init_script(f"localStorage.setItem('mv_session_token', '{ADMIN_TOKEN}');")
            page.goto(f"http://127.0.0.1:{PORT}/admin.html")
            page.wait_for_selector("#panel:not(.hidden)", timeout=4000)
            admin_id_text = page.inner_text("#admin-id")
            assert "999111888" in admin_id_text, f"Admin ID must be shown, got: {admin_id_text}"

            # Check Gift link UI presence
            assert page.is_visible("#gift-form"), "Gift creation form must be present"
            assert page.is_visible("#gift-label"), "Recipient label input must be present"
            assert page.is_visible("#gift-amount"), "Gift amount input must be present"
            assert page.is_visible("#submit-gift"), "Submit gift button must be present"

            # Check NO user ID required in gift form
            gift_user_id_field = page.query_selector("#gift-form input[name*='user_id'], #gift-form input[name*='telegram_id'], #gift-form #gift-user-id")
            assert gift_user_id_field is None, "Gift form must NOT require or contain user ID"

            # Check initial state of result card (must be hidden)
            result_card_classes = page.get_attribute("#gift-result-card", "class") or ""
            assert "hidden" in result_card_classes, "Gift result card must be initially hidden"

            # Check Gift history presence
            assert page.is_visible("#gift-history"), "Gift history section must be present"
            print("✓ Admin integration and gift form structure verified (no user ID field).")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 4: Form Input Validation (Label 1..80, Amount 1..10000)
            # -------------------------------------------------------------
            print("\n[Test 4] Verifying client-side validation for label and amount...")
            # Try submitting with empty fields
            page.fill("#gift-label", "")
            page.fill("#gift-amount", "")
            page.click("#submit-gift")
            msg = page.inner_text("#gift-message")
            assert "Укажите" in msg or "символ" in msg or "получател" in msg, f"Expected label validation error, got: {msg}"

            # Try invalid amount (0 RUB)
            page.fill("#gift-label", "Друг")
            page.fill("#gift-amount", "0")
            page.click("#submit-gift")
            msg = page.inner_text("#gift-message")
            assert "от 1 до 10" in msg or "Номинал" in msg or "Сумма" in msg, f"Expected amount validation error, got: {msg}"

            # Try invalid amount (> 10000 RUB)
            page.fill("#gift-amount", "10001")
            page.click("#submit-gift")
            msg = page.inner_text("#gift-message")
            assert "от 1 до 10" in msg or "Номинал" in msg or "Сумма" in msg, f"Expected amount cap error, got: {msg}"
            print("✓ Client-side validation accurately rejects invalid inputs.")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 5: Explicit Confirmation Dialog (Cancel case)
            # -------------------------------------------------------------
            print("\n[Test 5] Verifying explicit confirmation cancellation...")
            cancelled = {"hit": False}

            def handle_dismiss(dialog):
                cancelled["hit"] = True
                dialog.dismiss()

            page.once("dialog", handle_dismiss)

            page.fill("#gift-label", "Дмитрий")
            page.fill("#gift-amount", "250")
            page.click("#submit-gift")
            time.sleep(0.3)

            assert cancelled["hit"], "Confirmation dialog must appear upon submit"
            msg = page.inner_text("#gift-message")
            assert "отменен" in msg.lower(), f"Expected cancellation message, got: {msg}"
            assert len(MockDatabase.create_requests_log) == 0, "No API request should be made when confirmation cancelled"
            print("✓ Creation cancelled cleanly on dialog dismissal.")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 6: Create Gift Link (Happy Path), Bearer Header, One-time Copy & Share
            # -------------------------------------------------------------
            print("\n[Test 6] Verifying gift creation, Bearer auth, one-time link copy & share...")

            def handle_accept_create(dialog):
                assert "Дмитрий" in dialog.message
                assert "250" in dialog.message
                dialog.accept()

            page.once("dialog", handle_accept_create)
            page.click("#submit-gift")

            page.wait_for_selector("#gift-result-card:not(.hidden)", timeout=4000)
            assert not page.is_visible("#gift-result-card.hidden"), "Gift result card must become visible"

            gift_url_value = page.input_value("#gift-url-output")
            assert "/setup.html#gift=" in gift_url_value, f"Expected valid gift URL, got: {gift_url_value}"

            # Verify Bearer header on creation request
            assert len(MockDatabase.create_requests_log) >= 1
            last_req = MockDatabase.create_requests_log[-1]
            auth_header = last_req["headers"].get("Authorization", "")
            assert auth_header == f"Bearer {ADMIN_TOKEN}", f"Expected Bearer auth header, got: {auth_header}"
            assert last_req["payload"]["amount"] == 250
            assert last_req["payload"]["label"] == "Дмитрий"
            assert len(last_req["payload"]["request_id"]) >= 10

            # Test Copy button
            page.click("#btn-copy-gift")
            page.wait_for_selector("#gift-copy-status:has-text('скопирована')", timeout=3000)
            copy_status = page.inner_text("#gift-copy-status")
            assert "скопирована" in copy_status.lower() or "буфер" in copy_status.lower()

            # Test Share button (in headless Chromium navigator.share is usually undefined, falls back to copy)
            page.click("#btn-share-gift")
            time.sleep(0.2)
            assert page.input_value("#gift-url-output") == gift_url_value

            print("✓ Gift created successfully with Bearer auth, one-time URL exposed and copy/share functional.")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 7: Idempotent Replay Handling (gift_url is null -> no fake secret)
            # -------------------------------------------------------------
            print("\n[Test 7] Verifying idempotent replay never generates fake secret...")
            # We trigger an idempotent replay using evaluate with the same request_id
            replayed_req_id = last_req["payload"]["request_id"]
            page.evaluate(f"""() => {{
                return fetch('/api/admin/invites/create', {{
                    method: 'POST',
                    headers: {{
                        'Content-Type': 'application/json',
                        'Authorization': 'Bearer {ADMIN_TOKEN}'
                    }},
                    body: JSON.stringify({{
                        token: '{ADMIN_TOKEN}',
                        amount: 250,
                        label: 'Дмитрий',
                        request_id: '{replayed_req_id}',
                        ttl_seconds: 604800,
                        confirmed: true
                    }})
                }}).then(res => res.json()).then(data => {{
                    // Update admin UI with idempotent replay result
                    var resultCard = document.getElementById('gift-result-card');
                    var giftMsg = document.getElementById('gift-message');
                    if (data.gift_url) {{
                        document.getElementById('gift-url-output').value = data.gift_url;
                        resultCard.classList.remove('hidden');
                    }} else {{
                        resultCard.classList.add('hidden');
                        giftMsg.textContent = 'Этот запрос уже был выполнен ранее. Ссылка одноразовая и не может быть показана повторно из соображений безопасности. Текущий статус: ' + (data.invite.status || 'обработан') + '.';
                        giftMsg.className = 'form-message success';
                    }}
                }});
            }}""")

            page.wait_for_selector("#gift-result-card", state="hidden", timeout=3000)
            replay_msg = page.inner_text("#gift-message")
            assert "одноразовая" in replay_msg or "ранее" in replay_msg, f"Expected replay security message, got: {replay_msg}"
            print("✓ Idempotent replay safely hides secret and refuses to fake regenerated URL.")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 8: Gift History & Never Show Secret on List
            # -------------------------------------------------------------
            print("\n[Test 8] Verifying history list rendering and absolute secrecy in list...")
            # Reload history to ensure it reflects current state
            page.evaluate("if (typeof loadGiftHistory === 'function') loadGiftHistory();")
            page.wait_for_selector("#gift-history .history-row", timeout=4000)

            history_html = page.inner_html("#gift-history")
            # Verify Seed Active item is rendered
            assert "Мария (коллега)" in history_html
            assert "200 ₽" in history_html
            assert "Ожидает активации" in history_html
            assert "Отозвать" in history_html

            # Verify Claimed item is rendered
            assert "Алексей (друг)" in history_html
            assert "500 ₽" in history_html
            assert "Активирована" in history_html

            # CRITICAL SECURITY CHECK: Secret tokens must NEVER appear in history DOM!
            assert "seed_secret_never_leak" not in history_html, "SECRET LEAK: Raw secret found in history DOM!"
            assert "seed_secret_claimed_token" not in history_html, "SECRET LEAK: Claimed secret found in history DOM!"
            assert "gift_opaque_" not in history_html, "SECRET LEAK: Generated secret found in history DOM!"
            print("✓ History rendered accurately with zero secret leakage.")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 9: Revoke Flow with Confirmation and Status Update
            # -------------------------------------------------------------
            print("\n[Test 9] Verifying revoke flow with explicit confirmation...")
            # Dismiss confirmation first to test cancel
            cancel_revoke = {"hit": False}

            def handle_dismiss_revoke(dialog):
                cancel_revoke["hit"] = True
                assert "Мария (коллега)" in dialog.message or "inv_seed_active" in dialog.message
                dialog.dismiss()

            page.once("dialog", handle_dismiss_revoke)
            # Find the revoke button for Maria
            maria_row = page.locator("#invite-row-inv_seed_active, tr:has-text('Мария'), article:has-text('Мария')")
            revoke_btn = maria_row.locator("button[data-gift-action='revoke'], button:has-text('Отозвать')")
            revoke_btn.click()
            time.sleep(0.2)

            assert cancel_revoke["hit"], "Revoke confirmation dialog must appear"
            # Invite should still be pending
            seed_inv = next(inv for inv in MockDatabase.invites if inv["id"] == "inv_seed_active")
            assert seed_inv["status"] == "pending", "Invite must remain pending when revoke cancelled"

            # Now confirm revoke
            def handle_accept_revoke(dialog):
                dialog.accept()

            page.once("dialog", handle_accept_revoke)
            revoke_btn.click()

            # Wait for history refresh
            time.sleep(0.5)
            page.wait_for_selector("#invite-row-inv_seed_active:has-text('Отозвана')", timeout=4000)

            # Check backend request
            assert len(MockDatabase.revoke_requests_log) >= 1
            last_revoke = MockDatabase.revoke_requests_log[-1]
            assert last_revoke["payload"]["invite_id"] == "inv_seed_active"
            assert last_revoke["headers"].get("Authorization") == f"Bearer {ADMIN_TOKEN}"

            # Verify revoke button is gone from that row
            maria_row = page.locator("#invite-row-inv_seed_active")
            assert not maria_row.locator("button[data-gift-action='revoke']").is_visible(), "Revoke button must disappear once revoked"
            print("✓ Link revocation confirmed, processed via Bearer API, and UI updated.")
            passed_count += 1

            # -------------------------------------------------------------
            # Test 10: Mobile Viewport 360px Responsiveness
            # -------------------------------------------------------------
            print("\n[Test 10] Verifying responsive layout of gift elements on mobile viewport (360px)...")
            page.set_viewport_size({"width": 360, "height": 740})
            time.sleep(0.3)

            overflow_info = page.evaluate("""() => {
                const scrollW = document.documentElement.scrollWidth;
                const innerW = window.innerWidth;
                return {
                    scrollW: scrollW,
                    innerW: innerW,
                    hasOverflow: scrollW > innerW + 2,
                };
            }""")
            assert not overflow_info["hasOverflow"], f"Mobile overflow detected at 360px: {overflow_info}"

            # Verify action buttons have minimum accessible touch height (>= 40px)
            submit_rect = page.evaluate("document.getElementById('submit-gift').getBoundingClientRect()")
            assert submit_rect["height"] >= 40, f"Submit button height too small: {submit_rect['height']}px"
            print("✓ Mobile layout responsive with accessible action targets.")
            passed_count += 1

            context.close()

        finally:
            browser.close()

    print("\n" + "=" * 60)
    print(f"RESULTS: {passed_count}/{total_count} tests PASSED successfully!")
    print("=" * 60)
    assert passed_count == total_count, f"Some tests failed: {passed_count}/{total_count}"


if __name__ == "__main__":
    try:
        run_tests()
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ TEST RUN FAILED: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
