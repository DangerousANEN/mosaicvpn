"""Tiered re-verify TTL tests for mosaic_pool_scheduler.

Contract (verify_ttl_for):
- NEW (proxy_ok != True or verification_count < 2) -> 1h
- DEGRADED (proxy_ok True, >=2 lifetime failures)    -> 30m
- HEALTHY (proxy_ok True, >=2 verifications, <2 failures) -> 4h
- Global verify_ttl ceiling applies when smaller; floor is 60s.
- update_state accumulates verification_count / failure_count.
- sanitize_state preserves the new fields.
- schedule_candidates Tier-1 refresh uses the per-node TTL:
  a HEALTHY node must NOT be scheduled for refresh before 4h*0.8,
  while a NEW node must be scheduled after 1h*0.8.
"""
import copy
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mosaic_pool_scheduler import (
    DEFAULT_TTL_NEW_SECONDS,
    DEFAULT_TTL_DEGRADED_SECONDS,
    DEFAULT_TTL_HEALTHY_SECONDS,
    DEFAULT_REFRESH_RATIO,
    init_scheduler_state,
    sanitize_state,
    schedule_candidates,
    update_state,
    verify_ttl_for,
)


def _node(fp, cc=None, src="src-a"):
    return {"fingerprint": fp, "source_name": src, "country_code": cc}


class _FakeNode:
    """Attribute-style node as produced by the collector."""

    def __init__(self, fp, cc=None, src="src-a", proxy_ok=None):
        self.fingerprint = fp
        self.source_name = src
        self.country_code = cc
        self.proxy_ok = proxy_ok


class TestVerifyTtlTiers(unittest.TestCase):
    def test_new_unverified(self):
        self.assertEqual(verify_ttl_for({"proxy_ok": None}), DEFAULT_TTL_NEW_SECONDS)

    def test_new_first_verification(self):
        meta = {"proxy_ok": True, "verification_count": 1, "failure_count": 0}
        self.assertEqual(verify_ttl_for(meta), DEFAULT_TTL_NEW_SECONDS)

    def test_healthy_two_verifications(self):
        meta = {"proxy_ok": True, "verification_count": 2, "failure_count": 0}
        self.assertEqual(verify_ttl_for(meta), DEFAULT_TTL_HEALTHY_SECONDS)

    def test_degraded_with_failures(self):
        meta = {"proxy_ok": True, "verification_count": 5, "failure_count": 3}
        self.assertEqual(verify_ttl_for(meta), DEFAULT_TTL_DEGRADED_SECONDS)

    def test_ceiling_smaller_than_tier(self):
        meta = {"proxy_ok": True, "verification_count": 9, "failure_count": 0}
        ttl = verify_ttl_for(meta, verify_ttl=600.0)
        self.assertEqual(ttl, 600.0)

    def test_floor_sixty_seconds(self):
        ttl = verify_ttl_for({}, ttl_new=1.0, ttl_degraded=1.0, ttl_healthy=1.0)
        self.assertEqual(ttl, 60.0)

    def test_missing_meta_is_new(self):
        self.assertEqual(verify_ttl_for(None), DEFAULT_TTL_NEW_SECONDS)


class TestUpdateStateEvidence(unittest.TestCase):
    def test_verification_and_failure_counts_accumulate(self):
        state = init_scheduler_state()
        node = _FakeNode("fp-1")
        update_state(state, [node], now=100.0)  # proxy_ok None -> no evidence
        meta = state["candidates"]["fp-1"]
        self.assertEqual(meta.get("verification_count") or 0, 0)
        self.assertEqual(meta.get("failure_count") or 0, 0)

        ok_node = _FakeNode("fp-1", proxy_ok=True)
        update_state(state, [ok_node], now=200.0)
        self.assertEqual(state["candidates"]["fp-1"]["verification_count"], 1)

        update_state(state, [ok_node], now=300.0)
        self.assertEqual(state["candidates"]["fp-1"]["verification_count"], 2)
        self.assertEqual(state["candidates"]["fp-1"]["failure_count"], 0)
        # 2 verifications, no failures -> HEALTHY
        self.assertEqual(verify_ttl_for(state["candidates"]["fp-1"]), DEFAULT_TTL_HEALTHY_SECONDS)

        bad_node = _FakeNode("fp-1", proxy_ok=False)
        update_state(state, [bad_node], now=400.0)
        self.assertEqual(state["candidates"]["fp-1"]["failure_count"], 1)
        # proxy_ok now False -> NEW tier applies
        self.assertEqual(verify_ttl_for(state["candidates"]["fp-1"]), DEFAULT_TTL_NEW_SECONDS)

    def test_sanitize_preserves_evidence(self):
        state = init_scheduler_state()
        state["candidates"]["fp-x"] = {
            "source_name": "s",
            "country_code": "DE",
            "consecutive_fails": 0,
            "cooldown_until": 0.0,
            "last_seen_at": 1.0,
            "last_scheduled_at": 0.0,
            "last_checked_at": 1.0,
            "last_verified_at": 1.0,
            "proxy_ok": True,
            "verification_count": 7,
            "failure_count": 2,
        }
        clean = sanitize_state(state)
        self.assertEqual(clean["candidates"]["fp-x"]["verification_count"], 7)
        self.assertEqual(clean["candidates"]["fp-x"]["failure_count"], 2)
        # 7 verifications + 2 failures -> DEGRADED
        self.assertEqual(verify_ttl_for(clean["candidates"]["fp-x"]), DEFAULT_TTL_DEGRADED_SECONDS)


