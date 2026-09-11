#!/usr/bin/env python3
import datetime as dt
import hashlib
import os
from contextlib import contextmanager

import psycopg2
from psycopg2.extras import Json

UTC = dt.timezone.utc
MOSCOW = dt.timezone(dt.timedelta(hours=3))
DAILY_DEBIT_KOPECKS = 100


def pg_connection_config():
    value = os.environ.get('MOSAIC_PG_DSN')
    if value:
        return value
    password_path = os.environ.get('MOSAIC_PG_PASSWORD_FILE')
    if password_path:
        with open(password_path, 'r', encoding='utf-8') as handle:
            password = handle.read().strip()
        return {
            'host': os.environ.get('MOSAIC_PG_HOST', '127.0.0.1'),
            'port': int(os.environ.get('MOSAIC_PG_PORT', '6767')),
            'user': os.environ.get('MOSAIC_PG_USER', 'postgres'),
            'dbname': os.environ.get('MOSAIC_PG_DATABASE', 'postgres'),
            'password': password,
            'connect_timeout': 10,
        }
    raise RuntimeError('PostgreSQL connection is not configured')

@contextmanager
def db():
    config = pg_connection_config()
    conn = psycopg2.connect(config) if isinstance(config, str) else psycopg2.connect(**config)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

def day_key(now=None):
    now = now or dt.datetime.now(MOSCOW)
    return now.date()

def account_by_telegram(telegram_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT account_id FROM mosaic_identities WHERE kind='telegram' AND normalized_value=%s", (str(telegram_id),))
        row = cur.fetchone()
        return row[0] if row else None

def summary(account_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT a.id,a.status,a.language,a.tier,a.trial_ends_at,w.balance_kopecks,
                   s.remnawave_short_uuid,s.frozen_at
            FROM mosaic_accounts a
            JOIN mosaic_wallets w ON w.account_id=a.id
            LEFT JOIN mosaic_subscriptions s ON s.account_id=a.id
            WHERE a.id=%s
        """, (account_id,))
        row = cur.fetchone()
    if not row:
        return None
    return {'account_id': str(row[0]), 'status': row[1], 'language': row[2], 'tier': row[3],
            'trial_ends_at': row[4].isoformat() if row[4] else None,
            'balance_kopecks': row[5], 'balance_rub': row[5] / 100,
            'short_uuid': row[6], 'frozen_at': row[7].isoformat() if row[7] else None}

def freeze(account_id, reason='user_request'):
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE mosaic_accounts SET status='frozen',updated_at=now() WHERE id=%s AND status <> 'revoked' RETURNING id", (account_id,))
        changed = cur.fetchone() is not None
        if changed:
            cur.execute("UPDATE mosaic_subscriptions SET frozen_at=now(),updated_at=now() WHERE account_id=%s", (account_id,))
    return changed

def unfreeze(account_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            UPDATE mosaic_accounts SET status=CASE WHEN EXISTS (
              SELECT 1 FROM mosaic_wallets WHERE account_id=%s AND balance_kopecks>0
            ) OR EXISTS (
              SELECT 1 FROM mosaic_accounts WHERE id=%s AND trial_ends_at>now()
            ) THEN 'active' ELSE 'insufficient_funds' END,updated_at=now()
            WHERE id=%s AND status='frozen' RETURNING status
        """, (account_id, account_id, account_id))
        row = cur.fetchone()
        if row:
            cur.execute("UPDATE mosaic_subscriptions SET frozen_at=NULL,updated_at=now() WHERE account_id=%s", (account_id,))
            return row[0]
    return None

def credit(account_id, amount_kopecks, idempotency_key, kind='topup', metadata=None):
    if amount_kopecks <= 0:
        raise ValueError('amount must be positive')
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM mosaic_ledger WHERE idempotency_key=%s", (idempotency_key,))
        if cur.fetchone():
            return summary(account_id)
        cur.execute("UPDATE mosaic_wallets SET balance_kopecks=balance_kopecks+%s,updated_at=now() WHERE account_id=%s RETURNING balance_kopecks", (amount_kopecks, account_id))
        row = cur.fetchone()
        if not row:
            raise LookupError('wallet not found')
        cur.execute("INSERT INTO mosaic_ledger(account_id,kind,amount_kopecks,balance_after_kopecks,idempotency_key,metadata) VALUES(%s,%s,%s,%s,%s,%s)", (account_id, kind, amount_kopecks, row[0], idempotency_key, Json(metadata or {})))
        cur.execute("UPDATE mosaic_accounts SET status=CASE WHEN status IN ('insufficient_funds','frozen') THEN status ELSE 'active' END,updated_at=now() WHERE id=%s", (account_id,))
    return summary(account_id)

def debit_one_day(account_id, debit_date=None):
    debit_date = debit_date or day_key()
    amount_kopecks = daily_price_kopecks()
    key = f'daily-debit:{account_id}:{debit_date.isoformat()}'
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1 FROM mosaic_daily_debits WHERE account_id=%s AND debit_date=%s", (account_id, debit_date))
        if cur.fetchone():
            return {'result':'already_done','account_id':account_id}
        cur.execute("SELECT balance_kopecks FROM mosaic_wallets WHERE account_id=%s FOR UPDATE", (account_id,))
        row = cur.fetchone()
        if not row or row[0] < amount_kopecks:
            cur.execute("UPDATE mosaic_accounts SET status='insufficient_funds',updated_at=now() WHERE id=%s AND status <> 'revoked'", (account_id,))
            return {'result':'insufficient_funds','account_id':account_id}
        balance = row[0] - amount_kopecks
        cur.execute("UPDATE mosaic_wallets SET balance_kopecks=%s,updated_at=now() WHERE account_id=%s", (balance, account_id))
        cur.execute("INSERT INTO mosaic_ledger(account_id,kind,amount_kopecks,balance_after_kopecks,idempotency_key,metadata) VALUES(%s,'daily_debit',%s,%s,%s,%s) RETURNING id", (account_id, -amount_kopecks, balance, key, Json({'debit_date':debit_date.isoformat(),'daily_price_kopecks':amount_kopecks})))
        ledger_id = cur.fetchone()[0]
        cur.execute("INSERT INTO mosaic_daily_debits(account_id,debit_date,amount_kopecks,ledger_id) VALUES(%s,%s,%s,%s)", (account_id, debit_date, amount_kopecks, ledger_id))
        cur.execute("UPDATE mosaic_accounts SET status='active',updated_at=now() WHERE id=%s AND status <> 'revoked'", (account_id,))
        cur.execute("UPDATE mosaic_subscriptions SET last_debit_at=now(),updated_at=now() WHERE account_id=%s", (account_id,))
        return {'result':'debited','account_id':account_id,'balance_kopecks':balance,'ledger_id':ledger_id,'amount_kopecks':amount_kopecks}

def refund_debit(account_id, debit_date, reason):
    key = f'daily-debit-refund:{account_id}:{debit_date.isoformat()}'
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT amount_kopecks FROM mosaic_daily_debits WHERE account_id=%s AND debit_date=%s", (account_id, debit_date))
        row = cur.fetchone()
    amount_kopecks = int(row[0]) if row else daily_price_kopecks()
    return credit(account_id, amount_kopecks, key, kind='refund', metadata={'reason':reason,'debit_date':debit_date.isoformat()})

def active_accounts_for_debit(now=None):
    today = day_key(now)
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
          SELECT a.id,s.remnawave_username FROM mosaic_accounts a
          LEFT JOIN mosaic_subscriptions s ON s.account_id=a.id
          WHERE a.status='active' AND (a.trial_ends_at IS NULL OR a.trial_ends_at <= now())
        """)
        return [(str(r[0]), r[1]) for r in cur.fetchall()]

def run_daily_debits(extend_user, disable_user, logger):
    today = day_key()
    for account_id, username in active_accounts_for_debit():
        result = debit_one_day(account_id, today)
        if result.get('result') != 'debited':
            if result.get('result') == 'insufficient_funds' and username:
                disable_user(username)
            continue
        try:
            if not username or not extend_user(username, 1):
                refund_debit(account_id, today, 'remnawave_extend_failed')
                logger.error('Daily debit rolled back for account %s: Remnawave extend failed', account_id)
                continue
            logger.info('Daily debit completed for account %s', account_id)
        except Exception as exc:
            refund_debit(account_id, today, 'remnawave_extend_exception')
            logger.exception('Daily debit rolled back for account %s: %s', account_id, exc)


def ensure_telegram_account(telegram_id, language='ru'):
    normalized = str(int(telegram_id))
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT account_id FROM mosaic_identities WHERE kind='telegram' AND normalized_value=%s", (normalized,))
        row = cur.fetchone()
        if row:
            cur.execute("UPDATE mosaic_accounts SET language=COALESCE(NULLIF(%s,''),language),updated_at=now() WHERE id=%s", (language or '', row[0]))
            return str(row[0])
        cur.execute("INSERT INTO mosaic_accounts(language) VALUES(%s) RETURNING id", (language or 'ru',))
        account_id = cur.fetchone()[0]
        cur.execute("INSERT INTO mosaic_identities(account_id,kind,value,normalized_value,verified_at) VALUES(%s,'telegram',%s,%s,now())", (account_id, normalized, normalized))
        cur.execute("INSERT INTO mosaic_wallets(account_id) VALUES(%s)", (account_id,))
        cur.execute("INSERT INTO mosaic_subscriptions(account_id) VALUES(%s)", (account_id,))
        return str(account_id)


def create_payment(account_id, invoice_id, amount_kopecks, amount_usdt, metadata=None):
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            INSERT INTO mosaic_payments(invoice_id,account_id,amount_kopecks,amount_usdt,status,metadata)
            VALUES(%s,%s,%s,%s,'pending',%s)
            ON CONFLICT(invoice_id) DO NOTHING
        """, (invoice_id, account_id, amount_kopecks, amount_usdt, Json(metadata or {})))


