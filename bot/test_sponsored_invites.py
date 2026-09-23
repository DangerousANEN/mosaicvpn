import unittest
import datetime
import os
import tempfile
import threading
from bot.sponsored_invites import SponsoredInviteStore


class TestSponsoredInviteStore(unittest.TestCase):
    def setUp(self):
        self.store = SponsoredInviteStore(":memory:")

    def test_create_valid_invite_returns_record_and_token(self):
        record, token = self.store.create(
            admin_id=12345,
            amount=500,
            label="Gift for Alice",
            request_id="req-1",
            ttl_seconds=86400
        )
        self.assertIsNotNone(record)
        self.assertIsNotNone(token)
        self.assertIsInstance(token, str)
        self.assertGreater(len(token), 16)
        self.assertEqual(record["admin_id"], 12345)
        self.assertEqual(record["amount"], 500)
        self.assertEqual(record["label"], "Gift for Alice")
        self.assertEqual(record["request_id"], "req-1")
        self.assertEqual(record["status"], "pending")
        self.assertIn("expires_at", record)
        self.assertNotIn("token", record)  # token raw is NOT stored directly in the record fields
        self.assertIn("token_hash", record)

    def test_create_idempotent_same_admin_request_and_payload(self):
        record1, token1 = self.store.create(
            admin_id=12345,
            amount=500,
            label="Gift for Alice",
            request_id="req-1",
            ttl=3600
        )
        self.assertIsNotNone(token1)

        # Repeating with same payload should return existing record and None for token (token returned once)
        record2, token2 = self.store.create(
            admin_id=12345,
            amount=500,
            label="Gift for Alice",
            request_id="req-1",
            ttl=3600
        )
        self.assertEqual(record1["id"], record2["id"])
        self.assertIsNone(token2)

    def test_create_conflict_different_payload(self):
        self.store.create(
            admin_id=12345,
            amount=500,
            label="Gift for Alice",
            request_id="req-1",
        )
        with self.assertRaises(ValueError):
            self.store.create(
                admin_id=12345,
                amount=600,  # different amount
                label="Gift for Alice",
                request_id="req-1",
            )

    def test_amount_rejections_bool_float_nan_inf_limits(self):
        invalid_amounts = [
            True, False, 0, -1, 10001, 500.5, float("nan"), float("inf"),
            float("-inf"), "500", None, [], {}, (500,)
        ]
        for idx, val in enumerate(invalid_amounts):
            with self.subTest(val=val):
                with self.assertRaises((TypeError, ValueError)):
                    self.store.create(
                        admin_id=12345,
                        amount=val,
                        label="Gift",
                        request_id=f"req-invalid-{idx}",
                    )

    def test_label_validation(self):
        invalid_labels = [
            "", "   ", "a" * 81, None, 123, True, []
        ]
        for idx, lbl in enumerate(invalid_labels):
            with self.subTest(lbl=lbl):
                with self.assertRaises((TypeError, ValueError)):
                    self.store.create(
                        admin_id=12345,
                        amount=500,
                        label=lbl,
                        request_id=f"req-lbl-{idx}",
                    )

    def test_ttl_validation(self):
        invalid_ttls = [
            -1, 0, 7 * 86400 + 1, "3600", 3600.5, True, False, None, float("nan")
        ]
        for idx, ttl_val in enumerate(invalid_ttls):
            with self.subTest(ttl_val=ttl_val):
                with self.assertRaises((TypeError, ValueError)):
                    self.store.create(
                        admin_id=12345,
                        amount=500,
                        label="Gift",
                        request_id=f"req-ttl-{idx}",
                        ttl=ttl_val,
                    )


    def test_list_admin_invites_no_secrets(self):
        self.store.create(
            admin_id=1001,
            amount=100,
            label="Gift 1",
            request_id="req-admin1-1",
        )
        self.store.create(
            admin_id=1001,
            amount=200,
            label="Gift 2",
            request_id="req-admin1-2",
        )
        self.store.create(
            admin_id=1002,
            amount=300,
            label="Gift Other Admin",
            request_id="req-admin2-1",
        )

        invites_admin1 = self.store.list(1001)
        self.assertEqual(len(invites_admin1), 2)
        for inv in invites_admin1:
            self.assertEqual(inv["admin_id"], 1001)
            self.assertNotIn("token", inv)
            self.assertNotIn("token_hash", inv)
            self.assertIn("id", inv)
            self.assertIn("amount", inv)
            self.assertIn("label", inv)
            self.assertIn("status", inv)

        invites_admin2 = self.store.list(1002)
        self.assertEqual(len(invites_admin2), 1)
        self.assertEqual(invites_admin2[0]["admin_id"], 1002)

        invites_admin3 = self.store.list(1003)
        self.assertEqual(len(invites_admin3), 0)

        # Rejection of invalid admin_id
        with self.assertRaises((TypeError, ValueError)):
            self.store.list("1001")
        with self.assertRaises((TypeError, ValueError)):
            self.store.list(True)
        with self.assertRaises((TypeError, ValueError)):
            self.store.list(-5)

    def test_claim_success_transitions_to_processing(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=250,
            label="Friend gift",
            request_id="req-claim-1",
        )
        res = self.store.claim(token, telegram_id=999001, claimant_label="Alice (@alice)")
        self.assertTrue(res.is_claimed)
        self.assertIsNone(res.error)
        self.assertEqual(res.status, "claimed")
        self.assertIsNotNone(res.record)
        self.assertEqual(res.record["status"], "processing")
        self.assertEqual(res.record["claimant_telegram_id"], 999001)
        self.assertEqual(res.record["claimant_label"], "Alice (@alice)")
        self.assertIsNotNone(res.record["claimed_at"])

        # Unpacking as 2-tuple should also work seamlessly
        claimed_rec, err = res
        self.assertEqual(claimed_rec["id"], record["id"])
        self.assertIsNone(err)

    def test_claim_repeat_same_user_gets_state_no_double_execute(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=250,
            label="Friend gift",
            request_id="req-claim-repeat",
        )
        res1 = self.store.claim(token, telegram_id=999001)
        self.assertTrue(res1.is_claimed)
        self.assertEqual(res1.record["status"], "processing")

        # Second call by same user
        res2 = self.store.claim(token, telegram_id=999001)
        self.assertFalse(res2.is_claimed)
        self.assertTrue(res2.is_repeat)
        self.assertEqual(res2.error, "repeat")
        self.assertEqual(res2.status, "repeat")
        self.assertIsNotNone(res2.record)
        self.assertEqual(res2.record["id"], record["id"])
        self.assertEqual(res2.record["status"], "processing")

    def test_claim_locked_to_first_friend_rejects_second_friend(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=250,
            label="Friend gift",
            request_id="req-claim-lock",
        )
        res1 = self.store.claim(token, telegram_id=999001)
        self.assertTrue(res1.is_claimed)

        # Different user tries to claim
        res2 = self.store.claim(token, telegram_id=999002)
        self.assertFalse(res2.is_claimed)
        self.assertFalse(res2.is_repeat)
        self.assertEqual(res2.error, "already_claimed")
        self.assertEqual(res2.status, "already_claimed")
        self.assertIsNone(res2.record)

    def test_claim_not_found(self):
        res = self.store.claim("non-existent-token-12345", telegram_id=999001)
        self.assertFalse(res.is_claimed)
        self.assertIsNone(res.record)
        self.assertEqual(res.error, "not_found")
        self.assertEqual(res.status, "not_found")

    def test_claim_validation(self):
        _, token = self.store.create(
            admin_id=1001,
            amount=100,
            label="Validation",
            request_id="req-val",
        )
        invalid_ids = [True, False, 0, "999", None, 3.14]
        for val in invalid_ids:
            with self.subTest(val=val):
                with self.assertRaises((TypeError, ValueError)):
                    self.store.claim(token, account_id=val)

        invalid_tokens = ["", "  ", None, 123, True]
        for tok in invalid_tokens:
            with self.subTest(tok=tok):
                with self.assertRaises((TypeError, ValueError)):
                    self.store.claim(tok, account_id=999001)

    def test_claim_allows_negative_synthetic_account_ids(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=100,
            label="Negative synthetic account ID",
            request_id="req-neg-id",
        )
        res = self.store.claim(token, account_id=-100500, claimant_label="Web Client -100500")
        self.assertTrue(res.is_claimed)
        self.assertEqual(res.record["claimant_account_id"], -100500)

    def test_gift_url_generation(self):
        from bot.sponsored_invites import build_gift_url
        url = build_gift_url("test_tok_123", "https://mosaicvpn.example.com")
        self.assertEqual(url, "https://mosaicvpn.example.com/setup.html#gift=test_tok_123")
        url_rel = build_gift_url("test_tok_456")
        self.assertEqual(url_rel, "/setup.html#gift=test_tok_456")

    def test_finish_cas_transitions(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=500,
            label="Finish test",
            request_id="req-finish-1",
        )
        # Cannot finish a pending invite
        self.assertFalse(self.store.finish(record["id"], "succeeded", result="ok"))

        # Claim the invite -> moves to processing
        claim_res = self.store.claim(token, account_id=888111)
        self.assertTrue(claim_res.is_claimed)
        self.assertEqual(claim_res.record["status"], "processing")

        # Invalid status rejected
        with self.assertRaises(ValueError):
            self.store.finish(record["id"], "invalid_status")

        # First finish moves processing -> succeeded
        self.assertTrue(self.store.finish(record["id"], "succeeded", result="cred_123"))

        # Second finish on already succeeded invite returns False (CAS failed)
        self.assertFalse(self.store.finish(record["id"], "failed", error="should not overwrite"))

        # Repeat claim sees succeeded status and cannot re-claim
        rep_res = self.store.claim(token, account_id=888111)
        self.assertTrue(rep_res.is_repeat)
        self.assertEqual(rep_res.record["status"], "succeeded")
        self.assertEqual(rep_res.record["result"], "cred_123")

    def test_finish_uncertain_status_never_blindly_retries(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=500,
            label="Uncertain test",
            request_id="req-finish-uncertain",
        )
        claim_res = self.store.claim(token, account_id=888222)
        self.assertTrue(claim_res.is_claimed)

        # Provider timed out / network partition -> uncertain
        self.assertTrue(self.store.finish(record["id"], "uncertain", error="Gateway timeout"))

        # CAS prevents finishing again
        self.assertFalse(self.store.finish(record["id"], "succeeded", result="new_attempt"))

        # Repeat claim by same claimant reports uncertain state, never pending
        rep_res = self.store.claim(token, account_id=888222)
        self.assertTrue(rep_res.is_repeat)
        self.assertEqual(rep_res.record["status"], "uncertain")
        self.assertEqual(rep_res.record["error"], "Gateway timeout")

        # Different claimant still blocked
        other_claim = self.store.claim(token, account_id=888333)
        self.assertFalse(other_claim.is_claimed)
        self.assertEqual(other_claim.error, "already_claimed")

    def test_revoke_only_pending_creator(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=500,
            label="Revoke test",
            request_id="req-revoke-1",
        )
        # Unauthorized admin cannot revoke
        self.assertFalse(self.store.revoke(record["id"], admin_id=1002))

        # Authorized admin revokes successfully
        self.assertTrue(self.store.revoke(record["id"], admin_id=1001))

        # Revoking again returns False
        self.assertFalse(self.store.revoke(record["id"], admin_id=1001))

        # Claiming a revoked invite fails
        res = self.store.claim(token, account_id=999111)
        self.assertFalse(res.is_claimed)
        self.assertEqual(res.error, "revoked")
        self.assertEqual(res.status, "revoked")

    def test_revoke_fails_if_already_processing_or_succeeded(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=500,
            label="Revoke processing test",
            request_id="req-revoke-proc",
        )
        # Friend claims it -> status 'processing'
        res = self.store.claim(token, account_id=999222)
        self.assertTrue(res.is_claimed)

        # Admin tries to revoke while in processing -> must fail
        self.assertFalse(self.store.revoke(record["id"], admin_id=1001))

        # Admin finishes -> status 'succeeded'
        self.assertTrue(self.store.finish(record["id"], "succeeded", result="ok"))

        # Admin tries to revoke succeeded -> must fail
        self.assertFalse(self.store.revoke(record["id"], admin_id=1001))

    def test_expired_invite_blocked_from_claim(self):
        record, token = self.store.create(
            admin_id=1001,
            amount=500,
            label="Expired test",
            request_id="req-expired",
            ttl=1,  # 1 second TTL
        )
        # Directly update expires_at in DB to simulate passage of time
        with self.store._get_connection() as conn:
            past = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=10)).isoformat()
            conn.execute("UPDATE sponsored_invites SET expires_at = ? WHERE id = ?", (past, record["id"]))
            conn.commit()

        res = self.store.claim(token, account_id=999333)
        self.assertFalse(res.is_claimed)
        self.assertEqual(res.error, "expired")
        self.assertEqual(res.status, "expired")

    def test_revoke_fails_if_expired(self):
        record, _ = self.store.create(
            admin_id=1001,
            amount=500,
            label="Expired revoke test",
            request_id="req-exp-rev",
            ttl=1,
        )
        with self.store._get_connection() as conn:
            past = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=10)).isoformat()
            conn.execute("UPDATE sponsored_invites SET expires_at = ? WHERE id = ?", (past, record["id"]))
            conn.commit()

        # Attempting to revoke an expired invite must return False
        self.assertFalse(self.store.revoke(record["id"], admin_id=1001))

    def test_atomic_concurrent_redemption_different_users(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = os.path.join(temp_dir, "race_test.db")
            store = SponsoredInviteStore(db_path)
            record, token = store.create(
                admin_id=1001,
                amount=500,
                label="Concurrent race test",
                request_id="req-race-1",
            )

            num_threads = 15
            barrier = threading.Barrier(num_threads)
            results = [None] * num_threads

            def worker(thread_idx: int):
                # Each thread uses its own store/connection instance to test real multi-connection SQLite locking
                thread_store = SponsoredInviteStore(db_path)
                account_id = 7000 + thread_idx
                barrier.wait()
                res = thread_store.claim(token, account_id=account_id, claimant_label=f"User {thread_idx}")
                results[thread_idx] = (account_id, res)

            threads = [threading.Thread(target=worker, args=(i,)) for i in range(num_threads)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

            winners = [r for r in results if r[1].is_claimed]
            losers = [r for r in results if not r[1].is_claimed]

            self.assertEqual(len(winners), 1, f"Expected exactly 1 winner, got {len(winners)}")
            self.assertEqual(len(losers), num_threads - 1)

            winner_account_id, winner_res = winners[0]
            self.assertEqual(winner_res.status, "claimed")
            self.assertIsNone(winner_res.error)
            self.assertEqual(winner_res.record["status"], "processing")
            self.assertEqual(winner_res.record["claimant_account_id"], winner_account_id)

            for loser_account_id, loser_res in losers:
                self.assertFalse(loser_res.is_claimed)
                self.assertEqual(loser_res.error, "already_claimed")
                self.assertIsNone(loser_res.record)

    def test_atomic_concurrent_redemption_same_user_replay(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = os.path.join(temp_dir, "same_user_race.db")
            store = SponsoredInviteStore(db_path)
            record, token = store.create(
                admin_id=1001,
                amount=350,
                label="Concurrent same user test",
                request_id="req-race-same",
            )

            num_threads = 10
            same_account_id = -999888
            barrier = threading.Barrier(num_threads)
            results = [None] * num_threads

            def worker(thread_idx: int):
                thread_store = SponsoredInviteStore(db_path)
                barrier.wait()
                res = thread_store.claim(token, account_id=same_account_id, claimant_label="Same User")
                results[thread_idx] = res

            threads = [threading.Thread(target=worker, args=(i,)) for i in range(num_threads)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

            first_claims = [r for r in results if r.is_claimed]
            repeats = [r for r in results if r.is_repeat]

            self.assertEqual(len(first_claims), 1, f"Expected exactly 1 first claim, got {len(first_claims)}")
            self.assertEqual(len(repeats), num_threads - 1)
            for rep in repeats:
                self.assertEqual(rep.status, "repeat")
                self.assertEqual(rep.error, "repeat")
                self.assertIsNotNone(rep.record)
                self.assertEqual(rep.record["id"], record["id"])
                self.assertEqual(rep.record["status"], "processing")


    def test_get_invite_by_id_and_ownership(self):
        record, _ = self.store.create(
            admin_id=1001,
            amount=500,
            label="Get test",
            request_id="req-get-1",
        )
        # Query without admin_id filter
        fetched = self.store.get(record["id"])
        self.assertIsNotNone(fetched)
        self.assertEqual(fetched["id"], record["id"])
        self.assertNotIn("token", fetched)
        self.assertNotIn("token_hash", fetched)

        # Query with matching admin_id
        fetched_admin = self.store.get(record["id"], admin_id=1001)
        self.assertIsNotNone(fetched_admin)
        self.assertEqual(fetched_admin["id"], record["id"])

        # Query with non-matching admin_id
        self.assertIsNone(self.store.get(record["id"], admin_id=1002))

        # Query non-existent ID
        self.assertIsNone(self.store.get("non-existent-id"))

    def test_concurrent_idempotent_create(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = os.path.join(temp_dir, "concurrent_create.db")
            num_threads = 10
            barrier = threading.Barrier(num_threads)
            results = [None] * num_threads

            def worker(thread_idx: int):
                thread_store = SponsoredInviteStore(db_path)
                barrier.wait()
                rec, tok = thread_store.create(
                    admin_id=2001,
                    amount=500,
                    label="Concurrent create gift",
                    request_id="req-concurrent-create-fixed",
                )
                results[thread_idx] = (rec, tok)

            threads = [threading.Thread(target=worker, args=(i,)) for i in range(num_threads)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

            records = [r[0] for r in results]
            tokens = [r[1] for r in results if r[1] is not None]

            # All records must have the exact same invite ID
            self.assertEqual(len(set(r["id"] for r in records)), 1)
            # The unguessable token must only be issued ONCE
            self.assertEqual(len(tokens), 1)


if __name__ == "__main__":
    unittest.main()

