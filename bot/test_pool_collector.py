import importlib.util
import pathlib
import sys
import types
import unittest

psycopg2 = types.ModuleType("psycopg2")
extras = types.ModuleType("psycopg2.extras")
extras.Json = lambda value: value
psycopg2.extras = extras
sys.modules.setdefault("psycopg2", psycopg2)
sys.modules.setdefault("psycopg2.extras", extras)

MODULE_PATH = pathlib.Path(__file__).with_name("mosaic_pool_collector.py")
spec = importlib.util.spec_from_file_location("mosaic_pool_collector", MODULE_PATH)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class QualityScoreTest(unittest.TestCase):
    def node(self, **values):
        defaults = dict(
            source_name="test", source_url="https://example.test", country_code="DE",
            protocol="vless", address="127.0.0.1", port=443,
            config={"type": "vless"}, fingerprint="a" * 64,
            proxy_ok=True, latency_ms=100, speed_mbps=20,
            jitter_ms=5, loss_pct=0, success_rate=0.85
        )
        defaults.update(values)
        return collector.Node(**defaults)

    def test_failed_proxy_scores_zero(self):
        n = self.node(proxy_ok=False)
        self.assertEqual(collector.score_node(n), 0.0)

    def test_zero_loss_is_not_treated_as_missing(self):
        n_perfect = self.node(loss_pct=0)
        n_lossy = self.node(loss_pct=100)
        self.assertGreater(collector.score_node(n_perfect), collector.score_node(n_lossy))

    def test_better_node_scores_higher(self):
        good = self.node(latency_ms=40, jitter_ms=2, loss_pct=0, speed_mbps=50)
        poor = self.node(latency_ms=700, jitter_ms=180, loss_pct=50, speed_mbps=1)
        self.assertGreater(collector.score_node(good), collector.score_node(poor))

    def test_score_is_bounded(self):
        score = collector.score_node(self.node(latency_ms=1, jitter_ms=0, loss_pct=0, speed_mbps=1000))
        self.assertGreaterEqual(score, 0.0)
        self.assertLessEqual(score, 1.0)


if __name__ == "__main__":
    unittest.main()
