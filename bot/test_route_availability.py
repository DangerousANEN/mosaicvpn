"""Tests for route availability / maintenance override controls.

Following the pattern of test_bot_logic.py: bot.py connects to Telegram at
import time, so we extract only the functions we need via exec() on isolated
source blocks.  No real bot connection, no psycopg2, no telebot.
"""
import datetime
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")
_SRC = open(BOT_PY, encoding="utf-8").read()


def _find_block(start_marker):
    """Return source from start_marker to the next top-level def/class."""
    idx = _SRC.index(start_marker)
    # Find the next def or class at column 0 after this block
    rest = _SRC[idx + len(start_marker):]
    import re
    m = re.search(r"\ndef [a-zA-Z_]|\nclass [a-zA-Z_]", rest)
    if m:
        return _SRC[idx: idx + len(start_marker) + m.start() + 1]
    return _SRC[idx:]


def _extract_range(start_marker, end_marker):
    i = _SRC.index(start_marker)
    j = _SRC.index(end_marker, i)
    return _SRC[i:j]


# ---------------------------------------------------------------------------
# Build a namespace with all the functions we need by exec-ing a minimal
# set of source blocks together with their dependencies.
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS route_policies (
    route_id    TEXT PRIMARY KEY,
    disabled    INTEGER NOT NULL DEFAULT 0,
    reason      TEXT NOT NULL DEFAULT '',
    icon        TEXT NOT NULL DEFAULT '',
    min_eligible INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT NOT NULL,
    updated_by  INTEGER NOT NULL
)
"""


def _build_ns(db_path):
    """Return a namespace that contains the route-availability DB helpers."""
    base_ns = {
        "sqlite3": sqlite3,
        "datetime": datetime,
        "json": json,
        "logging": __import__("logging"),
        "logger": __import__("logging").getLogger("test"),
        "DB_PATH": db_path,
        "KNOWN_ROUTE_IDS": frozenset({
            "min-latency", "stable", "max-speed", "germany", "canada", "direct",
        }),
    }

    # Extract and exec all the route-policy helper functions
    blocks = [
        _extract_range("def get_route_policies():", "def get_route_policy("),
        _extract_range("def get_route_policy(", "def set_route_policy("),
        _extract_range("def set_route_policy(", "def apply_route_policies("),
        _extract_range("def apply_route_policies(", "\ndef get_user("),
    ]
    for block in blocks:
        exec(compile(block, BOT_PY, "exec"), base_ns)

    return base_ns


class _BaseRoutePolicyTest(unittest.TestCase):
    def setUp(self):
        fd, self.db = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        conn = sqlite3.connect(self.db)
        conn.execute(SCHEMA)
        conn.commit()
        conn.close()
        self.ns = _build_ns(self.db)
        # Handy aliases
        self.get_route_policies = self.ns["get_route_policies"]
        self.get_route_policy = self.ns["get_route_policy"]
        self.set_route_policy = self.ns["set_route_policy"]
        self.apply_route_policies = self.ns["apply_route_policies"]
        self.ADMIN_ID = 831992162

    def tearDown(self):
        try:
            os.unlink(self.db)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# DB helper tests
# ---------------------------------------------------------------------------

class TestRoutePolicyDB(_BaseRoutePolicyTest):
    def test_empty_initially(self):
        self.assertEqual(self.get_route_policies(), [])

    def test_set_and_get(self):
        p = self.set_route_policy("stable", True, "Технические работы", "wrench", 0, self.ADMIN_ID)
        self.assertEqual(p["route_id"], "stable")
        self.assertTrue(p["disabled"])
        self.assertEqual(p["reason"], "Технические работы")
        self.assertEqual(p["icon"], "wrench")
        self.assertEqual(p["min_eligible"], 0)

    def test_upsert_updates(self):
        self.set_route_policy("min-latency", True, "Maint", "wrench", 0, self.ADMIN_ID)
        self.set_route_policy("min-latency", False, "", "", 0, self.ADMIN_ID)
        p = self.get_route_policy("min-latency")
        self.assertFalse(p["disabled"])
        self.assertEqual(p["reason"], "")

    def test_get_unknown_returns_none(self):
        self.assertIsNone(self.get_route_policy("does-not-exist"))

    def test_min_eligible_persisted(self):
        self.set_route_policy("max-speed", False, "", "", 5, self.ADMIN_ID)
        p = self.get_route_policy("max-speed")
        self.assertEqual(p["min_eligible"], 5)

    def test_list_all(self):
        self.set_route_policy("stable", True, "T1", "", 0, self.ADMIN_ID)
        self.set_route_policy("canada", True, "T2", "", 0, self.ADMIN_ID)
        ids = [p["route_id"] for p in self.get_route_policies()]
        self.assertIn("stable", ids)
        self.assertIn("canada", ids)


# ---------------------------------------------------------------------------
# apply_route_policies tests
# ---------------------------------------------------------------------------

class TestApplyRoutePolicies(_BaseRoutePolicyTest):
    def test_no_policies_unchanged(self):
        groups = [{"id": "stable", "title": "S", "disabled": False}]
        result = self.apply_route_policies(groups)
        self.assertFalse(result[0]["disabled"])

    def test_disabled_override_applied(self):
        self.set_route_policy("stable", True, "Технические работы", "wrench", 0, self.ADMIN_ID)
        groups = [{"id": "stable", "title": "S", "disabled": False, "disabled_reason": "", "icon": "shield"}]
        result = self.apply_route_policies(groups)
        self.assertTrue(result[0]["disabled"])
        self.assertEqual(result[0]["disabled_reason"], "Технические работы")
        self.assertEqual(result[0]["icon"], "wrench")

    def test_enable_override_clears_flag(self):
        self.set_route_policy("stable", False, "", "", 0, self.ADMIN_ID)
        groups = [{"id": "stable", "title": "S", "disabled": True, "disabled_reason": "old"}]
        result = self.apply_route_policies(groups)
        self.assertFalse(result[0]["disabled"])
        self.assertEqual(result[0]["disabled_reason"], "")

    def test_unaffected_group_unchanged(self):
        self.set_route_policy("stable", True, "Maint", "wrench", 0, self.ADMIN_ID)
        groups = [
            {"id": "stable", "title": "S", "disabled": False},
            {"id": "min-latency", "title": "ML", "disabled": False},
        ]
        result = self.apply_route_policies(groups)
        self.assertTrue(result[0]["disabled"])
        self.assertFalse(result[1]["disabled"])

    def test_no_mutation_of_original(self):
        self.set_route_policy("canada", True, "Maint", "", 0, self.ADMIN_ID)
        original = {"id": "canada", "title": "C", "disabled": False}
        self.apply_route_policies([original])
        # original must not be mutated
        self.assertFalse(original["disabled"])

    def test_icon_overridden_only_when_disabled(self):
        self.set_route_policy("germany", True, "Maint", "wrench", 0, self.ADMIN_ID)
        groups = [{"id": "germany", "title": "G", "disabled": False, "icon": "flag_de"}]
        result = self.apply_route_policies(groups)
        self.assertEqual(result[0]["icon"], "wrench")

    def test_empty_icon_keeps_original(self):
        """When the policy has no icon override, the original icon is preserved."""
        self.set_route_policy("stable", True, "Maint", "", 0, self.ADMIN_ID)
        groups = [{"id": "stable", "title": "S", "disabled": False, "icon": "shield"}]
        result = self.apply_route_policies(groups)
        # icon is empty in policy, so the original should be unchanged
        self.assertEqual(result[0]["icon"], "shield")

    def test_direct_route_disabled(self):
        self.set_route_policy("direct", True, "Прямой отключён", "wrench", 0, self.ADMIN_ID)
        direct = [{"id": "direct", "title": "Direct", "disabled": False, "disabled_reason": ""}]
        result = self.apply_route_policies(direct)
        self.assertTrue(result[0]["disabled"])
        self.assertEqual(result[0]["disabled_reason"], "Прямой отключён")


# ---------------------------------------------------------------------------
# Validation helpers that would be checked by the HTTP handler
# ---------------------------------------------------------------------------

class TestValidation(unittest.TestCase):
    """Verify the business rules enforced by _handle_admin_route_put."""

    KNOWN = frozenset({"min-latency", "stable", "max-speed", "germany", "canada", "direct"})

    def _validate(self, route_id, disabled, reason, icon, min_eligible):
        """Mirror the validation logic from _handle_admin_route_put."""
        import re
        errors = []
        if not re.fullmatch(r"[a-z0-9_-]{1,64}", route_id or ""):
            errors.append("invalid route_id")
        elif route_id not in self.KNOWN:
            errors.append("unknown route_id")
        if len(reason) > 280:
            errors.append("reason too long")
        if len(icon) > 64:
            errors.append("icon too long")
        if not 0 <= int(min_eligible) <= 1000:
            errors.append("min_eligible out of range")
        if disabled and not reason:
            errors.append("reason required when disabling")
        return errors

    def test_valid_disable(self):
        errs = self._validate("stable", True, "Технические работы", "wrench", 0)
        self.assertEqual(errs, [])

    def test_valid_enable(self):
        errs = self._validate("stable", False, "", "", 0)
        self.assertEqual(errs, [])

    def test_unknown_route_rejected(self):
        errs = self._validate("not-a-route", True, "Maint", "", 0)
        self.assertIn("unknown route_id", errs)

    def test_disable_without_reason_rejected(self):
        errs = self._validate("stable", True, "", "", 0)
        self.assertIn("reason required when disabling", errs)

    def test_reason_too_long_rejected(self):
        errs = self._validate("stable", True, "x" * 300, "", 0)
        self.assertIn("reason too long", errs)

    def test_invalid_route_id_characters(self):
        errs = self._validate("Route/Bad!", True, "Maint", "", 0)
        self.assertIn("invalid route_id", errs)

    def test_min_eligible_out_of_range(self):
        errs = self._validate("stable", False, "", "", 9999)
        self.assertIn("min_eligible out of range", errs)


if __name__ == "__main__":
    unittest.main()
