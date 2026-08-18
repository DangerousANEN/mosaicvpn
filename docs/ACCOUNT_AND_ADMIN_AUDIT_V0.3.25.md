# Account and Admin Audit for v0.3.25

## Current account surface

The deployed system has a Telegram-ID keyed `users` table, one-time pairing codes, 30-day web sessions and opaque browser-to-app authorization codes. The web cabinet currently authenticates only by a pairing code. The Flutter client retains an older `loginWithEmail` entry point, but the hosted backend does not provide a production-ready password credential schema, registration route, recovery workflow or email verification channel.

## Required account design

Password credentials must be stored separately from the existing Telegram profile. The new schema must use a unique normalized email, an Argon2id password hash, a password-version counter and verified-email timestamp. Recovery tokens must be random, opaque, single-use, short-lived and stored only as SHA-256 digests. A password change must revoke all existing web sessions and pending pairing/app authorization material for that account.

The system cannot safely claim email recovery until it has a configured outbound email delivery path. The implementation will therefore use a controlled fallback: password reset starts with a one-time code delivered to the linked Telegram account; email links will be enabled only after a verified mail transport is configured. This preserves the requested recovery capability without creating a false or insecure delivery promise.

## Current admin surface

The website admin panel already has server-side administrator checks, a confirmed idempotent individual balance-credit operation and an audit history. The Telegram bot contains a legacy `/broadcast` command and package constants, but the web admin UI currently does not expose broadcast composition, per-day price changes or safe bulk credit operations.

## Required guardrails

| Operation | Required safeguard |
|---|---|
| Broadcast | Draft, recipient count preview, explicit confirmation code, rate limit, persistent audit record and delivery summary. |
| Price update | Value bounds, effective-at time, explicit confirmation, audit record; no retroactive recalculation of already created payments. |
| Bulk balance credit | Recipient filter preview, total impact preview, explicit confirmation code, stable idempotency request ID, per-user audit rows and partial-failure report. |
| Password recovery | Hashed one-time token, 15-minute expiry, rate limit, session revocation after reset and no account enumeration. |

## Scope order

1. Add secure credential and recovery persistence, with backend routes that do not reveal whether an email exists.
2. Add a compact register/login/recovery experience to the website; preserve Telegram code login as a parallel route.
3. Restore admin capabilities on the site only through preview-and-confirm operations and persistent audit records.
4. Add regression coverage, validate the bot service and client builds, release, then deploy the website and bot together.