def complete_payment(invoice_id):
    """Atomically claim a paid invoice and credit the wallet once."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT account_id,amount_kopecks,status FROM mosaic_payments WHERE invoice_id=%s FOR UPDATE", (invoice_id,))
        payment = cur.fetchone()
        if not payment:
            raise LookupError('payment not found')
        account_id, amount, status = payment
        if status == 'paid':
            return {'result': 'already_paid', 'account_id': str(account_id)}
        if status != 'pending':
            return {'result': f'not_payable:{status}', 'account_id': str(account_id)}
        cur.execute("UPDATE mosaic_wallets SET balance_kopecks=balance_kopecks+%s,updated_at=now() WHERE account_id=%s RETURNING balance_kopecks", (amount, account_id))
        balance = cur.fetchone()[0]
        cur.execute("""
            INSERT INTO mosaic_ledger(account_id,kind,amount_kopecks,balance_after_kopecks,idempotency_key,metadata)
            VALUES(%s,'topup',%s,%s,%s,%s)
            ON CONFLICT(idempotency_key) DO NOTHING
        """, (account_id, amount, balance, f'cryptopay:{invoice_id}', Json({'invoice_id': invoice_id})))
        cur.execute("UPDATE mosaic_payments SET status='paid',paid_at=now() WHERE invoice_id=%s", (invoice_id,))
        cur.execute("UPDATE mosaic_accounts SET status=CASE WHEN status='insufficient_funds' THEN 'active' ELSE status END,updated_at=now() WHERE id=%s", (account_id,))
        return {'result':'credited','account_id':str(account_id),'balance_kopecks':balance}


def claim_telegram_trial(account_id, telegram_user_id, channel_username, days=3):
    """Issue a one-time Telegram trial after channel membership was verified."""
    if days <= 0:
        raise ValueError('trial days must be positive')
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT trial_ends_at FROM mosaic_accounts WHERE id=%s FOR UPDATE", (account_id,))
        row = cur.fetchone()
        if not row:
            raise LookupError('account not found')
        if row[0] and row[0] > dt.datetime.now(UTC):
            return {'result': 'already_active', 'trial_ends_at': row[0].isoformat()}
        cur.execute("SELECT account_id FROM mosaic_trial_claims WHERE channel_username=%s AND telegram_user_id=%s", (channel_username, int(telegram_user_id)))
        prior = cur.fetchone()
        if prior and str(prior[0]) != str(account_id):
            return {'result': 'already_claimed_elsewhere'}
        cur.execute("""
            UPDATE mosaic_accounts SET status='active',trial_started_at=COALESCE(trial_started_at,now()),
                trial_ends_at=now()+(%s * interval '1 day'),updated_at=now()
            WHERE id=%s RETURNING trial_ends_at
        """, (days, account_id))
        trial_ends_at = cur.fetchone()[0]
        cur.execute("""
            INSERT INTO mosaic_trial_claims(account_id,channel_username,telegram_user_id)
            VALUES(%s,%s,%s)
            ON CONFLICT(account_id) DO UPDATE SET checked_at=now(),channel_username=excluded.channel_username,telegram_user_id=excluded.telegram_user_id
        """, (account_id, channel_username, int(telegram_user_id)))
        return {'result': 'claimed', 'trial_ends_at': trial_ends_at.isoformat()}


# Password-based web accounts use a versioned hashlib.scrypt format. Passwords are never stored or logged.
def _password_hash(password):
    import base64
    import secrets
    if not isinstance(password, str) or len(password) < 10 or len(password) > 256:
        raise ValueError('password length must be between 10 and 256 characters')
    salt = secrets.token_bytes(16)
    digest = __import__('hashlib').scrypt(password.encode('utf-8'), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return 'scrypt$16384$8$1$' + base64.urlsafe_b64encode(salt).decode() + '$' + base64.urlsafe_b64encode(digest).decode()


def _password_matches(password, stored):
    import base64
    import hmac
    try:
        kind, n, r, p, salt_b64, digest_b64 = stored.split('$', 5)
        if kind != 'scrypt':
            return False
        salt = base64.urlsafe_b64decode(salt_b64.encode())
        expected = base64.urlsafe_b64decode(digest_b64.encode())
        actual = __import__('hashlib').scrypt(password.encode('utf-8'), salt=salt, n=int(n), r=int(r), p=int(p), dklen=len(expected))
        return hmac.compare_digest(actual, expected)
    except Exception:
        return False


def _normalized_email(email):
    import re
    value = (email or '').strip().lower()
    if len(value) > 254 or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value):
        raise ValueError('invalid email')
    return value


def create_email_account(email, password, language='ru'):
    normalized = _normalized_email(email)
    password_hash = _password_hash(password)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT account_id FROM mosaic_identities WHERE kind='email' AND normalized_value=%s", (normalized,))
        if cur.fetchone():
            raise ValueError('email already registered')
        cur.execute("INSERT INTO mosaic_accounts(language,status) VALUES(%s,'insufficient_funds') RETURNING id", (language or 'ru',))
        account_id = cur.fetchone()[0]
        cur.execute("INSERT INTO mosaic_identities(account_id,kind,value,normalized_value,password_hash,verified_at) VALUES(%s,'email',%s,%s,%s,now())", (account_id, normalized, normalized, password_hash))
        cur.execute("INSERT INTO mosaic_wallets(account_id) VALUES(%s)", (account_id,))
        cur.execute("INSERT INTO mosaic_subscriptions(account_id) VALUES(%s)", (account_id,))
        return str(account_id)


def authenticate_email(email, password):
    normalized = _normalized_email(email)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT account_id,password_hash FROM mosaic_identities WHERE kind='email' AND normalized_value=%s", (normalized,))
        row = cur.fetchone()
    if not row or not _password_matches(password or '', row[1] or ''):
        return None
    return str(row[0])


def create_session(account_id, kind='web', ttl_days=30):
    import secrets
    token = secrets.token_urlsafe(32)
    token_hash = __import__('hashlib').sha256(token.encode('utf-8')).hexdigest()
    with db() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO mosaic_sessions(token_hash,account_id,kind,expires_at) VALUES(%s,%s,%s,now()+(%s * interval '1 day'))", (token_hash, account_id, kind, ttl_days))
    return token


def get_session(token, kind='web'):
    if not token or len(token) > 256:
        return None
    token_hash = __import__('hashlib').sha256(token.encode('utf-8')).hexdigest()
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT s.account_id,a.status,a.language FROM mosaic_sessions s
            JOIN mosaic_accounts a ON a.id=s.account_id
            WHERE s.token_hash=%s AND s.kind=%s AND s.revoked_at IS NULL AND s.expires_at>now()
        """, (token_hash, kind))
        row = cur.fetchone()
    if not row:
        return None
    return {'account_id': str(row[0]), 'status': row[1], 'language': row[2]}


