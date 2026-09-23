"""test_pool_scheduler.py — Unit and regression test suite for mosaic_pool_scheduler.

Covers:
1. Hard budget ceilings (zero, negative, tiny limits).
2. Deterministic clocks across time progression.
3. Priority for overdue previously verified/reserve nodes.
4. Priority for country deficits against targets.
5. Bounded exponential cooldown with deterministic jitter (cooldown skipping and expiry).
6. Source yield EWMA updating ONLY on actual proxy checks (True/False/None).
7. Anti-starvation guarantee for low-yield sources during rotating exploration.
8. Deterministic rotation across multiple cycles (preventing feed-prefix bias).
9. Strict state hygiene: no credentials or configs stored in state.
# State bounding and TTL pruning.
11. Atomic state persistence and recovery.
12. Proactive refresh before TTL expiry.
13. Overdue refresh cannot starve discovery and country deficits.
14. Stale/failed candidates do not produce false country quorum.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import shutil
import tempfile
from typing import Any, Dict, List, Optional
import unittest

from bot.mosaic_pool_scheduler import (
    DEFAULT_BASE_COOLDOWN,
    DEFAULT_MAX_COOLDOWN,
    DEFAULT_VERIFY_TTL,
    compute_cooldown,
    init_scheduler_state,
    load_scheduler_state,
    load_state,
    prune_state,
    save_scheduler_state,
    save_state,
    schedule_candidates,
    update_state,
)

SANDBOX_DIR = Path("/tmp/mosaic-scheduler")


@dataclass
class DummyNode:
    """Mock node mimicking mosaic_pool_collector.Node."""
    fingerprint: str
    source_name: str
    country_code: Optional[str] = None
    protocol: str = "vless"
    address: str = "192.0.2.1"
    port: int = 443
    config: Optional[dict] = None
    tcp_ok: Optional[bool] = None
    proxy_ok: Optional[bool] = None


class TestPoolScheduler(unittest.TestCase):
    """Isolated test suite using deterministic clocks and sandbox storage."""

    def setUp(self):
        SANDBOX_DIR.mkdir(parents=True, exist_ok=True)
        self.test_dir = Path(tempfile.mkdtemp(prefix="sched_test_", dir=str(SANDBOX_DIR)))
        self.state_file = self.test_dir / "scheduler_state.json"

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    # ── 1. Hard Budget Ceilings ────────────────────────────────────────────────

    def test_budget_ceilings_zero_negative_tiny(self):
        """Hard ceilings: zero/negative returns empty, tiny budgets strictly capped."""
        nodes = [
            DummyNode(fingerprint=f"fp_{i}", source_name="source_a", country_code="US")
            for i in range(20)
        ]
        state = init_scheduler_state()
        now = 1000.0

        # Zero and negative limits
        self.assertEqual(schedule_candidates(nodes, total_limit=0, state=state, now=now), [])
        self.assertEqual(schedule_candidates(nodes, total_limit=-5, state=state, now=now), [])
        self.assertEqual(schedule_candidates([], total_limit=10, state=state, now=now), [])

        # Tiny limits
        for limit in (1, 2, 3, 5):
            scheduled = schedule_candidates(nodes, total_limit=limit, state=state, now=now)
            self.assertEqual(len(scheduled), limit)
            # Check deduplication
            fps = [n.fingerprint for n in scheduled]
            self.assertEqual(len(fps), len(set(fps)))

    def test_deduplication_in_single_scheduling_call(self):
        """Duplicate fingerprints in input list must only be scheduled once."""
        nodes = [
            DummyNode(fingerprint="duplicate_fp", source_name="src_1", country_code=None),
            DummyNode(fingerprint="duplicate_fp", source_name="src_2", country_code="DE"),
            DummyNode(fingerprint="unique_fp", source_name="src_1", country_code="US"),
        ]
        state = init_scheduler_state()
        scheduled = schedule_candidates(nodes, total_limit=10, state=state, now=1000.0)
        fps = [n.fingerprint for n in scheduled]
        self.assertEqual(fps.count("duplicate_fp"), 1)
        self.assertEqual(len(scheduled), 2)

    # ── 2. Prioritization: Overdue Previously Verified / Reserve ──────────────

    def test_priority_overdue_verified_reserve(self):
        """Previously verified nodes that are overdue for refresh receive top priority."""
        nodes = [
            DummyNode(fingerprint="unverified_1", source_name="src", country_code="US"),
            DummyNode(fingerprint="unverified_2", source_name="src", country_code="US"),
            DummyNode(fingerprint="verified_fresh", source_name="src", country_code="US"),
            DummyNode(fingerprint="verified_overdue", source_name="src", country_code="US"),
        ]
        state = init_scheduler_state()

        # Seed state at t=1000.0
        # verified_overdue was verified at t=500.0 (overdue if verify_ttl=3600 at now=5000.0)
        # verified_fresh was verified at t=4800.0 (fresh)
        state["candidates"]["verified_overdue"] = {
            "source_name": "src",
            "country_code": "US",
            "proxy_ok": True,
            "last_verified_at": 500.0,
            "cooldown_until": 0.0,
        }
        state["candidates"]["verified_fresh"] = {
            "source_name": "src",
            "country_code": "US",
            "proxy_ok": True,
            "last_verified_at": 4800.0,
            "cooldown_until": 0.0,
        }

        now = 5000.0
        # Budget = 1: verified_overdue must win!
        scheduled = schedule_candidates(nodes, total_limit=1, state=state, now=now, verify_ttl=3600.0)
        self.assertEqual(len(scheduled), 1)
        self.assertEqual(scheduled[0].fingerprint, "verified_overdue")

    # ── 3. Prioritization: Country Deficit Allocation ─────────────────────────

    def test_country_deficit_priority(self):
        """Candidates matching countries with targets deficit take priority over others."""
        nodes = [
            DummyNode(fingerprint="nl_1", source_name="src", country_code="NL"),
            DummyNode(fingerprint="nl_2", source_name="src", country_code="NL"),
            DummyNode(fingerprint="de_1", source_name="src", country_code="DE"),
            DummyNode(fingerprint="us_1", source_name="src", country_code="US"),
            DummyNode(fingerprint="us_2", source_name="src", country_code="US"),
        ]
        state = init_scheduler_state()
        now = 1000.0

        # We request 2 NL nodes and 1 DE node; budget is 3
        country_targets = {"NL": 2, "DE": 1, "US": 0}
        scheduled = schedule_candidates(
            nodes,
            total_limit=3,
            state=state,
            now=now,
            country_targets=country_targets,
        )
        self.assertEqual(len(scheduled), 3)
        ccs = sorted([n.country_code for n in scheduled])
        self.assertEqual(ccs, ["DE", "NL", "NL"])

    def test_country_deficit_satisfied_falls_back_to_exploration(self):
        """When country deficits are satisfied, remaining budget explores other candidates."""
        nodes = [
            DummyNode(fingerprint="de_1", source_name="src", country_code="DE"),
            DummyNode(fingerprint="de_2", source_name="src", country_code="DE"),
            DummyNode(fingerprint="us_1", source_name="src", country_code="US"),
            DummyNode(fingerprint="fr_1", source_name="src", country_code="FR"),
        ]
        state = init_scheduler_state()
        now = 1000.0

        # Only 1 DE node deficit; total budget = 3
        country_targets = {"DE": 1}
        scheduled = schedule_candidates(
            nodes,
            total_limit=3,
            state=state,
            now=now,
            country_targets=country_targets,
        )
        self.assertEqual(len(scheduled), 3)
        ccs = [n.country_code for n in scheduled]
        self.assertIn("DE", ccs)
        # Remaining 2 slots filled from US, FR, or surplus DE
        self.assertEqual(len(scheduled), 3)

    # ── 4. Bounded Exponential Cooldown & Deterministic Jitter ────────────────

    def test_deterministic_cooldown_jitter(self):
        """compute_cooldown must be strictly deterministic for identical inputs."""
        fp = "sample_fingerprint_abc123"
        cd1 = compute_cooldown(fp, consecutive_fails=1)
        cd2 = compute_cooldown(fp, consecutive_fails=1)
        self.assertEqual(cd1, cd2)

        # Consecutive fails increase backoff up to max_cooldown
        cd_fail_1 = compute_cooldown(fp, 1, base_cooldown=100.0, max_cooldown=1000.0)
        cd_fail_2 = compute_cooldown(fp, 2, base_cooldown=100.0, max_cooldown=1000.0)
        cd_fail_3 = compute_cooldown(fp, 3, base_cooldown=100.0, max_cooldown=1000.0)
        cd_fail_10 = compute_cooldown(fp, 10, base_cooldown=100.0, max_cooldown=1000.0)

        self.assertGreater(cd_fail_2, cd_fail_1 * 1.5)
        self.assertGreater(cd_fail_3, cd_fail_2 * 1.5)
        self.assertLessEqual(cd_fail_10, 1000.0)

    def test_cooldown_skipping_and_expiry(self):
        """Failing nodes are skipped during cooldown and become eligible again after expiry."""
        node = DummyNode(fingerprint="flaky_node", source_name="src_1", proxy_ok=False)
        state = init_scheduler_state()
        t0 = 1000.0

        # Run probe update marking node as failed
        update_state(state, [node], now=t0, base_cooldown=300.0)
        meta = state["candidates"]["flaky_node"]
        self.assertEqual(meta["consecutive_fails"], 1)
        cooldown_until = meta["cooldown_until"]
        self.assertGreater(cooldown_until, t0)

        # At t=1100 (still in cooldown), scheduling should skip the node
        scheduled_during_cd = schedule_candidates([node], total_limit=5, state=state, now=1100.0)
        self.assertEqual(scheduled_during_cd, [])

        # At t = cooldown_until + 1 (expired), scheduling should include the node
        scheduled_after_cd = schedule_candidates([node], total_limit=5, state=state, now=cooldown_until + 1.0)
        self.assertEqual(len(scheduled_after_cd), 1)
        self.assertEqual(scheduled_after_cd[0].fingerprint, "flaky_node")

    # ── 5. Source Yield EWMA & True / False / None Semantics ───────────────────

    def test_proxy_ok_true_false_none_behavior(self):
        """Verify explicit True / False / None update semantics.
        
        - True: increments success, resets failures, updates EWMA up.
        - False: increments failure, activates cooldown, updates EWMA down.
        - None (untested/TCP-only): never advances failures, never updates EWMA.
        """
        node_true = DummyNode(fingerprint="fp_true", source_name="src_ewma", proxy_ok=True)
        node_false = DummyNode(fingerprint="fp_false", source_name="src_ewma", proxy_ok=False)
        node_none = DummyNode(fingerprint="fp_none", source_name="src_ewma", proxy_ok=None)

        state = init_scheduler_state()
        now = 1000.0

        # 1. Update with proxy_ok=None: must NOT touch EWMA or consecutive_fails
        update_state(state, [node_none], now=now)
        src_meta = state["sources"].get("src_ewma")
        self.assertIsNone(src_meta)  # EWMA not created on None
        self.assertEqual(state["candidates"]["fp_none"]["consecutive_fails"], 0)
        self.assertIsNone(state["candidates"]["fp_none"]["last_verified_at"])

        # 2. Update with proxy_ok=True: updates EWMA up
        update_state(state, [node_true], now=now, ewma_alpha=0.5)
        src_meta = state["sources"]["src_ewma"]
        self.assertEqual(src_meta["checks_count"], 1)
        self.assertEqual(src_meta["success_count"], 1)
        # initial 0.5 -> alpha=0.5: 0.5*0.5 + 0.5*1.0 = 0.75
        self.assertAlmostEqual(src_meta["ewma_yield"], 0.75)
        self.assertEqual(state["candidates"]["fp_true"]["consecutive_fails"], 0)
        self.assertEqual(state["candidates"]["fp_true"]["last_verified_at"], now)

        # 3. Update with proxy_ok=False: updates EWMA down
        update_state(state, [node_false], now=now, ewma_alpha=0.5)
        self.assertEqual(src_meta["checks_count"], 2)
        self.assertEqual(src_meta["success_count"], 1)
        # 0.75 -> alpha=0.5: 0.5*0.75 + 0.5*0.0 = 0.375
        self.assertAlmostEqual(src_meta["ewma_yield"], 0.375)
        self.assertEqual(state["candidates"]["fp_false"]["consecutive_fails"], 1)

        # 4. Another proxy_ok=None: must NOT change checks_count or ewma_yield
        update_state(state, [node_none], now=now + 10.0)
        self.assertEqual(src_meta["checks_count"], 2)
        self.assertAlmostEqual(src_meta["ewma_yield"], 0.375)

    # ── 6. Anti-Starvation for Low-Yield Sources ───────────────────────────────

    def test_low_yield_source_no_starvation(self):
        """Sources with very low EWMA yields must not be starved during exploration."""
        good_nodes = [
            DummyNode(fingerprint=f"good_{i}", source_name="good_src")
            for i in range(10)
        ]
        poor_nodes = [
            DummyNode(fingerprint=f"poor_{i}", source_name="poor_src")
            for i in range(10)
        ]
        all_nodes = good_nodes + poor_nodes

        state = init_scheduler_state()
        # Seed EWMA yields: good=0.95, poor=0.01
        state["sources"]["good_src"] = {"ewma_yield": 0.95, "checks_count": 100, "success_count": 95}
        state["sources"]["poor_src"] = {"ewma_yield": 0.01, "checks_count": 100, "success_count": 1}

        # Schedule a modest budget of 5 candidates
        scheduled = schedule_candidates(all_nodes, total_limit=5, state=state, now=1000.0)
        self.assertEqual(len(scheduled), 5)

        scheduled_sources = [n.source_name for n in scheduled]
        # poor_src must have at least 1 candidate scheduled (no starvation)
        self.assertIn("poor_src", scheduled_sources)
        self.assertIn("good_src", scheduled_sources)

    # ── 7. Deterministic Rotating Exploration (No Feed-Prefix Trap) ────────────

    def test_deterministic_rotating_exploration(self):
        """Subsequent runs rotate through candidates rather than repeating the feed prefix."""
        # 12 nodes across 3 sources
        nodes = []
        for src in ("src_1", "src_2", "src_3"):
            for i in range(4):
                nodes.append(DummyNode(fingerprint=f"{src}_node_{i}", source_name=src))

        state = init_scheduler_state()
        limit = 3  # budget is 3 candidates per run

        seen_fps: List[str] = []
        now = 1000.0
        # Run 4 consecutive scheduling cycles
        for cycle in range(4):
            scheduled = schedule_candidates(nodes, total_limit=limit, state=state, now=now + cycle * 10.0)
            self.assertEqual(len(scheduled), limit)
            for n in scheduled:
                seen_fps.append(n.fingerprint)

        # Total scheduled over 4 runs = 12
        # Verify rotation covered diverse candidates without getting stuck on prefix
        unique_seen = set(seen_fps)
        self.assertGreaterEqual(len(unique_seen), 8)

    # ── 8. State Hygiene: No Credentials or Sensitive Data ─────────────────────

    def test_state_hygiene_no_creds_or_configs(self):
        """Scheduler state must only persist metadata/fingerprints, never credentials."""
        node_with_creds = DummyNode(
            fingerprint="clean_fp_123",
            source_name="src_auth",
            country_code="DE",
            config={
                "type": "vless",
                "server": "1.2.3.4",
                "uuid": "secret-user-uuid-999",
                "password": "super-secret-password",
                "private_key": "sensitive-crypto-key",
            },
            proxy_ok=True,
        )
        state = init_scheduler_state()
        update_state(state, [node_with_creds], now=1000.0)

        # Save to disk
        save_state(self.state_file, state)

        # Read back raw JSON content from disk
        raw_text = self.state_file.read_text(encoding="utf-8")
        self.assertNotIn("secret-user-uuid-999", raw_text)
        self.assertNotIn("super-secret-password", raw_text)
        self.assertNotIn("sensitive-crypto-key", raw_text)
        self.assertNotIn("1.2.3.4", raw_text)

        loaded = load_state(self.state_file)
        self.assertIn("clean_fp_123", loaded["candidates"])
        cand_meta = loaded["candidates"]["clean_fp_123"]
        self.assertNotIn("config", cand_meta)
        self.assertEqual(cand_meta["country_code"], "DE")

    # ── 9. State Bounding & Pruning TTL ────────────────────────────────────────

    def test_state_pruning_unseen_candidates(self):
        """Unseen non-verified candidates older than prune_ttl are purged from state."""
        state = init_scheduler_state()
        t0 = 1000.0
        state["candidates"]["stale_cand"] = {
            "source_name": "src",
            "country_code": "US",
            "proxy_ok": False,
            "last_seen_at": t0 - 100000.0,
        }
        state["candidates"]["verified_cand"] = {
            "source_name": "src",
            "country_code": "US",
            "proxy_ok": True,
            "last_seen_at": t0 - 100000.0,
        }
        state["candidates"]["fresh_cand"] = {
            "source_name": "src",
            "country_code": "US",
            "proxy_ok": False,
            "last_seen_at": t0 - 10.0,
        }

        prune_state(state, now=t0, prune_ttl=3600.0)
        self.assertNotIn("stale_cand", state["candidates"])
        self.assertIn("verified_cand", state["candidates"])  # verified preserved
        self.assertIn("fresh_cand", state["candidates"])     # fresh preserved

    def test_state_hard_max_candidates_bound(self):
        """State size is bounded by max_candidates."""
        state = init_scheduler_state()
        for i in range(50):
            state["candidates"][f"fp_{i}"] = {
                "source_name": "src",
                "proxy_ok": False,
                "last_seen_at": float(i),
            }

        prune_state(state, now=1000.0, prune_ttl=999999.0, max_candidates=20)
        self.assertEqual(len(state["candidates"]), 20)

    # ── 10. Atomic Persistence & Error Recovery ───────────────────────────────

    def test_atomic_save_and_corrupt_load_recovery(self):
        """save_state writes atomically; load_state recovers safely on corrupt file."""
        state = init_scheduler_state()
        state["candidates"]["fp_atom"] = {"source_name": "src", "proxy_ok": True}
        save_scheduler_state(self.state_file, state)

        loaded = load_scheduler_state(self.state_file)
        self.assertIn("fp_atom", loaded["candidates"])

        # Corrupt the file
        self.state_file.write_text("corrupted json content {", encoding="utf-8")
        recovered = load_scheduler_state(self.state_file)
        # Should gracefully return fresh initial state without crashing
        self.assertEqual(recovered["candidates"], {})

    # ── 11. Refresh Before TTL (Proactive Refresh Audit) ──────────────────────

    def test_refresh_before_ttl_anticipation(self):
        """Verified nodes are scheduled for refresh at refresh_ratio * TTL before expiry."""
        now = 10000.0
        ttl = 7200.0  # 2 hours
        ratio = 0.75  # 75% = 5400s threshold

        # Node A: verified 5500s ago (exceeded 75% threshold, but < TTL)
        node_a = DummyNode("node_a_fp", "src1", "US", True)
        # Node B: verified 3000s ago (under 75% threshold)
        node_b = DummyNode("node_b_fp", "src1", "US", True)
        # Node C: unverified candidate
        node_c = DummyNode("node_c_fp", "src1", "US", None)

        state = init_scheduler_state()
        state["candidates"]["node_a_fp"] = {
            "source_name": "src1",
            "country_code": "US",
            "proxy_ok": True,
            "last_verified_at": now - 5500.0,
            "last_seen_at": now,
        }
        state["candidates"]["node_b_fp"] = {
            "source_name": "src1",
            "country_code": "US",
            "proxy_ok": True,
            "last_verified_at": now - 3000.0,
            "last_seen_at": now,
        }

        # With refresh_ratio=0.75, node_a is overdue for refresh and selected in Tier 1
        scheduled = schedule_candidates(
            nodes=[node_a, node_b, node_c],
            total_limit=1,
            state=state,
            now=now,
            verify_ttl=ttl,
            refresh_ratio=ratio,
        )
        self.assertEqual(len(scheduled), 1)
        self.assertEqual(scheduled[0].fingerprint, "node_a_fp")

    # ── 12. Record Scheduled Flag (No HTTP Target Starvation) ─────────────────

    def test_record_scheduled_false_preserves_state(self):
        """record_scheduled=False does not overwrite last_scheduled_at or advance cursor."""
        now = 5000.0
        node = DummyNode("fp_probe", "src1", "DE", True)

        state = init_scheduler_state()
        state["candidates"]["fp_probe"] = {
            "source_name": "src1",
            "country_code": "DE",
            "last_scheduled_at": 1234.0,
            "proxy_ok": True,
            "last_verified_at": 1000.0,
        }
        initial_cursor = state["exploration_cursor"]

        scheduled = schedule_candidates(
            nodes=[node],
            total_limit=1,
            state=state,
            now=now,
            record_scheduled=False,
        )
        self.assertEqual(len(scheduled), 1)
        # last_scheduled_at must NOT be updated
        self.assertEqual(state["candidates"]["fp_probe"]["last_scheduled_at"], 1234.0)
        # exploration_cursor must NOT be advanced
        self.assertEqual(state["exploration_cursor"], initial_cursor)

    # ── 13. Country Deficit Exploration Budget Floor ──────────────────────────

    def test_country_deficits_capped_preserves_exploration(self):
        """Massive country deficits cannot exhaust 100% of budget when exploration exists."""
        nodes = []
        # 50 DE nodes (DE has deficit)
        for i in range(50):
            nodes.append(DummyNode(f"de_{i}", "src1", "DE"))
        # 50 OTHER nodes (representing unallocated sources for exploration)
        for i in range(50):
            nodes.append(DummyNode(f"other_{i}", "src2", "XX"))

        state = init_scheduler_state()
        # Large deficit for DE (target 100, current 0)
        country_targets = {"DE": 100}
        total_limit = 20

        # With max_deficit_ratio=0.85, at most 17 nodes go to Tier 2 DE deficit,
        # leaving at least 3 for Tier 3 exploration across sources
        scheduled = schedule_candidates(
            nodes=nodes,
            total_limit=total_limit,
            state=state,
            now=1000.0,
            country_targets=country_targets,
            max_deficit_ratio=0.85,
        )
        self.assertEqual(len(scheduled), total_limit)
        other_count = sum(1 for n in scheduled if n.country_code == "XX")
        # Exploration from non-deficit source src2 MUST have taken place
        self.assertGreaterEqual(other_count, 1)

    # ── 14. Malformed Persisted State Types Robustness ────────────────────────

    def test_malformed_persisted_state_types_handled_gracefully(self):
        """State containing malformed types (corrupted schema, wrong types) is sanitized safely."""
        malformed_state = {
            "version": "not-an-int",
            "updated_at": "invalid-timestamp",
            "candidates": {
                "corrupt_1": "not-a-dict",
                "corrupt_2": {
                    "source_name": 12345,  # wrong type
                    "country_code": ["invalid", "list"],
                    "proxy_ok": "not-a-bool",
                    "consecutive_fails": "many",
                    "cooldown_until": "bad-float",
                    "last_scheduled_at": None,
                    "last_verified_at": "corrupt",
                },
            },
            "sources": "not-a-dict",
            "exploration_cursor": "zero",
        }

        # Saving and loading should sanitize
        save_state(self.state_file, malformed_state)
        loaded = load_state(self.state_file)
        self.assertIsInstance(loaded, dict)
        self.assertIsInstance(loaded["candidates"], dict)
        self.assertIsInstance(loaded["sources"], dict)
        self.assertIsInstance(loaded["exploration_cursor"], int)

        # Scheduling with malformed state must not raise exceptions
        node = DummyNode("corrupt_2", "src1", "US")
        scheduled = schedule_candidates(
            nodes=[node],
            total_limit=5,
            state=malformed_state,
            now=1000.0,
        )
        self.assertEqual(len(scheduled), 1)

    # ── 15. Bounded Load & Scaling Benchmark (Synthetic 10788+ Candidates) ────

    def test_synthetic_10788_candidates_bounded_load(self):
        """Synthetic benchmark with 10,788+ candidates measures bounded CPU, memory, and wall-clock.
        NOTE: This benchmark validates local algorithm bounds under synthetic load, not live availability.
        """
        import time
        import tracemalloc

        total_candidates = 11000  # Exceeds the 10,788 candidate threshold
        synthetic_nodes = []
        countries = ["DE", "NL", "US", "FI", "GB", "FR", "CA", "JP", "SG", "PL", "SE", "CH"]
        sources = [f"synthetic_feed_{i}" for i in range(15)]

        for i in range(total_candidates):
            synthetic_nodes.append(
                DummyNode(
                    fingerprint=f"synthetic_candidate_fp_{i:06x}",
                    source_name=sources[i % len(sources)],
                    country_code=countries[i % len(countries)],
                )
            )

        state = init_scheduler_state()

        # Measure memory and CPU
        tracemalloc.start()
        t_cpu_start = time.process_time()
        t_wall_start = time.perf_counter()

        scheduled = schedule_candidates(
            nodes=synthetic_nodes,
            total_limit=500,
            state=state,
            now=time.time(),
            country_targets={"DE": 40, "NL": 40, "US": 40},
            max_deficit_ratio=0.85,
        )

        t_wall_elapsed = time.perf_counter() - t_wall_start
        t_cpu_elapsed = time.process_time() - t_cpu_start
        current_mem, peak_mem = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        # Assertions for correctness and bounds
        self.assertEqual(len(scheduled), 500)
        self.assertLess(t_wall_elapsed, 3.0, f"Wall-clock too slow: {t_wall_elapsed:.3f}s")
        self.assertLess(t_cpu_elapsed, 2.5, f"CPU time too high: {t_cpu_elapsed:.3f}s")
        # Peak memory for scheduling 11,000 synthetic items must be bounded (< 35MB)
        peak_mb = peak_mem / (1024 * 1024)
        self.assertLess(peak_mb, 35.0, f"Peak memory too high: {peak_mb:.2f} MB")

    def test_refresh_cannot_starve_discovery(self):
        """Overdue verified refresh must not starve discovery when new candidates exist."""
        now = 100000.0
        verify_ttl = 7200.0
        state = init_scheduler_state()

        # 15 overdue verified nodes
        overdue_nodes = []
        for i in range(15):
            fp = f"overdue_{i}"
            node = DummyNode(fingerprint=fp, source_name="src_refresh", country_code="DE")
            overdue_nodes.append(node)
            state["candidates"][fp] = {
                "source_name": "src_refresh",
                "country_code": "DE",
                "consecutive_fails": 0,
                "cooldown_until": 0.0,
                "last_seen_at": now - 100.0,
                "last_scheduled_at": now - 6000.0,
                "last_checked_at": now - 6000.0,
                "last_verified_at": now - 6000.0,  # Overdue (6000s > 7200 * 0.8 = 5760s)
                "proxy_ok": True,
            }

        # 10 fresh discovery candidates from another source
        discovery_nodes = [
            DummyNode(fingerprint=f"disc_{i}", source_name="src_discovery", country_code="US")
            for i in range(10)
        ]

        all_nodes = overdue_nodes + discovery_nodes

        # Request total_limit = 10 with default parameters
        import copy
        scheduled_default = schedule_candidates(
            nodes=all_nodes,
            total_limit=10,
            state=copy.deepcopy(state),
            now=now,
            verify_ttl=verify_ttl,
            refresh_ratio=0.8,
        )
        discovery_default = [n for n in scheduled_default if n.source_name == "src_discovery"]
        refresh_default = [n for n in scheduled_default if n.source_name == "src_refresh"]
        self.assertEqual(len(scheduled_default), 10)
        self.assertGreaterEqual(len(discovery_default), 3, "Default refresh ratio starved discovery")
        self.assertLessEqual(len(refresh_default), 7, "Default refresh exceeded capped quota")

        # Request total_limit = 10 with explicit max_refresh_ratio = 0.6
        scheduled_custom = schedule_candidates(
            nodes=all_nodes,
            total_limit=10,
            state=copy.deepcopy(state),
            now=now,
            verify_ttl=verify_ttl,
            refresh_ratio=0.8,
            max_refresh_ratio=0.6,
        )
        discovery_custom = [n for n in scheduled_custom if n.source_name == "src_discovery"]
        refresh_custom = [n for n in scheduled_custom if n.source_name == "src_refresh"]
        self.assertEqual(len(scheduled_custom), 10)
        self.assertGreaterEqual(len(discovery_custom), 4, "Custom max_refresh_ratio starved discovery")
        self.assertLessEqual(len(refresh_custom), 6, "Custom refresh exceeded capped quota")

    def test_stale_or_failed_candidates_do_not_produce_false_country_quorum(self):
        """Stale or failed candidates in state must not satisfy country quorum and starve replenishment."""
        now = 100000.0
        verify_ttl = 7200.0
        state = init_scheduler_state()

        # DE has target of 5.
        # State has 5 DE candidates marked proxy_ok=True, BUT:
        # 3 are stale (last_seen_at ancient > verify_ttl),
        # 2 have consecutive_fails > 0.
        for i in range(3):
            fp = f"stale_de_{i}"
            state["candidates"][fp] = {
                "source_name": "src_old",
                "country_code": "DE",
                "consecutive_fails": 0,
                "cooldown_until": 0.0,
                "last_seen_at": now - (verify_ttl + 1000.0),  # Stale!
                "last_verified_at": now - 1000.0,
                "proxy_ok": True,
            }
        for i in range(2):
            fp = f"failed_de_{i}"
            state["candidates"][fp] = {
                "source_name": "src_old",
                "country_code": "DE",
                "consecutive_fails": 2,  # Failed!
                "cooldown_until": now - 10.0,  # Cooldown elapsed, but has consecutive failures
                "last_seen_at": now - 100.0,
                "last_verified_at": now - 1000.0,
                "proxy_ok": True,
            }

        # Fresh incoming DE candidates available to replenish, and fresh US candidates
        fresh_de_nodes = [
            DummyNode(fingerprint=f"fresh_de_{i}", source_name="src_new", country_code="DE")
            for i in range(5)
        ]
        us_nodes = [
            DummyNode(fingerprint=f"us_{i}", source_name="src_new", country_code="US")
            for i in range(5)
        ]

        # With total_limit=3, US has real deficit (5), while DE has 0 deficit due to
        # false quorum (counting stale/failed nodes as healthy).
        # As a result, US takes all 3 deficit slots and DE gets 0!
        scheduled = schedule_candidates(
            nodes=fresh_de_nodes + us_nodes,
            total_limit=3,
            state=state,
            now=now,
            verify_ttl=verify_ttl,
            country_targets={"DE": 5, "US": 5},
        )

        scheduled_de = [n for n in scheduled if n.country_code == "DE"]
        scheduled_us = [n for n in scheduled if n.country_code == "US"]
        # Since DE has 0 genuinely healthy nodes (all 5 in state are stale or failed),
        # DE must have a real deficit and must receive replenishment slots,
        # instead of being completely starved by false quorum.
        self.assertGreater(len(scheduled_de), 0, "False country quorum starved DE replenishment")

    def test_no_lost_budget_when_no_discovery_or_insufficient_discovery(self):
        """When discovery nodes are absent or insufficient, overdue refresh backfills to full total_limit."""
        now = 100000.0
        verify_ttl = 7200.0
        state = init_scheduler_state()

        overdue_nodes = []
        for i in range(15):
            fp = f"overdue_{i}"
            node = DummyNode(fingerprint=fp, source_name="src_refresh", country_code="DE")
            overdue_nodes.append(node)
            state["candidates"][fp] = {
                "source_name": "src_refresh",
                "country_code": "DE",
                "consecutive_fails": 0,
                "cooldown_until": 0.0,
                "last_seen_at": now - 100.0,
                "last_scheduled_at": now - 6000.0,
                "last_checked_at": now - 6000.0,
                "last_verified_at": now - 6000.0,
                "proxy_ok": True,
            }

        # Case 1: Zero discovery nodes available (only overdue nodes)
        scheduled_case1 = schedule_candidates(
            nodes=overdue_nodes,
            total_limit=10,
            state=state,
            now=now,
            verify_ttl=verify_ttl,
            refresh_ratio=0.8,
            max_refresh_ratio=0.7,
        )
        self.assertEqual(len(scheduled_case1), 10, "Budget was lost when no discovery nodes existed")

        # Case 2: Insufficient discovery nodes (only 1 discovery node when limit is 10)
        # Cap is floor(10 * 0.7) = 7 overdue in Tier 1; 1 discovery node in Tier 3 = 8;
        # remaining 2 slots must be backfilled from overdue nodes so total is 10.
        discovery_nodes = [
            DummyNode(fingerprint="disc_single", source_name="src_discovery", country_code="US")
        ]
        scheduled_case2 = schedule_candidates(
            nodes=overdue_nodes + discovery_nodes,
            total_limit=10,
            state=state,
            now=now,
            verify_ttl=verify_ttl,
            refresh_ratio=0.8,
            max_refresh_ratio=0.7,
        )
        self.assertEqual(len(scheduled_case2), 10, "Budget was lost when discovery nodes were fewer than remaining limit")
        disc_scheduled = [n for n in scheduled_case2 if n.source_name == "src_discovery"]
        self.assertEqual(len(disc_scheduled), 1)


if __name__ == "__main__":
    unittest.main()
