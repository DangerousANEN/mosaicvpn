"""Safe Telegram website login challenge backend.

Implements server-backed browser Telegram sign-in challenge:
- Distinct public request_id (token_urlsafe(18)) and private poll_secret (token_urlsafe(32)).
- Raw secret is NEVER stored in database; only salted SHA-256 hash is kept.
- Constant-time secret comparison with brute-force lockout after max attempts.
- Strict input validation rejecting malformed request IDs, secrets, and telegram IDs.
- Atomic bind/approve: requires existing live request, binds once, cannot change account.
- Explicit Telegram confirmation required (starts pending, no auto-approval).
- Atomic single-consumer consumption: guarded with single-use claim token and
  optional transactional session exchange callback.
- Public challenge metadata lookup (get_challenge) for Telegram confirmation UI.
- Real SQLite multi-threaded safety with WAL and busy timeout handling.
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import re
import secrets
import sqlite3
from typing import Any, Callable, Dict, Optional, Tuple, Union

# Regex patterns for input validation: URL-safe base64 tokens
_RE_REQUEST_ID = re.compile(r"^[A-Za-z0-9_-]{16,64}$")
_RE_POLL_SECRET = re.compile(r"^[A-Za-z0-9_-]{16,128}$")

DEFAULT_CHALLENGE_TTL_SECONDS = 600
DEFAULT_MAX_ATTEMPTS = 5


class BrowserLoginResult:
    """Status constants for login challenge lifecycle."""
    PENDING = "pending"
    APPROVED = "approved"
    CONSUMED = "consumed"
    USED = "used"
    EXPIRED = "expired"
    LOCKED = "locked"
    INVALID_SECRET = "invalid_secret"
    ALREADY_BOUND = "already_bound"
    NOT_FOUND = "not_found"
    MALFORMED_INPUT = "malformed_input"
    EXCHANGE_FAILED = "exchange_failed"


class BrowserLoginStore:
    """Server-backed SQLite store for Telegram website login challenges."""

    def __init__(
        self,
        db_path: str,
        default_ttl_seconds: int = DEFAULT_CHALLENGE_TTL_SECONDS,
        max_attempts: int = DEFAULT_MAX_ATTEMPTS,
        auto_init: bool = True,
    ) -> None:
        self.db_path = db_path
        self.default_ttl_seconds = int(default_ttl_seconds)
        self.max_attempts = int(max_attempts)
        if auto_init:
            self.init_schema()

    def _get_connection(self) -> sqlite3.Connection:
        """Create a configured SQLite connection."""
        conn = sqlite3.connect(self.db_path, timeout=15.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 15000")
        try:
            conn.execute("PRAGMA journal_mode = WAL")
        except sqlite3.OperationalError:
            pass
        return conn

    def init_schema(self) -> None:
        """Idempotently initialize tables and indexes."""
        with self._get_connection() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS browser_login_challenges (
                    request_id TEXT PRIMARY KEY,
                    secret_hash TEXT NOT NULL,
                    salt TEXT NOT NULL,
                    telegram_id INTEGER,
                    telegram_username TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    issued_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    approved_at TEXT,
                    used_at TEXT,
                    claim_token TEXT,
                    attempts INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_blc_status_expires
                    ON browser_login_challenges(status, expires_at);
                """
            )

    @staticmethod
    def _hash_secret(secret: str, salt: str) -> str:
        """Hash secret with salt using SHA-256."""
        payload = f"{salt}:{secret}".encode("utf-8")
        return hashlib.sha256(payload).hexdigest()

    @staticmethod
    def _parse_iso(iso_str: Optional[str]) -> Optional[datetime.datetime]:
        """Parse ISO timestamp safely with UTC fallback."""
        if not iso_str:
            return None
        try:
            dt = datetime.datetime.fromisoformat(iso_str)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return dt
        except (ValueError, TypeError):
            return None

    def create(self, ttl_seconds: Optional[int] = None) -> Dict[str, Any]:
        """Mint a new login challenge.

        Returns:
            Dict containing request_id, poll_secret, expires_in, and expires_at.
            Raw poll_secret is never persisted.
        """
        ttl = int(ttl_seconds) if ttl_seconds is not None else self.default_ttl_seconds
        request_id = secrets.token_urlsafe(18)
        poll_secret = secrets.token_urlsafe(32)
        salt = secrets.token_hex(16)
        secret_hash = self._hash_secret(poll_secret, salt)

        now = datetime.datetime.now(datetime.timezone.utc)
        expires_at = now + datetime.timedelta(seconds=ttl)
        now_iso = now.isoformat()
        expires_iso = expires_at.isoformat()

        with self._get_connection() as conn:
            conn.execute(
                """
                INSERT INTO browser_login_challenges (
                    request_id, secret_hash, salt, status, issued_at, expires_at, attempts
                ) VALUES (?, ?, ?, 'pending', ?, ?, 0)
                """,
                (request_id, secret_hash, salt, now_iso, expires_iso),
            )

        return {
            "request_id": request_id,
            "poll_secret": poll_secret,
            "expires_in": ttl,
            "expires_at": expires_iso,
        }

    def get_challenge(self, request_id: Any) -> Optional[Dict[str, Any]]:
        """Retrieve challenge metadata without exposing sensitive secrets or hashes.

        Useful for Telegram bot dialog confirmation flow.
        """
        if not isinstance(request_id, str) or not _RE_REQUEST_ID.match(request_id):
            return None

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT request_id, telegram_id, telegram_username, status,
                       issued_at, expires_at, approved_at, used_at, attempts
                FROM browser_login_challenges
                WHERE request_id = ?
                """,
                (request_id,),
            )
            row = cursor.fetchone()
            if not row:
                return None

            now = datetime.datetime.now(datetime.timezone.utc)
            exp = self._parse_iso(row["expires_at"])
            status = row["status"]
            if exp and exp <= now and status == BrowserLoginResult.PENDING:
                status = BrowserLoginResult.EXPIRED

            return {
                "request_id": row["request_id"],
                "telegram_id": row["telegram_id"],
                "telegram_username": row["telegram_username"] or "",
                "status": status,
                "issued_at": row["issued_at"],
                "expires_at": row["expires_at"],
                "approved_at": row["approved_at"],
                "used_at": row["used_at"],
                "is_live": (status == BrowserLoginResult.PENDING and exp is not None and exp > now),
            }

    def _verify_secret_and_get_row(
        self, conn: sqlite3.Connection, request_id: Any, poll_secret: Any
    ) -> Tuple[Optional[sqlite3.Row], Dict[str, Any]]:
        """Validate input format, check lockout, and verify secret hash.

        Returns (row, error_dict). Exactly one is non-None.
        """
        if not isinstance(request_id, str) or not _RE_REQUEST_ID.match(request_id):
            return None, {"status": BrowserLoginResult.MALFORMED_INPUT, "error": "Invalid request_id format"}
        if not isinstance(poll_secret, str) or not _RE_POLL_SECRET.match(poll_secret):
            return None, {"status": BrowserLoginResult.MALFORMED_INPUT, "error": "Invalid poll_secret format"}

        cursor = conn.cursor()
        cursor.execute("SELECT * FROM browser_login_challenges WHERE request_id = ?", (request_id,))
        row = cursor.fetchone()
        if not row:
            return None, {"status": BrowserLoginResult.NOT_FOUND, "error": "Challenge not found"}

        # Check if already locked out
        if row["status"] == BrowserLoginResult.LOCKED or row["attempts"] >= self.max_attempts:
            return None, {"status": BrowserLoginResult.LOCKED, "error": "Too many failed attempts"}

        # Constant-time hash verification
        computed_hash = self._hash_secret(poll_secret, row["salt"])
        if not hmac.compare_digest(row["secret_hash"], computed_hash):
            new_attempts = row["attempts"] + 1
            new_status = BrowserLoginResult.LOCKED if new_attempts >= self.max_attempts else row["status"]
            cursor.execute(
                "UPDATE browser_login_challenges SET attempts = ?, status = ? WHERE request_id = ?",
                (new_attempts, new_status, request_id),
            )
            if new_attempts >= self.max_attempts:
                return None, {
                    "status": BrowserLoginResult.LOCKED,
                    "error": "Too many failed attempts",
                    "attempts_left": 0,
                }
            return None, {
                "status": BrowserLoginResult.INVALID_SECRET,
                "error": "Invalid secret",
                "attempts_left": self.max_attempts - new_attempts,
            }

        return row, {}

    def poll(self, request_id: Any, poll_secret: Any) -> Dict[str, Any]:
        """Poll the state of a login challenge."""
        with self._get_connection() as conn:
            row, err = self._verify_secret_and_get_row(conn, request_id, poll_secret)
            if err:
                return err

            now = datetime.datetime.now(datetime.timezone.utc)
            expires_at = self._parse_iso(row["expires_at"])
            if expires_at and expires_at <= now:
                if row["status"] == BrowserLoginResult.PENDING:
                    conn.execute(
                        "UPDATE browser_login_challenges SET status = 'expired' WHERE request_id = ?",
                        (row["request_id"],),
                    )
                return {"status": BrowserLoginResult.EXPIRED, "error": "Challenge expired"}

            if row["used_at"] is not None or row["status"] == BrowserLoginResult.USED:
                return {"status": BrowserLoginResult.USED, "error": "Challenge already consumed"}

            if row["status"] == BrowserLoginResult.APPROVED:
                return {
                    "status": BrowserLoginResult.APPROVED,
                    "telegram_id": row["telegram_id"],
                    "telegram_username": row["telegram_username"] or "",
                }

            if row["status"] == BrowserLoginResult.PENDING:
                return {"status": BrowserLoginResult.PENDING}

            return {"status": row["status"]}

    def approve(
        self, request_id: Any, telegram_id: Any, telegram_username: Optional[str] = None
    ) -> Dict[str, Any]:
        """Approve and bind a Telegram identity to a live request.

        Atomic: requires existing live request, binds once, cannot change account.
        """
        # Malformed input check
        if not isinstance(request_id, str) or not _RE_REQUEST_ID.match(request_id):
            return {
                "success": False,
                "status": BrowserLoginResult.MALFORMED_INPUT,
                "error": "Invalid request_id format",
            }

        # Normalize telegram_id: accept positive int or digits string
        tid: Optional[int] = None
        if isinstance(telegram_id, int) and not isinstance(telegram_id, bool) and telegram_id > 0:
            tid = telegram_id
        elif isinstance(telegram_id, str) and telegram_id.isdigit() and int(telegram_id) > 0:
            tid = int(telegram_id)

        if tid is None:
            return {
                "success": False,
                "status": BrowserLoginResult.MALFORMED_INPUT,
                "error": "Invalid telegram_id (must be a positive integer)",
            }

        clean_username = str(telegram_username)[:64] if telegram_username else ""
        now = datetime.datetime.now(datetime.timezone.utc)
        now_iso = now.isoformat()

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT status, telegram_id, expires_at, used_at FROM browser_login_challenges WHERE request_id = ?",
                (request_id,),
            )
            row = cursor.fetchone()
            if not row:
                return {
                    "success": False,
                    "status": BrowserLoginResult.NOT_FOUND,
                    "error": "Challenge not found",
                }

            # Check expiration
            exp = self._parse_iso(row["expires_at"])
            if exp and exp <= now:
                return {
                    "success": False,
                    "status": BrowserLoginResult.EXPIRED,
                    "error": "Challenge expired",
                }

            if row["used_at"] is not None or row["status"] == BrowserLoginResult.USED:
                return {
                    "success": False,
                    "status": BrowserLoginResult.USED,
                    "error": "Challenge already consumed",
                }

            if row["status"] == BrowserLoginResult.LOCKED:
                return {
                    "success": False,
                    "status": BrowserLoginResult.LOCKED,
                    "error": "Challenge is locked",
                }

            # If already bound or approved, refuse rebinding (binds once, cannot change account)
            if row["status"] == BrowserLoginResult.APPROVED or row["telegram_id"] is not None:
                return {
                    "success": False,
                    "status": BrowserLoginResult.ALREADY_BOUND,
                    "error": "Challenge is already bound to an account",
                }

            # Atomic conditional update
            cursor.execute(
                """
                UPDATE browser_login_challenges
                SET status = 'approved',
                    telegram_id = ?,
                    telegram_username = ?,
                    approved_at = ?
                WHERE request_id = ?
                  AND status = 'pending'
                  AND used_at IS NULL
                  AND expires_at > ?
                """,
                (tid, clean_username, now_iso, request_id, now_iso),
            )

            if cursor.rowcount == 1:
                return {
                    "success": True,
                    "status": BrowserLoginResult.APPROVED,
                    "telegram_id": tid,
                }

            # Race condition occurred: inspect state
            cursor.execute("SELECT status, telegram_id FROM browser_login_challenges WHERE request_id = ?", (request_id,))
            race_row = cursor.fetchone()
            if race_row and (race_row["status"] == BrowserLoginResult.APPROVED or race_row["telegram_id"] is not None):
                return {
                    "success": False,
                    "status": BrowserLoginResult.ALREADY_BOUND,
                    "error": "Challenge was concurrently bound",
                }

            return {
                "success": False,
                "status": "failed",
                "error": "Failed to approve challenge",
            }

    # Alias bind to approve
    bind = approve

    def consume(
        self,
        request_id: Any,
        poll_secret: Any,
        exchange_callback: Optional[Callable[[Dict[str, Any]], Any]] = None,
    ) -> Dict[str, Any]:
        """Atomically consume an approved challenge.

        Ensures single consumer via claim token guard. If exchange_callback
        is provided, runs it inside the transaction; on failure/exception,
        rolls back the consumption.
        """
        conn = self._get_connection()
        try:
            # Begin explicit transaction
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.cursor()

            row, err = self._verify_secret_and_get_row(conn, request_id, poll_secret)
            if err:
                conn.commit()
                return err

            now = datetime.datetime.now(datetime.timezone.utc)
            expires_at = self._parse_iso(row["expires_at"])
            if expires_at and expires_at <= now:
                conn.commit()
                return {"status": BrowserLoginResult.EXPIRED, "error": "Challenge expired"}

            if row["used_at"] is not None or row["status"] == BrowserLoginResult.USED:
                conn.commit()
                return {"status": BrowserLoginResult.USED, "error": "Challenge already consumed"}

            if row["status"] == BrowserLoginResult.PENDING:
                conn.commit()
                return {"status": BrowserLoginResult.PENDING, "error": "Challenge not yet approved"}

            if row["status"] != BrowserLoginResult.APPROVED:
                conn.commit()
                return {"status": row["status"], "error": f"Unexpected challenge status: {row['status']}"}

            # Status is approved: attempt atomic transition to 'used' with unique claim token
            claim_token = secrets.token_urlsafe(32)
            now_iso = now.isoformat()

            cursor.execute(
                """
                UPDATE browser_login_challenges
                SET status = 'used',
                    used_at = ?,
                    claim_token = ?
                WHERE request_id = ?
                  AND status = 'approved'
                  AND used_at IS NULL
                  AND expires_at > ?
                """,
                (now_iso, claim_token, request_id, now_iso),
            )

            if cursor.rowcount == 0:
                conn.commit()
                return {"status": BrowserLoginResult.USED, "error": "Challenge already consumed"}

            payload = {
                "request_id": request_id,
                "telegram_id": row["telegram_id"],
                "telegram_username": row["telegram_username"] or "",
                "claim_token": claim_token,
            }

            session_data = None
            if exchange_callback:
                try:
                    session_data = exchange_callback(payload)
                except Exception as ex:
                    conn.rollback()
                    return {
                        "status": BrowserLoginResult.EXCHANGE_FAILED,
                        "error": str(ex),
                    }

            conn.commit()

            res: Dict[str, Any] = {
                "status": BrowserLoginResult.CONSUMED,
                "telegram_id": row["telegram_id"],
                "telegram_username": row["telegram_username"] or "",
                "claim_token": claim_token,
            }
            if session_data is not None:
                res["session"] = session_data
            return res
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def prune_expired(self, older_than_seconds: int = 86400) -> int:
        """Prune expired challenges older than given threshold."""
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=older_than_seconds)
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "DELETE FROM browser_login_challenges WHERE expires_at < ?",
                (cutoff.isoformat(),),
            )
            return cursor.rowcount