def payment_history(account_id, limit=50):
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT invoice_id,amount_kopecks,amount_usdt,status,created_at,paid_at
            FROM mosaic_payments WHERE account_id=%s
            ORDER BY created_at DESC LIMIT %s
        """, (account_id, max(1, min(int(limit), 100))))
        rows = cur.fetchall()
    return [{'invoice_id': r[0], 'amount_rub': r[1] / 100, 'amount_usdt': float(r[2]),
             'status': r[3], 'created_at': r[4].isoformat(), 'paid_at': r[5].isoformat() if r[5] else None}
            for r in rows]


def _notification_exists(cur, key):
    cur.execute("SELECT 1 FROM mosaic_notifications WHERE idempotency_key=%s", (key,))
    return cur.fetchone() is not None


def mark_notification(account_id, campaign, idempotency_key, metadata=None):
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            INSERT INTO mosaic_notifications(account_id,campaign,idempotency_key,metadata)
            VALUES(%s,%s,%s,%s) ON CONFLICT(idempotency_key) DO NOTHING
        """, (account_id, campaign, idempotency_key, Json(metadata or {})))


def notification_candidates(now=None):
    """Return deterministic, cooldown-protected Telegram notification candidates."""
    today = (now or dt.datetime.now(MOSCOW)).date().isoformat()
    month = today[:7]
    queries = {
        'setup_help': """
          SELECT a.id,i.value,NULL::bigint FROM mosaic_accounts a
          JOIN mosaic_identities i ON i.account_id=a.id AND i.kind='telegram'
          LEFT JOIN mosaic_subscriptions s ON s.account_id=a.id
          LEFT JOIN users rw ON rw.uuid=s.remnawave_user_uuid
          LEFT JOIN user_traffic ut ON ut.t_id=rw.t_id
          WHERE a.created_at < now()-interval '24 hours' AND a.created_at > now()-interval '7 days'
            AND (ut.first_connected_at IS NULL) AND a.status='active'
        """,
        'freeze_offer': """
          SELECT a.id,i.value,w.balance_kopecks FROM mosaic_accounts a
          JOIN mosaic_identities i ON i.account_id=a.id AND i.kind='telegram'
          JOIN mosaic_wallets w ON w.account_id=a.id
          LEFT JOIN mosaic_subscriptions s ON s.account_id=a.id
          LEFT JOIN users rw ON rw.uuid=s.remnawave_user_uuid
          LEFT JOIN user_traffic ut ON ut.t_id=rw.t_id
          WHERE a.status='active' AND w.balance_kopecks>0 AND ut.online_at < now()-interval '14 days'
        """,
        'low_balance': """
          SELECT a.id,i.value,w.balance_kopecks FROM mosaic_accounts a
          JOIN mosaic_identities i ON i.account_id=a.id AND i.kind='telegram'
          JOIN mosaic_wallets w ON w.account_id=a.id
          WHERE a.status='active' AND w.balance_kopecks BETWEEN 1 AND 300
        """,
        'loyalty_bonus': """
          SELECT a.id,i.value,ut.lifetime_used_traffic_bytes FROM mosaic_accounts a
          JOIN mosaic_identities i ON i.account_id=a.id AND i.kind='telegram'
          LEFT JOIN mosaic_subscriptions s ON s.account_id=a.id
          LEFT JOIN users rw ON rw.uuid=s.remnawave_user_uuid
          LEFT JOIN user_traffic ut ON ut.t_id=rw.t_id
          WHERE a.status='active' AND a.created_at < now()-interval '30 days'
            AND coalesce(ut.lifetime_used_traffic_bytes,0) >= 1073741824
        """,
    }
    candidates = []
    with db() as conn, conn.cursor() as cur:
        for campaign, query in queries.items():
            cur.execute(query)
            for account_id, telegram_id, metric in cur.fetchall():
                scope = month if campaign == 'loyalty_bonus' else today if campaign == 'low_balance' else 'once'
                key = f'{campaign}:{account_id}:{scope}'
                if not _notification_exists(cur, key):
                    candidates.append({'account_id': str(account_id), 'telegram_id': int(telegram_id), 'campaign': campaign, 'key': key, 'metric': metric})
    return candidates


