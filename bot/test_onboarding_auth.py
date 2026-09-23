"""Unit and integration tests for BrowserLoginStore (Telegram website login challenge backend).

Tests verify:
1. Idempotent schema initialization.
2. Creation contract: request_id token_urlsafe(18), poll_secret token_urlsafe(32), secret hashed only (never raw secret in DB).
3. Status begins as pending (no auto-approval on start, explicit Telegram confirmation required).
4. Polling contract: pending, approved (with telegram_id), expired, used, locked, invalid_secret, not_found.
5. Binding/Approval contract: atomic, binds once, cannot change account, requires live request.
6. Expiration behavior: expired requests cannot be approved, polled, or consumed.
7. Brute force prevention: secret guessing lockout after max failed attempts.
8. Malformed input protection: rejecting non-string, invalid characters, bad telegram IDs.
9. Single-consumer claim token guard and transactional exchange callback.
10. Challenge metadata inspection for Telegram bot dialog confirmation UI.
11. Real SQLite multi-threaded concurrency: races on consume and approve ensure exactly one winner without database locks.
"""

import datetime
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest

# Ensure current directory is on sys.path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from onboarding_auth import BrowserLoginStore, BrowserLoginResult


class BrowserLoginStoreTest(unittest.TestCase):
    def setUp(self):
        fd, self.db_path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        self.store = BrowserLoginStore(self.db_path, default_ttl_seconds=600, max_attempts=5)

    def tearDown(self):
        try:
            os.unlink(self.db_path)
        except OSError:
            pass

    # -------------------------------------------------------------------------
    # 1. Schema Idempotency
    # -------------------------------------------------------------------------
    def test_schema_initialization_is_idempotent(self):
        """Calling init_schema repeatedly must succeed without altering existing records."""
        challenge = self.store.create()
        self.assertIsNotNone(challenge["request_id"])

        # Re-initialize schema multiple times
        self.store.init_schema()
        self.store.init_schema()

        # Data must remain intact
        poll_res = self.store.poll(challenge["request_id"], challenge["poll_secret"])
        self.assertEqual(poll_res["status"], BrowserLoginResult.PENDING)

    # -------------------------------------------------------------------------
    # 2. Creation Contract & Secret Hashing
    # -------------------------------------------------------------------------
    def test_create_contract_and_secret_hashing(self):
        """create() must return request_id, poll_secret, expires_in:600.
        Raw poll_secret must NEVER be stored in the SQLite database.
        """
        challenge = self.store.create()
        request_id = challenge["request_id"]
        poll_secret = challenge["poll_secret"]
        expires_in = challenge["expires_in"]

        self.assertIsInstance(request_id, str)
        self.assertIsInstance(poll_secret, str)
        self.assertEqual(expires_in, 600)
        # request_id from secrets.token_urlsafe(18) should be 24 chars
        self.assertGreaterEqual(len(request_id), 24)
        # poll_secret from secrets.token_urlsafe(32) should be 43+ chars
        self.assertGreaterEqual(len(poll_secret), 40)

        # Inspect raw database directly to confirm poll_secret is NOT present in any column
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM browser_login_challenges WHERE request_id = ?", (request_id,))
            row = cursor.fetchone()
            self.assertIsNotNone(row)
            col_names = [desc[0] for desc in cursor.description]
            row_dict = dict(zip(col_names, row))

            # Raw poll_secret must not equal any column value or be contained within it
            for col, val in row_dict.items():
                if isinstance(val, str):
                    self.assertNotIn(poll_secret, val, f"Raw secret leaked in column {col}")

            # secret_hash must be present and distinct from raw secret
            self.assertIn("secret_hash", row_dict)
            self.assertNotEqual(row_dict["secret_hash"], poll_secret)
            # Starts as pending
            self.assertEqual(row_dict["status"], BrowserLoginResult.PENDING)
            self.assertIsNone(row_dict["telegram_id"])

    # -------------------------------------------------------------------------
    # 3. Explicit Confirmation Required (No Auto-Approval on Start)
    # -------------------------------------------------------------------------
    def test_no_auto_approval_on_creation(self):
        """Newly created challenge must remain in pending status until explicitly approved."""
        challenge = self.store.create()
        poll_res = self.store.poll(challenge["request_id"], challenge["poll_secret"])
        self.assertEqual(poll_res["status"], BrowserLoginResult.PENDING)
        self.assertNotIn("telegram_id", poll_res)

    # -------------------------------------------------------------------------
    # 4. Polling Contract
    # -------------------------------------------------------------------------
    def test_poll_outcomes(self):
        """poll() returns pending, approved with telegram_id, or expired/used."""
        challenge = self.store.create()
        req_id = challenge["request_id"]
        secret = challenge["poll_secret"]

        # 1. Pending
        self.assertEqual(self.store.poll(req_id, secret)["status"], BrowserLoginResult.PENDING)

        # 2. Approved
        bind_res = self.store.approve(req_id, telegram_id=987654321, telegram_username="alice")
        self.assertTrue(bind_res["success"])

        poll_approved = self.store.poll(req_id, secret)
        self.assertEqual(poll_approved["status"], BrowserLoginResult.APPROVED)
        self.assertEqual(poll_approved["telegram_id"], 987654321)
        self.assertEqual(poll_approved["telegram_username"], "alice")

        # 3. Used
        consume_res = self.store.consume(req_id, secret)
        self.assertEqual(consume_res["status"], BrowserLoginResult.CONSUMED)

        poll_used = self.store.poll(req_id, secret)
        self.assertEqual(poll_used["status"], BrowserLoginResult.USED)

    # -------------------------------------------------------------------------
    # 5. Bind / Approve Contract
    # -------------------------------------------------------------------------
    def test_bind_approve_atomic_and_account_lock(self):
        """bind/approve binds once and cannot change account."""
        challenge = self.store.create()
        req_id = challenge["request_id"]

        # First approval by user 123456
        res1 = self.store.approve(req_id, telegram_id=123456, telegram_username="user1")
        self.assertTrue(res1["success"])
        self.assertEqual(res1["status"], BrowserLoginResult.APPROVED)

        # Second approval attempt with DIFFERENT telegram_id must be rejected
        res2 = self.store.approve(req_id, telegram_id=654321, telegram_username="user2")
        self.assertFalse(res2["success"])
        self.assertEqual(res2["status"], BrowserLoginResult.ALREADY_BOUND)

        # Second approval attempt with SAME telegram_id must also be rejected (binds once)
        res3 = self.store.approve(req_id, telegram_id=123456, telegram_username="user1")
        self.assertFalse(res3["success"])
        self.assertEqual(res3["status"], BrowserLoginResult.ALREADY_BOUND)

        # Both 'bind' and 'approve' aliases work
        challenge2 = self.store.create()
        res_alias = self.store.bind(challenge2["request_id"], telegram_id=111222)
        self.assertTrue(res_alias["success"])

    def test_bind_requires_existing_live_request(self):
        """Cannot approve non-existent or expired or used request."""
        # Non-existent
        res = self.store.approve("non_existent_req_id_0000", telegram_id=123)
        self.assertFalse(res["success"])
        self.assertEqual(res["status"], BrowserLoginResult.NOT_FOUND)

        # Consumed request cannot be approved again
        ch = self.store.create()
        self.store.approve(ch["request_id"], telegram_id=123)
        self.store.consume(ch["request_id"], ch["poll_secret"])

        res_used = self.store.approve(ch["request_id"], telegram_id=456)
        self.assertFalse(res_used["success"])
        self.assertEqual(res_used["status"], BrowserLoginResult.USED)

    # -------------------------------------------------------------------------
    # 6. Expiration Contract
    # -------------------------------------------------------------------------
    def test_expiration_lifecycle(self):
        """Expired requests cannot be polled as live, cannot be approved, and cannot be consumed."""
        # Create challenge with 1 second TTL
        short_store = BrowserLoginStore(self.db_path, default_ttl_seconds=1)
        challenge = short_store.create(ttl_seconds=1)
        req_id = challenge["request_id"]
        secret = challenge["poll_secret"]

        # Wait for expiration
        time.sleep(1.1)

        # Polling returns expired
        poll_res = short_store.poll(req_id, secret)
        self.assertEqual(poll_res["status"], BrowserLoginResult.EXPIRED)

        # Approval of expired request fails
        app_res = short_store.approve(req_id, telegram_id=999)
        self.assertFalse(app_res["success"])
        self.assertEqual(app_res["status"], BrowserLoginResult.EXPIRED)

        # Consumption of expired request fails
        con_res = short_store.consume(req_id, secret)
        self.assertEqual(con_res["status"], BrowserLoginResult.EXPIRED)

    # -------------------------------------------------------------------------
    # 7. Brute Force & Secret Guessing Protection
    # -------------------------------------------------------------------------
    def test_brute_force_lockout(self):
        """Submitting wrong secrets increments failure counter and locks after max_attempts."""
        challenge = self.store.create()
        req_id = challenge["request_id"]
        real_secret = challenge["poll_secret"]
        wrong_secret = "invalid_secret_token_1234567890abcdef"

        # 4 wrong attempts allowed (max is 5)
        for i in range(1, 5):
            res = self.store.poll(req_id, wrong_secret)
            self.assertEqual(res["status"], BrowserLoginResult.INVALID_SECRET)
            self.assertEqual(res["attempts_left"], 5 - i)

        # 5th wrong attempt triggers lockout
        res5 = self.store.poll(req_id, wrong_secret)
        self.assertEqual(res5["status"], BrowserLoginResult.LOCKED)

        # Even with REAL secret, request is now locked out
        res_locked = self.store.poll(req_id, real_secret)
        self.assertEqual(res_locked["status"], BrowserLoginResult.LOCKED)

        # Cannot consume locked request
        res_con = self.store.consume(req_id, real_secret)
        self.assertEqual(res_con["status"], BrowserLoginResult.LOCKED)

    # -------------------------------------------------------------------------
    # 8. Malformed Input Protection
    # -------------------------------------------------------------------------
    def test_malformed_input_rejection(self):
        """Malformed request IDs, secrets, or telegram IDs must be safely rejected."""
        # Non-string or SQL-injection style IDs
        bad_ids = [None, 12345, "", "   ", "a" * 200, "drop table users;--", "<script>"]
        for bad in bad_ids:
            res_poll = self.store.poll(bad, "some_secret_12345")
            self.assertIn(res_poll["status"], (BrowserLoginResult.MALFORMED_INPUT, BrowserLoginResult.NOT_FOUND))

            res_app = self.store.approve(bad, telegram_id=100)
            self.assertFalse(res_app["success"])
            self.assertIn(res_app["status"], (BrowserLoginResult.MALFORMED_INPUT, BrowserLoginResult.NOT_FOUND))

        # Bad telegram IDs
        ch = self.store.create()
        bad_tg_ids = [None, "", "not_an_int", -500, 0, "admin' OR '1'='1", False]
        for bad_tg in bad_tg_ids:
            res = self.store.approve(ch["request_id"], telegram_id=bad_tg)
            self.assertFalse(res["success"])
            self.assertEqual(res["status"], BrowserLoginResult.MALFORMED_INPUT)

        # Positive string digits should be safely accepted and converted
        res_str_digit = self.store.approve(ch["request_id"], telegram_id="999888")
        self.assertTrue(res_str_digit["success"])
        self.assertEqual(res_str_digit["telegram_id"], 999888)

    # -------------------------------------------------------------------------
    # 9. Challenge Metadata Inspection (for Telegram Bot UI)
    # -------------------------------------------------------------------------
    def test_get_challenge_metadata(self):
        """Telegram bot can look up challenge info without seeing secrets."""
        ch = self.store.create()
        req_id = ch["request_id"]

        info = self.store.get_challenge(req_id)
        self.assertIsNotNone(info)
        self.assertEqual(info["request_id"], req_id)
        self.assertEqual(info["status"], BrowserLoginResult.PENDING)
        self.assertTrue(info["is_live"])
        self.assertNotIn("secret_hash", info)
        self.assertNotIn("salt", info)

        # Non-existent returns None
        self.assertIsNone(self.store.get_challenge("non_existent_req_id"))

    # -------------------------------------------------------------------------
    # 10. Atomic Consumption & Preferred Exchange Callback
    # -------------------------------------------------------------------------
    def test_consume_with_claim_token_guard(self):
        """Single-use consume issues a unique claim token and prevents replay."""
        challenge = self.store.create()
        req_id = challenge["request_id"]
        secret = challenge["poll_secret"]

        # Must be approved first
        pending_con = self.store.consume(req_id, secret)
        self.assertEqual(pending_con["status"], BrowserLoginResult.PENDING)

        self.store.approve(req_id, telegram_id=777888, telegram_username="guard_user")

        # First consumption succeeds and issues claim_token
        res1 = self.store.consume(req_id, secret)
        self.assertEqual(res1["status"], BrowserLoginResult.CONSUMED)
        self.assertEqual(res1["telegram_id"], 777888)
        self.assertEqual(res1["telegram_username"], "guard_user")
        self.assertTrue(bool(res1.get("claim_token")))

        # Second consumption fails with 'used'
        res2 = self.store.consume(req_id, secret)
        self.assertEqual(res2["status"], BrowserLoginResult.USED)

    def test_consume_with_exchange_callback_success(self):
        """Exchange callback issues web session atomically inside the transaction."""
        challenge = self.store.create()
        req_id = challenge["request_id"]
        secret = challenge["poll_secret"]
        self.store.approve(req_id, telegram_id=555444, telegram_username="sess_user")

        def mock_issue_session(payload):
            self.assertEqual(payload["telegram_id"], 555444)
            self.assertEqual(payload["telegram_username"], "sess_user")
            self.assertIsNotNone(payload["claim_token"])
            return {"session_id": "sess_tok_998877", "csrf": "csrf_1234"}

        consume_res = self.store.consume(req_id, secret, exchange_callback=mock_issue_session)
        self.assertEqual(consume_res["status"], BrowserLoginResult.CONSUMED)
        self.assertIn("session", consume_res)
        self.assertEqual(consume_res["session"]["session_id"], "sess_tok_998877")

        # Now marked used
        self.assertEqual(self.store.poll(req_id, secret)["status"], BrowserLoginResult.USED)

    def test_consume_with_exchange_callback_failure_rollback(self):
        """If exchange callback raises, transaction rolls back and challenge is not burned."""
        challenge = self.store.create()
        req_id = challenge["request_id"]
        secret = challenge["poll_secret"]
        self.store.approve(req_id, telegram_id=333222)

        def failing_session_issuer(payload):
            raise RuntimeError("upstream session store unavailable")

        consume_res = self.store.consume(req_id, secret, exchange_callback=failing_session_issuer)
        self.assertEqual(consume_res["status"], BrowserLoginResult.EXCHANGE_FAILED)

        # Challenge remains approved and unconsumed!
        poll_res = self.store.poll(req_id, secret)
        self.assertEqual(poll_res["status"], BrowserLoginResult.APPROVED)

        # Subsequent consume without error can still succeed
        good_res = self.store.consume(req_id, secret)
        self.assertEqual(good_res["status"], BrowserLoginResult.CONSUMED)

    # -------------------------------------------------------------------------
    # 11. Concurrency & Race Condition Tests (Real SQLite)
    # -------------------------------------------------------------------------
    def test_concurrent_consumption_race_condition(self):
        """10 concurrent threads racing to consume the same challenge: exactly 1 wins."""
        challenge = self.store.create()
        req_id = challenge["request_id"]
        secret = challenge["poll_secret"]
        self.store.approve(req_id, telegram_id=101010)

        results = []
        barrier = threading.Barrier(10)

        def worker():
            thread_store = BrowserLoginStore(self.db_path)
            barrier.wait()
            res = thread_store.consume(req_id, secret)
            results.append(res["status"])

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Exactly 1 'consumed' and 9 'used'
        self.assertEqual(results.count(BrowserLoginResult.CONSUMED), 1, f"Expected exactly 1 consumed, got: {results}")
        self.assertEqual(results.count(BrowserLoginResult.USED), 9, f"Expected 9 used, got: {results}")

    def test_concurrent_binding_race_condition(self):
        """10 concurrent threads racing to approve the same challenge with different users: exactly 1 wins."""
        challenge = self.store.create()
        req_id = challenge["request_id"]

        results = []
        barrier = threading.Barrier(10)

        def worker(user_id):
            thread_store = BrowserLoginStore(self.db_path)
            barrier.wait()
            res = thread_store.approve(req_id, telegram_id=user_id)
            results.append(res["status"])

        threads = [threading.Thread(target=worker, args=(2000 + i,)) for i in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Exactly 1 approved and 9 already_bound
        self.assertEqual(results.count(BrowserLoginResult.APPROVED), 1, f"Expected exactly 1 approved, got: {results}")
        self.assertEqual(results.count(BrowserLoginResult.ALREADY_BOUND), 9, f"Expected 9 already_bound, got: {results}")


if __name__ == "__main__":
    unittest.main()
