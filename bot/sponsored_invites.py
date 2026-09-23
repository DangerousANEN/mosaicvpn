import datetime
import hashlib
import math
import secrets
import sqlite3
import uuid
from typing import Any, Dict, NamedTuple, Optional, Tuple


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _is_valid_int(val: Any) -> bool:
    if type(val) is not int or isinstance(val, bool):
        return False
    return True


def build_gift_url(token: str, base_url: str = "") -> str:
    clean_base = base_url.rstrip("/") if base_url else ""
    return f"{clean_base}/setup.html#gift={token}"


class ClaimResult:
    def __init__(self, record: Optional[Dict[str, Any]], error: Optional[str], status: str):
        self.record = record
        self.error = error
        self.status = status

    @property
    def is_claimed(self) -> bool:
        return self.status == "claimed"

    @property
    def is_repeat(self) -> bool:
        return self.status == "repeat"

    def __iter__(self):
        return iter((self.record, self.error))

    def __getitem__(self, idx):
        return (self.record, self.error)[idx]

    def __len__(self):
        return 2

    def __repr__(self):
        return f"ClaimResult(record={bool(self.record)}, error={self.error!r}, status={self.status!r})"


class SponsoredInviteStore:
    MAX_TTL_SECONDS = 7 * 86400  # 7 days

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._mem_conn = None
        if db_path == ":memory:":
            self._mem_conn = sqlite3.connect(":memory:", check_same_thread=False, timeout=30.0)
            self._mem_conn.row_factory = sqlite3.Row
        self._init_db()

    def _get_connection(self) -> sqlite3.Connection:
        if self._mem_conn is not None:
            return self._mem_conn
        conn = sqlite3.connect(self.db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._get_connection() as conn:
            conn.execute("PRAGMA journal_mode = WAL;")
            conn.execute("""
            CREATE TABLE IF NOT EXISTS sponsored_invites (
                id TEXT PRIMARY KEY,
                admin_id INTEGER NOT NULL,
                request_id TEXT NOT NULL,
                amount INTEGER NOT NULL,
                label TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                claimed_at TEXT,
                claimant_account_id INTEGER,
                claimant_label TEXT,
                completed_at TEXT,
                result TEXT,
                error TEXT
            )
            """)
            conn.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS uq_admin_request
            ON sponsored_invites (admin_id, request_id)
            """)
            conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_admin_created
            ON sponsored_invites (admin_id, created_at DESC)
            """)
            conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_status
            ON sponsored_invites (status)
            """)

    def _row_to_dict(self, row: Optional[sqlite3.Row], include_hash: bool = False) -> Optional[Dict[str, Any]]:
        if not row:
            return None
        d = dict(row)
        # Convenience aliases
        d["claimant_telegram_id"] = d.get("claimant_account_id")
        if not include_hash:
            d.pop("token_hash", None)
        return d

    def create(
        self,
        admin_id: int,
        amount: int,
        label: str,
        request_id: str,
        ttl: int = MAX_TTL_SECONDS,
        ttl_seconds: Optional[int] = None,
    ) -> Tuple[Dict[str, Any], Optional[str]]:
        if ttl_seconds is not None:
            ttl = ttl_seconds

        # Type and value validations
        if not _is_valid_int(admin_id) or admin_id <= 0:
            raise ValueError("admin_id must be a positive integer")

        if not _is_valid_int(amount):
            raise TypeError("amount must be an integer")
        if amount < 1 or amount > 10000:
            raise ValueError("amount must be between 1 and 10000")

        if not isinstance(label, str):
            raise TypeError("label must be a string")
        stripped_label = label.strip()
        if not (1 <= len(stripped_label) <= 80):
            raise ValueError("label must be between 1 and 80 characters")

        if not isinstance(request_id, str):
            raise TypeError("request_id must be a string")
        stripped_request_id = request_id.strip()
        if not stripped_request_id:
            raise ValueError("request_id must be non-empty")

        if not _is_valid_int(ttl):
            raise TypeError("ttl must be an integer")
        if ttl <= 0 or ttl > self.MAX_TTL_SECONDS:
            raise ValueError(f"ttl must be between 1 and {self.MAX_TTL_SECONDS} seconds (max 7 days)")

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("BEGIN IMMEDIATE")
            cursor.execute(
                "SELECT * FROM sponsored_invites WHERE admin_id = ? AND request_id = ?",
                (admin_id, stripped_request_id),
            )
            row = cursor.fetchone()
            if row:
                conn.commit()
                existing = self._row_to_dict(row, include_hash=True)
                if existing["amount"] != amount or existing["label"] != stripped_label:
                    raise ValueError("Idempotency conflict: request_id exists with different parameters")
                return existing, None

            invite_id = f"inv_{uuid.uuid4().hex[:16]}"
            token = secrets.token_urlsafe(32)
            token_hash = _hash_token(token)

            now = datetime.datetime.now(datetime.timezone.utc)
            expires = now + datetime.timedelta(seconds=ttl)
            created_at_str = now.isoformat()
            expires_at_str = expires.isoformat()

            try:
                cursor.execute(
                    """
                    INSERT INTO sponsored_invites (
                        id, admin_id, request_id, amount, label, token_hash,
                        status, created_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                    """,
                    (
                        invite_id,
                        admin_id,
                        stripped_request_id,
                        amount,
                        stripped_label,
                        token_hash,
                        created_at_str,
                        expires_at_str,
                    ),
                )
                conn.commit()
            except sqlite3.IntegrityError:
                conn.commit()
                # Race condition: another thread inserted between our select and insert
                cursor.execute(
                    "SELECT * FROM sponsored_invites WHERE admin_id = ? AND request_id = ?",
                    (admin_id, stripped_request_id),
                )
                row = cursor.fetchone()
                if row:
                    existing = self._row_to_dict(row, include_hash=True)
                    if existing["amount"] != amount or existing["label"] != stripped_label:
                        raise ValueError("Idempotency conflict: request_id exists with different parameters")
                    return existing, None
                raise

            cursor.execute("SELECT * FROM sponsored_invites WHERE id = ?", (invite_id,))
            record = self._row_to_dict(cursor.fetchone(), include_hash=True)
            return record, token

    def get(self, invite_id: str, admin_id: Optional[int] = None) -> Optional[Dict[str, Any]]:
        if not isinstance(invite_id, str) or not invite_id.strip():
            return None
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if admin_id is not None:
                if not _is_valid_int(admin_id) or admin_id <= 0:
                    return None
                cursor.execute(
                    "SELECT * FROM sponsored_invites WHERE id = ? AND admin_id = ?",
                    (invite_id.strip(), admin_id),
                )
            else:
                cursor.execute(
                    "SELECT * FROM sponsored_invites WHERE id = ?",
                    (invite_id.strip(),),
                )
            row = cursor.fetchone()
            return self._row_to_dict(row, include_hash=False)

    def list(self, admin_id: int) -> list[Dict[str, Any]]:
        if not _is_valid_int(admin_id) or admin_id <= 0:
            raise ValueError("admin_id must be a positive integer")

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT id, admin_id, request_id, amount, label, status,
                       created_at, expires_at, claimed_at, claimant_account_id,
                       claimant_label, completed_at, result, error
                FROM sponsored_invites
                WHERE admin_id = ?
                ORDER BY created_at DESC
                """,
                (admin_id,),
            )
            return [self._row_to_dict(row, include_hash=False) for row in cursor.fetchall()]

    def claim(
        self,
        token: str,
        account_id: Optional[int] = None,
        claimant_label: Optional[str] = None,
        telegram_id: Optional[int] = None,
    ) -> ClaimResult:
        if not isinstance(token, str) or not token.strip():
            raise ValueError("token must be a non-empty string")

        eff_account_id = account_id if account_id is not None else telegram_id
        if not _is_valid_int(eff_account_id) or eff_account_id == 0:
            raise ValueError("claimant account_id must be a non-zero integer (may be negative)")

        if claimant_label is not None:
            if not isinstance(claimant_label, str):
                raise TypeError("claimant_label must be a string")
            claimant_label = claimant_label.strip()
            if len(claimant_label) > 120:
                claimant_label = claimant_label[:120]

        token_hash = _hash_token(token.strip())
        now = datetime.datetime.now(datetime.timezone.utc)
        now_str = now.isoformat()

        with self._get_connection() as conn:
            cursor = conn.cursor()
            # Lock row using immediate/exclusive or select in transaction
            cursor.execute("BEGIN IMMEDIATE")
            cursor.execute("SELECT * FROM sponsored_invites WHERE token_hash = ?", (token_hash,))
            row = cursor.fetchone()
            if not row:
                conn.commit()
                return ClaimResult(record=None, error="not_found", status="not_found")

            rec = dict(row)
            # Check expiry
            expires_at = datetime.datetime.fromisoformat(rec["expires_at"])
            if now >= expires_at:
                conn.commit()
                return ClaimResult(record=None, error="expired", status="expired")

            current_status = rec["status"]
            current_claimant = rec.get("claimant_account_id")

            # Check if revoked
            if current_status == "revoked":
                conn.commit()
                return ClaimResult(record=None, error="revoked", status="revoked")

            # Repeat claim by same user
            if current_claimant == eff_account_id:
                conn.commit()
                return ClaimResult(
                    record=self._row_to_dict(row, include_hash=False),
                    error="repeat",
                    status="repeat",
                )

            # Claimed by someone else or not pending
            if current_status != "pending" or current_claimant is not None:
                conn.commit()
                return ClaimResult(record=None, error="already_claimed", status="already_claimed")

            # Transition pending -> processing
            cursor.execute(
                """
                UPDATE sponsored_invites
                SET status = 'processing',
                    claimed_at = ?,
                    claimant_account_id = ?,
                    claimant_label = ?
                WHERE id = ? AND status = 'pending'
                """,
                (now_str, eff_account_id, claimant_label, rec["id"]),
            )
            if cursor.rowcount == 0:
                # Concurrent race condition lost
                conn.commit()
                cursor.execute("SELECT * FROM sponsored_invites WHERE id = ?", (rec["id"],))
                fresh = cursor.fetchone()
                if fresh and dict(fresh).get("claimant_account_id") == eff_account_id:
                    return ClaimResult(
                        record=self._row_to_dict(fresh, include_hash=False),
                        error="repeat",
                        status="repeat",
                    )
                return ClaimResult(record=None, error="already_claimed", status="already_claimed")

            conn.commit()
            cursor.execute("SELECT * FROM sponsored_invites WHERE id = ?", (rec["id"],))
            updated_row = cursor.fetchone()
            return ClaimResult(
                record=self._row_to_dict(updated_row, include_hash=False),
                error=None,
                status="claimed",
            )

    def finish(
        self,
        invite_id: str,
        status: str,
        result: Optional[str] = None,
        error: Optional[str] = None,
    ) -> bool:
        if not isinstance(invite_id, str) or not invite_id.strip():
            raise ValueError("invite_id must be a non-empty string")
        if status not in {"succeeded", "failed", "uncertain"}:
            raise ValueError("status must be one of 'succeeded', 'failed', 'uncertain'")

        now_str = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                UPDATE sponsored_invites
                SET status = ?,
                    completed_at = ?,
                    result = ?,
                    error = ?
                WHERE id = ? AND status = 'processing'
                """,
                (status, now_str, result, error, invite_id.strip()),
            )
            conn.commit()
            return cursor.rowcount > 0

    def revoke(self, invite_id: str, admin_id: int) -> bool:
        if not isinstance(invite_id, str) or not invite_id.strip():
            raise ValueError("invite_id must be a non-empty string")
        if not _is_valid_int(admin_id) or admin_id <= 0:
            raise ValueError("admin_id must be a positive integer")

        now = datetime.datetime.now(datetime.timezone.utc)
        now_str = now.isoformat()
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                UPDATE sponsored_invites
                SET status = 'revoked',
                    completed_at = ?
                WHERE id = ? AND admin_id = ? AND status = 'pending' AND expires_at > ?
                """,
                (now_str, invite_id.strip(), admin_id, now_str),
            )
            conn.commit()
            return cursor.rowcount > 0