def direct_pool_feed(account_id, limit=80):
    """Return curated direct outbounds for an active account without source metadata."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT a.status,a.trial_ends_at,w.balance_kopecks
            FROM mosaic_accounts a JOIN mosaic_wallets w ON w.account_id=a.id WHERE a.id=%s
        """, (account_id,))
        state = cur.fetchone()
        if not state:
            return None, 'account_not_found'
        status, trial_ends_at, balance = state
        has_trial = bool(trial_ends_at and trial_ends_at > dt.datetime.now(UTC))
        if status != 'active' or (not has_trial and balance <= 0):
            return None, 'access_inactive'
        cur.execute("""
            SELECT n.id,n.config,n.country_code,n.speed_mbps,gn.priority,
                   (SELECT priority FROM mosaic_group_nodes x WHERE x.group_id='stable' AND x.node_id=n.id) AS stable_priority,
                   (SELECT priority FROM mosaic_group_nodes x WHERE x.group_id='allowlist' AND x.node_id=n.id) AS allowlist_priority,
                   (SELECT priority FROM mosaic_group_nodes x WHERE x.group_id='max_speed' AND x.node_id=n.id) AS speed_priority
            FROM mosaic_group_nodes gn JOIN mosaic_nodes n ON n.id=gn.node_id
            WHERE gn.group_id='all' AND n.enabled AND n.proxy_ok=true
            ORDER BY gn.priority ASC LIMIT %s
        """, (max(1, min(int(limit), 100)),))
        rows = cur.fetchall()
    outbounds = []
    for node_id, config, country, speed_mbps, priority, stable_priority, allowlist_priority, speed_priority in rows:
        item = dict(config or {})
        if 'uri' in item:
            continue
        item['tag'] = f"pool-{node_id}-{(country or 'xx').lower()}"
        # These are client-selection hints only; source URLs and operator
        # metadata are never exported with a node configuration.
        if country:
            item['mosaic_country'] = country
        if speed_mbps is not None:
            item['mosaic_speed_mbps'] = float(speed_mbps)
        # Client-only group hints. They carry no source URL, provenance or
        # admin health log and do not change the protocol outbound itself.
        item['mosaic_stable'] = stable_priority is not None
        item['mosaic_allowlist'] = allowlist_priority is not None
        item['mosaic_speed_eligible'] = speed_priority is not None
        item['mosaic_failover_priority'] = max(1, int(priority or 999))
        if stable_priority is not None:
            item['mosaic_stable_priority'] = int(stable_priority)
        if allowlist_priority is not None:
            item['mosaic_allowlist_priority'] = int(allowlist_priority)
        outbounds.append(item)
    return {'outbounds': outbounds}, None