class TestScheduleTieredRefresh(unittest.TestCase):
    def _seed(self, state, fp, verified_at, now, verification_count, failure_count):
        state["candidates"][fp] = {
            "source_name": "s",
            "country_code": "DE",
            "consecutive_fails": 0,
            "cooldown_until": 0.0,
            "last_seen_at": now,
            "last_scheduled_at": 0.0,
            "last_checked_at": verified_at,
            "last_verified_at": verified_at,
            "proxy_ok": True,
            "verification_count": verification_count,
            "failure_count": failure_count,
        }

    def test_healthy_node_not_refreshed_before_healthy_threshold(self):
        # 4h * 0.8 = 3.2h; node verified 1h ago with a HEALTHY record must NOT
        # be overdue for refresh (old flat 2h*0.8 = 1.6h WOULD have flagged it).
        # We measure the overdue classification directly: replicate the Tier-1
        # overdue predicate from schedule_candidates with a controlled state.
        state = init_scheduler_state()
        now = 100000.0
        self._seed(state, "fp-h", verified_at=now - 3600, now=now,
                   verification_count=10, failure_count=0)
        meta = state["candidates"]["fp-h"]
        age = now - meta["last_verified_at"]
        ttl = verify_ttl_for(meta)
        threshold = ttl * DEFAULT_REFRESH_RATIO
        self.assertGreater(threshold, age,
                           "HEALTHY node 1h after verification must not be overdue")

    def test_healthy_node_eventually_refreshed(self):
        # Same HEALTHY node 4h after verification IS overdue (4h >= 3.2h).
        state = init_scheduler_state()
        now = 100000.0
        self._seed(state, "fp-h", verified_at=now - 4 * 3600, now=now,
                   verification_count=10, failure_count=0)
        meta = state["candidates"]["fp-h"]
        age = now - meta["last_verified_at"]
        ttl = verify_ttl_for(meta)
        threshold = ttl * DEFAULT_REFRESH_RATIO
        self.assertLessEqual(threshold, age,
                             "HEALTHY node 4h after verification must be overdue")

    def test_new_node_refreshed_after_new_threshold(self):
        # 1h * 0.8 = 0.8h; NEW node verified 1h ago must be selected.
        state = init_scheduler_state()
        now = 100000.0
        self._seed(state, "fp-n", verified_at=now - 3600, now=now,
                   verification_count=1, failure_count=0)
        picked = schedule_candidates([_node("fp-n", cc="DE")], 10, state, now)
        self.assertEqual(len(picked), 1, "NEW node must be refreshed at 1h*0.8")

    def test_degraded_node_refreshed_after_degraded_threshold(self):
        # 30m * 0.8 = 24m; DEGRADED node verified 30m ago must be selected
        # even though a HEALTHY TTL would never fire this early.
        state = init_scheduler_state()
        now = 100000.0
        self._seed(state, "fp-d", verified_at=now - 1800, now=now,
                   verification_count=6, failure_count=2)
        picked = schedule_candidates([_node("fp-d", cc="DE")], 10, state, now)
        self.assertEqual(len(picked), 1, "DEGRADED node must be refreshed at 30m*0.8")


if __name__ == "__main__":
    unittest.main()
