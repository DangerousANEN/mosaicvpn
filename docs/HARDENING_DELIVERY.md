# Ecosystem hardening delivery

## Scope and verification contract
User authorized implementation across backups, bot, clients, website and documentation. Google Drive authorization is deferred until the final stage. No production payment or personal Google data operations during sandbox tests.

Baseline: dfad3f1. Implementation and verification status below are intentionally distinct. No recovery time or platform leak-protection guarantee without an executed rehearsal.

## Acceptance matrix
- [ ] Full encrypted PostgreSQL + consistent SQLite + explicit configuration backup; secrets excluded from Git.
- [ ] Safe restore rejects corruption and SQL failures, stops actual writers, rehearsal in Ubuntu sandbox.
- [ ] Off-host destination prepared; Google Drive upload/download and integrity check after authorization.
- [ ] Legal links, versioned pre-purchase acceptance, payment support and refund request UX.
- [ ] Payment reconciliation and duplicate notification tests; transparent transaction status.
- [ ] Stars implementation/policy gate reviewed without silently changing live prices or stranding existing invoices.
- [ ] Client sanitized diagnostic export and connection/reconnection failure tests.
- [ ] Platform E2E coverage explicitly distinguished from unit coverage.
- [ ] SEO report uses measured fields, timestamps and unknown values for unavailable external data.
- [ ] Useful current-feature user documentation and privacy-preserving status/telemetry.
- [ ] Sandbox regression and frontend interaction/screenshot evidence.
- [ ] Production rollout with pre-change snapshot and read-back health verification.
- [ ] Git diff reviewed and published without secrets.

## Safety boundaries
- No destructive production restoration drills.
- Do not expose subscription links, authentication secrets, traffic destinations or private account analytics.
- Do not launch UI on the user's host desktop.
- Google Drive remote retention must stay inside a dedicated backup directory; never sync/delete unrelated files.
- Live payment changes that need pricing decisions remain gated, with the precise blocker documented.

## Current verified state
- Encrypted backup deployed; systemd reported Result=success and ExecMainStatus=0. Google Drive is not configured; last-success explicitly records offsite_verified=false.
- Production archive `mosaic_full_20260912T034659436230Z.tar.gz.age` was downloaded, hash-matched, decrypted and restored only into the Ubuntu sandbox. Verification found 45 payload files; restored/source counts matched: users=22, mosaic_accounts=7, web_credentials=5, telegram_account_links=0; SQLite integrity_check=ok. These are point-in-time checks, not continuous monitoring.
- Parent reran all 17 encrypted-backup regressions in Developer-sandbox as postgres: real PostgreSQL/SQLite round-trip, corrupt archive/wrong key rejection, Certbot symlink reconstruction, lock contention and scoped local-rclone retention passed. This does not establish external Google Drive authorization or certificate renewal.
- Parent reproduced a raw-log clipboard disclosure with a failing Flutter widget test, implemented shared export redaction, and reran 7 redaction/diagnostics tests successfully. Copy and file export use the same sanitizer; arbitrary free text and device visual QA remain separate boundaries.
- Pool-health changes remain undeployed. Parent reran current 23 regression tests successfully in Developer-sandbox; TCP accept and generic UDP response cannot reactivate nodes or reset failures. These tests explicitly use JSON-only validation where sing-box is unavailable. Authenticated recovery and real engine validation remain open.
- Site changes remain undeployed. Parent reran Playwright on five pages at 375px and 1280px; DOM interactions, horizontal overflow and console assertions passed. IndexNow remains ready, not submitted; internal audit score is not search-ranking evidence.
- Parent reran 15 targeted Flutter tests and Go api/state/proto tests successfully. Real-engine tests previously skipped, full analysis, device network E2E and visual client QA remain open.
- Scheduler integration, authenticated health recovery and real-engine verification are actively assigned in separate non-overlapping workstreams. Their completion is not parent delivery completion.
- IndexNow helper: 7 sandbox regressions pass. Follow-up read-only probes returned Cloudflare HTTP 502 both directly and through configured proxy for the key. Origin nginx container is running and syntax-valid; origin homepage returns 200. The key file is absent and its exact static location is missing, so requests enter the subscription upstream. `deploy/nginx-indexnow.conf` supplies the narrow exact route; parent tested real isolated nginx: syntax pass, exact key/content/type HTTP 200, unrelated route unchanged. Not deployed; no IndexNow submission attempted.
- Parent reran 15 bot legal/schema/callback regressions in Developer-sandbox with isolated SQLite and mocked providers: pass. These do not establish external payment settlement; broader invoice/idempotency regression review continues.
- Android candidate probing no longer credits direct host HTTP or TCP connectivity to a candidate. Native isolated candidate runtime is not implemented: results explicitly remain unverified with zero samples. Parent Android/redaction suite: 9 pass. This safety correction does NOT satisfy Android candidate-selection functionality or native E2E release acceptance.
- Parent ran Go isolated-engine local VLESS WebSocket cases (204 success, wrong credentials, non-204 rejection) and real state configuration/mux regressions with sing-box. Additional certificate/proxy-environment/timeout review continues. Local fixtures are not public pool availability.
- Bot/legal/payment and cloud-backup acceptance remain open. No production rollout or platform network E2E completion is claimed.
