"""End-to-end check that the daemon's verifier and the bot's endpoint agree.

The Go verifier and the Python endpoint were written separately, so this
serves the bot's real do_POST handler over HTTP and drives it exactly as
BotLinkVerifier does: same path, same request shape, same status mapping.
A drift on either side fails here rather than in production.
"""
import datetime
import json
import os
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer

BOT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")
_src = open(BOT_PY, encoding="utf-8").read()


def _slice(start, end):
    i = _src.index(start)
    j = _src.index(end, i)
    return _src[i:j]


# Reuse the real helpers and the real do_POST body.
_helpers = _slice("LINK_CODE_ALPHABET =", "def get_user(telegram_id):")
_handler_src = _slice("class StatsRequestHandler(BaseHTTPRequestHandler):",
                      "    def do_GET(self):")

_ns = {
    "sqlite3": sqlite3,
    "datetime": datetime,
    "secrets": __import__("secrets"),
    "logging": __import__("logging"),
    "json": json,
    "BaseHTTPRequestHandler": BaseHTTPRequestHandler,
}
exec(compile(_helpers, BOT_PY, "exec"), _ns)
exec(compile(_handler_src + "        pass\n", BOT_PY, "exec"), _ns)

issue_link_code = _ns["issue_link_code"]
Handler = _ns["StatsRequestHandler"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS link_codes (
    code TEXT PRIMARY KEY,
    telegram_id INTEGER NOT NULL,
    username TEXT,
    session_token TEXT,
    issued_at TEXT,
    expires_at TEXT,
    used_at TEXT,
    attempts INTEGER DEFAULT 0
)
"""


class QuietHandler(Handler):
    def log_message(self, *args):
        pass


class BotEndpointContractTest(unittest.TestCase):
    """Mirrors internal/api/link_verifier.go against the live bot endpoint."""

    @classmethod
    def setUpClass(cls):
        # Threading server: the race test must genuinely contend at the DB layer.
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def setUp(self):
        fd, self.db = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        conn = sqlite3.connect(self.db)
        conn.execute(SCHEMA)
        conn.commit()
        conn.close()
        _ns["DB_PATH"] = self.db

    def tearDown(self):
        try:
            os.unlink(self.db)
        except OSError:
            pass

    def _post(self, payload, path="/api/link/redeem", raw=None):
        """Issue the same request BotLinkVerifier.Verify sends."""
        url = f"http://127.0.0.1:{self.port}{path}"
        body = raw if raw is not None else json.dumps(payload).encode()
        req = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            raw_body = e.read().decode()
            try:
                return e.code, json.loads(raw_body)
            except ValueError:
                return e.code, {}
        except (ConnectionError, OSError) as e:
            # The handler refuses an oversized body without draining it, so the
            # peer may see a reset before the 400 arrives. Deliberate: draining
            # attacker-controlled bytes is what the cap exists to avoid.
            return "aborted", {"error": str(e)}

    def test_valid_code_returns_the_fields_the_daemon_reads(self):
        code, _ = issue_link_code(4242, "nikita", "tok-xyz")
        status, body = self._post({"code": code})
        self.assertEqual(status, 200)
        # BotLinkVerifier unmarshals exactly these JSON keys.
        self.assertEqual(body["telegram_id"], 4242)
        self.assertEqual(body["username"], "nikita")
        self.assertEqual(body["session_token"], "tok-xyz")

    def test_unknown_code_is_404(self):
        status, _ = self._post({"code": "ZZZZZZZZ"})
        self.assertEqual(status, 404)

    def test_replayed_code_is_409(self):
        code, _ = issue_link_code(1, "u")
        self.assertEqual(self._post({"code": code})[0], 200)
        self.assertEqual(self._post({"code": code})[0], 409)

    def test_expired_code_is_410(self):
        code, _ = issue_link_code(2, "u")
        past = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE link_codes SET expires_at = ? WHERE code = ?",
                     (past.isoformat(), code))
        conn.commit()
        conn.close()
        self.assertEqual(self._post({"code": code})[0], 410)

    def test_burned_code_is_429(self):
        code, _ = issue_link_code(3, "u")
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE link_codes SET attempts = 5 WHERE code = ?", (code,))
        conn.commit()
        conn.close()
        self.assertEqual(self._post({"code": code})[0], 429)

    def test_missing_code_is_400(self):
        self.assertEqual(self._post({})[0], 400)

    def test_malformed_json_is_400(self):
        self.assertEqual(self._post(None, raw=b"not json")[0], 400)

    def test_empty_body_is_400(self):
        self.assertEqual(self._post(None, raw=b"")[0], 400)

    def test_oversized_body_is_rejected(self):
        # The handler caps the read so a caller cannot exhaust VPS memory.
        # Either a 400 or a reset counts: both mean the body was not buffered.
        self.assertIn(self._post(None, raw=b"x" * 8192)[0], (400, "aborted"))

    def test_wrong_path_is_404(self):
        code, _ = issue_link_code(9, "u")
        self.assertEqual(self._post({"code": code}, path="/api/link/other")[0], 404)

    def test_lowercase_code_is_accepted(self):
        code, _ = issue_link_code(10, "u")
        status, body = self._post({"code": code.lower()})
        self.assertEqual(status, 200)
        self.assertEqual(body["telegram_id"], 10)

    def test_only_one_of_two_racing_clients_wins(self):
        code, _ = issue_link_code(11, "u")
        results = []
        lock = threading.Lock()

        def attempt():
            status, _ = self._post({"code": code})
            with lock:
                results.append(status)

        threads = [threading.Thread(target=attempt) for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(results.count(200), 1, f"statuses: {results}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
