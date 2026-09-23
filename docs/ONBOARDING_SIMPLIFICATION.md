# Simple onboarding delivery

Status: implementation and sandbox verification in progress; not deployed.

## Goal
Two understandable phases, not a false promise of two literal taps: (1) website account and paid or administrator-sponsored access, with NO Telegram prerequisite; (2) install/open MosaicVPN with the same account and subscription. Telegram is optional. OS installation and VPN consent remain explicit. Verify website payment configuration rather than assuming existing code is live.

## Observed gaps
- Landing CTA opens a generic bot menu. Cabinet's default Telegram login requires /link and copying eight characters.
- Bot splits installing and adding an account across OS menus and separate client choices.
- Enrollment codes expire after 120 seconds; downloading/installing can outlast them. The callback page cannot renew without authenticated context.
- Admin credit requires account ID. There is no sponsored, single-use invitation whose claimant identifies themselves in Telegram.
- Existing client enrollment imports account/profile; this must remain durable and account-safe, not be replaced with raw subscription clipboard hacks.

## Chosen design and acceptance gates
1. Server-backed browser Telegram sign-in challenge: public start ID and private polling secret are distinct. Telegram owner explicitly confirms a request (login-CSRF prevention), one browser can consume it once; expiration/rate limits enforced. No durable sessions in URLs.
2. `/setup.html` is the simple website/bot entry: choose platform automatically with explicit override, login without copying, show access/payment status, install verified release, issue enrollment only on opening the installed app. Preserve non-secret progress and browser session. A return from payment is not proof of payment; profile is re-read.
3. Administrator creates a capped, expiring, one-person sponsored invitation with a label and amount. Friend claims via authenticated Telegram; notification identifies claimant and links an admin action. Redemption is atomic and auditable; double clicks/retries cannot double-credit or bind a different account. Uncertain provider writes must not be blindly retried.
4. Existing users can be found by Telegram handle/name in admin-only UI; disambiguate with identity card before explicit credit confirmation. IDs remain internal.
5. Client completion puts a successfully persisted account and profile on the connection screen, without duplicate prompts/manual import. Do not silently replace another account or start VPN without system consent. Test interrupted exchange/save, expired tokens, duplicates and existing profiles.
6. Sandbox gates: real HTTP handler + SQLite tests; browser desktop/mobile journeys, network failure and payment pending; Flutter enrollment and first-run regressions, build/analyze. External providers may use named test doubles, never described as live proof.

## Platform boundaries
Verified links do not guarantee deferred account handoff through a fresh APK/desktop install. Supported recovery is return to the authenticated setup page or Telegram and tap Open; no device fingerprinting or clipboard credential collection. Apple download/install paths must reflect actual available signed artifacts, not promised releases.

## Production boundary
No production config, billing credit, user messages or deployment until the integrated change passes the sandbox gates. Test gifts and payment fixtures never credit real users.
