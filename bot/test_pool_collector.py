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
            jitter_ms=5, packet_loss=0,
        )
        defaults.update(values)
        return collector.Node(**defaults)

    def test_failed_proxy_scores_zero(self):
        self.assertEqual(self.node(proxy_ok=False).quality_score, 0)

    def test_zero_loss_is_not_treated_as_missing(self):
        perfect = self.node(packet_loss=0).quality_score
        lossy = self.node(packet_loss=1).quality_score
        self.assertGreater(perfect, lossy)

    def test_better_node_scores_higher(self):
        good = self.node(latency_ms=40, jitter_ms=2, packet_loss=0, speed_mbps=50)
        poor = self.node(latency_ms=700, jitter_ms=180, packet_loss=0.67, speed_mbps=1)
        self.assertGreater(good.quality_score, poor.quality_score)

    def test_score_is_bounded(self):
        score = self.node(latency_ms=1, jitter_ms=0, packet_loss=0, speed_mbps=1000).quality_score
        self.assertGreaterEqual(score, 0)
        self.assertLessEqual(score, 100)


if __name__ == "__main__":
    unittest.main()
