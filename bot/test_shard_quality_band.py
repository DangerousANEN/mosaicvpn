"""Shard quality-band tests for bot._shard_group_nodes.

Contract:
- Candidates are pre-ranked by measured quality (speed desc, latency asc)
  BEFORE sharding, so shard anchors are always the pool's best nodes.
- Per-user diversity (LCG) is preserved, but extras are drawn only from the
  top half of the ranked remainder (quality band), never from the tail.
- Deterministic for a given (opaque_id, group_id).
- Short lists (<= target) pass through unchanged (same set).
- Nodes without quality data rank below any measured node.

bot.py cannot be imported directly (TeleBot decorators fire at import time);
we use the exec-extract pattern established in test_ux_redesign.py.
"""
import os
import sys
import unittest

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")
_SRC = open(BOT_PY, encoding="utf-8").read()

# Extract the shard helpers (they are contiguous in bot.py).
_START = "def _lcg_seed("
_END = "class ThreadedHTTPServer("
_i = _SRC.index(_START)
_j = _SRC.index(_END, _i)
_NS = {}
import datetime as _datetime
import hashlib as _hashlib
_NS["datetime"] = _datetime
_NS["hashlib"] = _hashlib
exec(_SRC[_i:_j], _NS)

_shard_group_nodes = _NS["_shard_group_nodes"]


def _cand(fp, speed=None, latency=None):
    return {"fingerprint": fp, "speed_mbps": speed, "latency_ms": latency}


def make_candidates():
    # 20 candidates: high-quality head, low-quality tail.
    cands = []
    for i in range(20):
        # speed decays, latency grows -> index 0 best, index 19 worst
        cands.append(_cand(f"fp-{i:02d}", speed=100.0 - i * 4.5, latency=20.0 + i * 15.0))
    return cands


class TestShardQualityBand(unittest.TestCase):
    def test_shard_size_respected(self):
        cands = make_candidates()
        shard = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        self.assertEqual(len(shard), 6)

    def test_anchors_are_top_quality(self):
        cands = make_candidates()
        shard = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        # Anchors must be the two globally best nodes (fp-00, fp-01).
        fps = [c["fingerprint"] for c in shard]
        self.assertEqual(fps[0], "fp-00")
        self.assertEqual(fps[1], "fp-01")

    def test_extras_within_quality_band(self):
        # Extras must come from the top half of the remaining 18 ranked nodes:
        # indices 2..10 (fp-02..fp-10), never the tail (fp-11..fp-19).
        cands = make_candidates()
        shard = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        extras = shard[2:]
        for node in extras:
            idx = int(node["fingerprint"].split("-")[1])
            self.assertLessEqual(idx, 10,
                                 f"extra {node['fingerprint']} is from the tail; quality band violated")

    def test_deterministic_per_user(self):
        cands = make_candidates()
        s1 = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        s2 = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        self.assertEqual([c["fingerprint"] for c in s1], [c["fingerprint"] for c in s2])

    def test_user_diversity_preserved(self):
        # Different users still get different extra sets (load distribution).
        cands = make_candidates()
        sets = []
        for u in ("user-a", "user-b", "user-c", "user-d"):
            shard = _shard_group_nodes(u, "min_latency", cands, target=6)
            sets.append(frozenset(c["fingerprint"] for c in shard[2:]))
        self.assertGreater(len(set(sets)), 1, "LCG per-user diversity lost")

    def test_short_list_passthrough(self):
        cands = make_candidates()[:5]
        shard = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        self.assertEqual(len(shard), 5)
        self.assertEqual(frozenset(c["fingerprint"] for c in shard),
                         frozenset(c["fingerprint"] for c in cands))

    def test_empty(self):
        self.assertEqual(_shard_group_nodes("u", "g", [], target=6), [])

    def test_missing_quality_fields_are_worst(self):
        # Nodes without speed/latency data rank below any measured node.
        cands = [
            _cand("fp-no-data"),
            _cand("fp-measured", speed=1.0, latency=500.0),
        ] + [_cand(f"fp-tail-{i}", speed=0.1, latency=2000.0) for i in range(10)]
        shard = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        # Anchors: best measured node first; unmeasured node is not an anchor.
        self.assertEqual(shard[0]["fingerprint"], "fp-measured")
        self.assertNotEqual(shard[1]["fingerprint"], "fp-no-data")

    def test_exact_target_no_shuffle_needed(self):
        cands = make_candidates()[:6]
        shard = _shard_group_nodes("user-a", "min_latency", cands, target=6)
        self.assertEqual(len(shard), 6)


if __name__ == "__main__":
    unittest.main()