def subscription_username(account_id):
    """Return the Remnawave username bound to a Mosaic account, if any."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT remnawave_username FROM mosaic_subscriptions WHERE account_id=%s", (account_id,))
        row = cur.fetchone()
    return row[0] if row and row[0] else None


def pending_checkout_payments(limit=100):
    """Return pending hosted-checkout invoices without exposing payment secrets."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT p.invoice_id,p.account_id,p.amount_kopecks,p.amount_usdt,
                   coalesce(p.metadata->>'provider','cryptopay'),s.remnawave_username
            FROM mosaic_payments p
            LEFT JOIN mosaic_subscriptions s ON s.account_id=p.account_id
            WHERE p.status='pending'
              AND coalesce(p.metadata->>'channel','')='unified_checkout'
            ORDER BY p.created_at ASC
            LIMIT %s
        """, (max(1, min(int(limit), 200)),))
        rows = cur.fetchall()
    return [
        {
            'invoice_id': int(row[0]), 'account_id': str(row[1]),
            'amount_kopecks': int(row[2]), 'amount_usdt': float(row[3]),
            'provider': row[4], 'remnawave_username': row[5],
        }
        for row in rows
    ]


def checkout_status(account_id, invoice_id):
    """Return a minimal status view for an invoice owned by the authenticated account."""
    try:
        invoice_id = int(invoice_id)
    except (TypeError, ValueError):
        return None
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT invoice_id,status,amount_kopecks,created_at,paid_at,
                   coalesce(metadata->>'provider','cryptopay')
            FROM mosaic_payments
            WHERE account_id=%s AND invoice_id=%s
        """, (account_id, invoice_id))
        row = cur.fetchone()
    if not row:
        return None
    return {
        'invoice_id': int(row[0]), 'status': row[1],
        'amount_rub': int(row[2]) / 100, 'created_at': row[3].isoformat(),
        'paid_at': row[4].isoformat() if row[4] else None, 'provider': row[5],
    }



def resolve_subscription_username(account_id):
    """Return the provisioned Remnawave username, falling back only to a bound Telegram identity."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT s.remnawave_username,i.value
            FROM mosaic_subscriptions s
            LEFT JOIN mosaic_identities i ON i.account_id=s.account_id AND i.kind='telegram'
            WHERE s.account_id=%s
        """, (account_id,))
        row = cur.fetchone()
    if not row:
        return None
    if row[0]:
        return row[0]
    return f"tg_{row[1]}" if row[1] else None


def subscription_link_state(account_id):
    """Return only the current short identifier metadata; never a bearer URL."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT remnawave_username,remnawave_short_uuid
            FROM mosaic_subscriptions WHERE account_id=%s
        """, (account_id,))
        row = cur.fetchone()
    if not row:
        return {'username': None, 'short_uuid': None}
    return {'username': row[0], 'short_uuid': row[1]}


def can_rotate_subscription_link(account_id, cooldown_seconds=300):
    """Rate-limit link rotation per account without leaking historic identifiers."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS mosaic_subscription_link_rotations (
                id bigserial PRIMARY KEY,
                account_id uuid NOT NULL REFERENCES mosaic_accounts(id) ON DELETE CASCADE,
                old_short_uuid text,
                new_short_uuid text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now()
            )
        """)
        cur.execute("""
            SELECT extract(epoch FROM (now()-created_at))
            FROM mosaic_subscription_link_rotations
            WHERE account_id=%s
            ORDER BY created_at DESC LIMIT 1
        """, (account_id,))
        row = cur.fetchone()
    if not row or row[0] is None or float(row[0]) >= cooldown_seconds:
        return {'allowed': True, 'retry_after_seconds': 0}
    return {'allowed': False, 'retry_after_seconds': max(1, int(cooldown_seconds - float(row[0])))}


def record_subscription_link_rotation(account_id, username, old_short_uuid, new_short_uuid):
    """Persist the newly issued identifier and a minimal audit trail after the provider succeeds."""
    if not new_short_uuid or len(str(new_short_uuid)) < 16:
        raise ValueError('invalid regenerated short UUID')
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS mosaic_subscription_link_rotations (
                id bigserial PRIMARY KEY,
                account_id uuid NOT NULL REFERENCES mosaic_accounts(id) ON DELETE CASCADE,
                old_short_uuid text,
                new_short_uuid text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now()
            )
        """)
        cur.execute("""
            UPDATE mosaic_subscriptions
            SET remnawave_username=coalesce(%s,remnawave_username),
                remnawave_short_uuid=%s,updated_at=now()
            WHERE account_id=%s
        """, (username, str(new_short_uuid), account_id))
        if cur.rowcount != 1:
            raise LookupError('subscription binding not found')
        cur.execute("""
            INSERT INTO mosaic_subscription_link_rotations(account_id,old_short_uuid,new_short_uuid)
            VALUES(%s,%s,%s)
        """, (account_id, old_short_uuid, str(new_short_uuid)))
    return {'account_id': str(account_id), 'short_uuid': str(new_short_uuid)}



def sync_subscription_link_state(account_id, username, short_uuid):
    """Synchronize a known current short UUID without creating a rotation/audit event."""
    if not short_uuid or len(str(short_uuid)) < 16:
        raise ValueError('invalid short UUID')
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            UPDATE mosaic_subscriptions
            SET remnawave_username=coalesce(%s,remnawave_username),
                remnawave_short_uuid=%s,updated_at=now()
            WHERE account_id=%s
        """, (username, str(short_uuid), account_id))
        if cur.rowcount != 1:
            raise LookupError('subscription binding not found')
    return {'account_id': str(account_id), 'short_uuid': str(short_uuid)}


# --- Admin control plane ----------------------------------------------------

def _ensure_admin_schema(cur):
    cur.execute("""
        CREATE TABLE IF NOT EXISTS mosaic_service_settings (
            singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
            daily_price_kopecks integer NOT NULL DEFAULT 100 CHECK (daily_price_kopecks BETWEEN 10 AND 100000),
            checkout_discount_percent integer NOT NULL DEFAULT 0 CHECK (checkout_discount_percent BETWEEN 0 AND 90),
            updated_at timestamptz NOT NULL DEFAULT now(),
            updated_by uuid REFERENCES mosaic_accounts(id)
        )
    """)
    cur.execute("""
        INSERT INTO mosaic_service_settings(singleton,daily_price_kopecks,checkout_discount_percent)
        VALUES(true,100,0) ON CONFLICT(singleton) DO NOTHING
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS mosaic_admin_audit (
            id bigserial PRIMARY KEY,
            actor_account_id uuid REFERENCES mosaic_accounts(id),
            action text NOT NULL,
            metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
            created_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS mosaic_announcements (
            id bigserial PRIMARY KEY,
            title text NOT NULL,
            body text NOT NULL,
            severity text NOT NULL DEFAULT 'info' CHECK (severity IN ('info','maintenance','warning')),
            site_visible boolean NOT NULL DEFAULT true,
            telegram_requested boolean NOT NULL DEFAULT false,
            active boolean NOT NULL DEFAULT true,
            starts_at timestamptz NOT NULL DEFAULT now(),
            ends_at timestamptz,
            created_by uuid REFERENCES mosaic_accounts(id),
            created_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS mosaic_announcements_active_idx ON mosaic_announcements(active,starts_at,ends_at)")
    cur.execute("""
        CREATE TABLE IF NOT EXISTS mosaic_trial_channels (
            username text PRIMARY KEY,
            enabled boolean NOT NULL DEFAULT true,
            position integer NOT NULL DEFAULT 0,
            created_by uuid REFERENCES mosaic_accounts(id),
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS mosaic_trial_channels_enabled_idx ON mosaic_trial_channels(enabled,position,username)")
    cur.execute("""
        INSERT INTO mosaic_trial_channels(username,enabled,position)
        VALUES('@llm_hubs',true,0) ON CONFLICT(username) DO NOTHING
    """)


def service_settings():
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("SELECT daily_price_kopecks,checkout_discount_percent,updated_at FROM mosaic_service_settings WHERE singleton=true")
        row = cur.fetchone()
    return {'daily_price_kopecks': int(row[0]), 'daily_price_rub': int(row[0]) / 100,
            'checkout_discount_percent': int(row[1]), 'updated_at': row[2].isoformat() if row[2] else None}


def daily_price_kopecks():
    return service_settings()['daily_price_kopecks']


def update_service_settings(actor_account_id, daily_price_kopecks_value=None, checkout_discount_percent=None):
    values = {}
    if daily_price_kopecks_value is not None:
        value = int(daily_price_kopecks_value)
        if value < 10 or value > 100000:
            raise ValueError('daily price must be between 0.10 and 1000.00 RUB')
        values['daily_price_kopecks'] = value
    if checkout_discount_percent is not None:
        value = int(checkout_discount_percent)
        if value < 0 or value > 90:
            raise ValueError('discount percent must be between 0 and 90')
        values['checkout_discount_percent'] = value
    if not values:
        return service_settings()
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        sets = ', '.join([f"{name}=%s" for name in values] + ['updated_at=now()', 'updated_by=%s'])
        cur.execute(f"UPDATE mosaic_service_settings SET {sets} WHERE singleton=true", tuple(values.values()) + (actor_account_id,))
        cur.execute("INSERT INTO mosaic_admin_audit(actor_account_id,action,metadata) VALUES(%s,%s,%s)",
                    (actor_account_id, 'settings_updated', Json(values)))
    return service_settings()


def active_announcements(limit=3):
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("""
            SELECT id,title,body,severity,starts_at,ends_at
            FROM mosaic_announcements
            WHERE active=true AND site_visible=true AND starts_at<=now()
              AND (ends_at IS NULL OR ends_at>now())
            ORDER BY CASE severity WHEN 'maintenance' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, created_at DESC
            LIMIT %s
        """, (max(1, min(int(limit), 10)),))
        rows = cur.fetchall()
    return [{'id': int(r[0]), 'title': r[1], 'body': r[2], 'severity': r[3],
             'starts_at': r[4].isoformat(), 'ends_at': r[5].isoformat() if r[5] else None} for r in rows]


def create_announcement(actor_account_id, title, body, severity='info', site_visible=True, telegram_requested=False, ends_at=None):
    title = (title or '').strip()
    body = (body or '').strip()
    if not title or len(title) > 140 or not body or len(body) > 1500:
        raise ValueError('announcement title or body length is invalid')
    if severity not in ('info', 'maintenance', 'warning'):
        raise ValueError('invalid announcement severity')
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("""
            INSERT INTO mosaic_announcements(title,body,severity,site_visible,telegram_requested,ends_at,created_by)
            VALUES(%s,%s,%s,%s,%s,%s,%s) RETURNING id
        """, (title, body, severity, bool(site_visible), bool(telegram_requested), ends_at, actor_account_id))
        announcement_id = int(cur.fetchone()[0])
        cur.execute("INSERT INTO mosaic_admin_audit(actor_account_id,action,metadata) VALUES(%s,%s,%s)",
                    (actor_account_id, 'announcement_created', Json({'announcement_id': announcement_id, 'severity': severity, 'site_visible': bool(site_visible), 'telegram_requested': bool(telegram_requested)})))
    return {'id': announcement_id, 'title': title, 'body': body, 'severity': severity,
            'site_visible': bool(site_visible), 'telegram_requested': bool(telegram_requested)}


def account_telegram_ids(account_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT value FROM mosaic_identities WHERE account_id=%s AND kind='telegram'", (account_id,))
        rows = cur.fetchall()
    result = []
    for row in rows:
        try:
            result.append(int(row[0]))
        except (TypeError, ValueError):
            pass
    return result


def telegram_broadcast_recipients():
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT DISTINCT value FROM mosaic_identities WHERE kind='telegram'")
        rows = cur.fetchall()
    recipients = []
    for row in rows:
        try:
            recipients.append(int(row[0]))
        except (TypeError, ValueError):
            pass
    return recipients


def bulk_grant_days(actor_account_id, days, operation_key, note=''):
    days = int(days)
    if days < 1 or days > 365:
        raise ValueError('days must be between 1 and 365')
    if not operation_key or len(operation_key) > 160:
        raise ValueError('invalid operation key')
    amount = daily_price_kopecks() * days
    activated = []
    credited = 0
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("SELECT a.id,a.status,s.remnawave_username FROM mosaic_accounts a JOIN mosaic_wallets w ON w.account_id=a.id LEFT JOIN mosaic_subscriptions s ON s.account_id=a.id ORDER BY a.id")
        rows = cur.fetchall()
        for account_id, status, username in rows:
            ledger_key = f'admin-grant:{operation_key}:{account_id}'
            cur.execute("SELECT 1 FROM mosaic_ledger WHERE idempotency_key=%s", (ledger_key,))
            if cur.fetchone():
                continue
            cur.execute("UPDATE mosaic_wallets SET balance_kopecks=balance_kopecks+%s,updated_at=now() WHERE account_id=%s RETURNING balance_kopecks", (amount, account_id))
            balance = cur.fetchone()[0]
            cur.execute("INSERT INTO mosaic_ledger(account_id,kind,amount_kopecks,balance_after_kopecks,idempotency_key,metadata) VALUES(%s,'bonus',%s,%s,%s,%s)",
                        (account_id, amount, balance, ledger_key, Json({'admin_operation': operation_key, 'days': days, 'note': (note or '')[:240]})))
            if status == 'insufficient_funds':
                cur.execute("UPDATE mosaic_accounts SET status='active',updated_at=now() WHERE id=%s", (account_id,))
                if username:
                    activated.append(username)
            credited += 1
        cur.execute("INSERT INTO mosaic_admin_audit(actor_account_id,action,metadata) VALUES(%s,%s,%s)",
                    (actor_account_id, 'bulk_grant_days', Json({'operation_key': operation_key, 'days': days, 'amount_kopecks': amount, 'credited_accounts': credited, 'note': (note or '')[:240]})))
    return {'credited_accounts': credited, 'amount_kopecks_per_account': amount, 'activated_usernames': activated}


def admin_snapshot():
    """Return aggregate service metrics for an authorized operator; no PII, URLs or tokens."""
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("""
            SELECT count(*),
                   count(*) FILTER (WHERE status='active'),
                   count(*) FILTER (WHERE status='frozen'),
                   count(*) FILTER (WHERE status='insufficient_funds'),
                   count(*) FILTER (WHERE created_at >= now()-interval '24 hours'),
                   count(*) FILTER (WHERE created_at >= now()-interval '7 days'),
                   count(*) FILTER (WHERE trial_ends_at > now())
            FROM mosaic_accounts
        """)
        accounts, active, frozen, insufficient, registered_24h, registered_7d, trial_active = [int(v or 0) for v in cur.fetchone()]
        cur.execute("SELECT coalesce(sum(balance_kopecks),0) FROM mosaic_wallets")
        prepaid = int(cur.fetchone()[0] or 0)
        cur.execute("""
            SELECT count(*) FILTER (WHERE status='paid'),
                   count(*) FILTER (WHERE status='pending'),
                   coalesce(sum(amount_kopecks) FILTER (WHERE status='paid' AND paid_at >= now()-interval '24 hours'),0),
                   coalesce(sum(amount_kopecks) FILTER (WHERE status='paid' AND paid_at >= now()-interval '7 days'),0)
            FROM mosaic_payments
        """)
        paid, pending, payments_24h, payments_7d = [int(v or 0) for v in cur.fetchone()]
        cur.execute("""
            SELECT count(*),coalesce(sum(amount_kopecks),0)
            FROM mosaic_daily_debits WHERE debit_date=(now() AT TIME ZONE 'Europe/Moscow')::date
        """)
        debits_today, debit_amount_today = [int(v or 0) for v in cur.fetchone()]
        cur.execute("""
            SELECT coalesce(sum(amount_kopecks) FILTER (WHERE kind='bonus' AND created_at >= now()-interval '7 days'),0),
                   count(*) FILTER (WHERE kind='bonus' AND created_at >= now()-interval '7 days')
            FROM mosaic_ledger
        """)
        bonus_7d, bonus_events_7d = [int(v or 0) for v in cur.fetchone()]
        cur.execute("""
            SELECT kind,count(*) FROM mosaic_sessions
            WHERE revoked_at IS NULL AND expires_at>now() GROUP BY kind
        """)
        sessions = {row[0]: int(row[1]) for row in cur.fetchall()}
        cur.execute("SELECT count(*) FILTER (WHERE revoked_at IS NULL),count(*) FILTER (WHERE last_seen_at >= now()-interval '24 hours') FROM mosaic_devices")
        devices_total, devices_seen_24h = [int(v or 0) for v in cur.fetchone()]
        cur.execute("SELECT count(*),count(*) FILTER (WHERE checked_at >= now()-interval '7 days') FROM mosaic_trial_claims")
        trial_claims, trial_claims_7d = [int(v or 0) for v in cur.fetchone()]
        cur.execute("SELECT count(*) FILTER (WHERE enabled),count(*) FROM mosaic_groups")
        groups_enabled, groups_total = [int(v or 0) for v in cur.fetchone()]
        cur.execute("""
            SELECT count(*) FILTER (WHERE enabled),
                   count(*) FILTER (WHERE enabled AND proxy_ok=true),
                   count(*) FILTER (WHERE enabled AND last_checked_at >= now()-interval '2 hours'),
                   count(*) FILTER (WHERE enabled AND coalesce(last_checked_at,now()-interval '100 years') < now()-interval '2 hours'),
                   coalesce(round(avg(latency_ms) FILTER (WHERE enabled AND proxy_ok=true)),0),
                   coalesce(round(avg(speed_mbps) FILTER (WHERE enabled AND proxy_ok=true)),0)
            FROM mosaic_nodes
        """)
        nodes_enabled, nodes_healthy, nodes_checked_2h, nodes_stale, avg_latency_ms, avg_speed_mbps = [int(v or 0) for v in cur.fetchone()]
        cur.execute("SELECT count(*) FROM mosaic_announcements WHERE active=true")
        announcements = int(cur.fetchone()[0] or 0)
        cur.execute("SELECT count(*) FROM mosaic_subscription_link_rotations WHERE created_at >= now()-interval '30 days'")
        link_rotations_30d = int(cur.fetchone()[0] or 0)
        cur.execute("SELECT count(*) FROM mosaic_admin_audit WHERE created_at >= now()-interval '7 days'")
        admin_actions_7d = int(cur.fetchone()[0] or 0)
    return {
        'accounts': accounts, 'active_accounts': active, 'frozen_accounts': frozen, 'insufficient_funds_accounts': insufficient,
        'registered_24h': registered_24h, 'registered_7d': registered_7d, 'trial_active_accounts': trial_active,
        'prepaid_balance_kopecks': prepaid, 'paid_payments': paid, 'pending_payments': pending,
        'payments_24h_kopecks': payments_24h, 'payments_7d_kopecks': payments_7d,
        'debits_today': debits_today, 'debit_amount_today_kopecks': debit_amount_today,
        'bonus_7d_kopecks': bonus_7d, 'bonus_events_7d': bonus_events_7d,
        'sessions': sessions, 'devices_total': devices_total, 'devices_seen_24h': devices_seen_24h,
        'trial_claims': trial_claims, 'trial_claims_7d': trial_claims_7d,
        'groups_enabled': groups_enabled, 'groups_total': groups_total,
        'nodes_enabled': nodes_enabled, 'nodes_healthy': nodes_healthy, 'nodes_checked_2h': nodes_checked_2h,
        'nodes_stale': nodes_stale, 'avg_latency_ms': avg_latency_ms, 'avg_speed_mbps': avg_speed_mbps,
        'active_announcements': announcements, 'link_rotations_30d': link_rotations_30d,
        'admin_actions_7d': admin_actions_7d, 'settings': service_settings(), 'trial_channels': trial_channels(),
    }


def bulk_grant_preview(days):
    days = int(days)
    if days < 1 or days > 365:
        raise ValueError('days must be between 1 and 365')
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("SELECT count(*) FROM mosaic_accounts")
        recipients = int(cur.fetchone()[0])
    amount = daily_price_kopecks() * days
    return {'recipients': recipients, 'days': days, 'amount_kopecks_per_account': amount,
            'total_kopecks': amount * recipients}


TRIAL_CHANNEL_RE = __import__('re').compile(r'^@[A-Za-z0-9_]{5,64}$')

def _normalize_trial_channel(value):
    username = str(value or '').strip()
    if username and not username.startswith('@'):
        username = '@' + username
    if not TRIAL_CHANNEL_RE.fullmatch(username):
        raise ValueError('channel must be a public Telegram username, e.g. @llm_hubs')
    return username.lower()


def trial_channels(include_disabled=False):
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        if include_disabled:
            cur.execute("SELECT username,enabled,position,updated_at FROM mosaic_trial_channels ORDER BY position,username")
        else:
            cur.execute("SELECT username,enabled,position,updated_at FROM mosaic_trial_channels WHERE enabled=true ORDER BY position,username")
        rows = cur.fetchall()
    return [{'username': row[0], 'enabled': bool(row[1]), 'position': int(row[2]),
             'updated_at': row[3].isoformat() if row[3] else None} for row in rows]


def update_trial_channels(actor_account_id, values):
    if not isinstance(values, list):
        raise ValueError('channels must be a list')
    normalized = []
    for value in values:
        channel = _normalize_trial_channel(value)
        if channel not in normalized:
            normalized.append(channel)
    if not normalized:
        raise ValueError('at least one mandatory trial channel is required')
    if len(normalized) > 10:
        raise ValueError('no more than 10 mandatory trial channels are allowed')
    with db() as conn, conn.cursor() as cur:
        _ensure_admin_schema(cur)
        cur.execute("UPDATE mosaic_trial_channels SET enabled=false,updated_at=now()")
        for position, username in enumerate(normalized):
            cur.execute("""
                INSERT INTO mosaic_trial_channels(username,enabled,position,created_by,updated_at)
                VALUES(%s,true,%s,%s,now())
                ON CONFLICT(username) DO UPDATE SET enabled=true,position=excluded.position,updated_at=now()
            """, (username, position, actor_account_id))
        cur.execute("INSERT INTO mosaic_admin_audit(actor_account_id,action,metadata) VALUES(%s,%s,%s)",
                    (actor_account_id, 'trial_channels_updated', Json({'channels': normalized, 'count': len(normalized)})))
    return trial_channels(include_disabled=True)


def trial_channel_fingerprint(channels=None):
    values = channels if channels is not None else [row['username'] for row in trial_channels()]
    return ','.join(sorted(str(value) for value in values))
