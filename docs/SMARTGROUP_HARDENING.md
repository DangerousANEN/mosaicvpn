# Smart-group reliability delivery

## Scope and acceptance
Public feeds -> safe normalized candidates -> bounded protocol/HTTPS verification -> database memberships -> device-local policy selection -> truthful connection UI.

Acceptance gates:
- Unknown/not-tested never becomes failure or success; UDP-only transports are not rejected by a TCP-only admission test.
- HTTPS probes validate certificates, expected status/body, and route through the candidate; timings represent remote HTTP, not the loopback SOCKS connection.
- Every collector budget is a hard ceiling; source fetch bytes/concurrency, proxy processes, runtime and download bytes are bounded.
- Existing verified candidates are refreshed before expiry, discovery rotates, and country/policy deficits receive priority without inventing healthy counts.
- Canonical identity ignores display tags; unsafe private/local/own-infrastructure endpoints and unsafe imported routing fields are rejected.
- Pool replacement is transactional, restricted to managed groups, and config replacement is validated with rollback and a shared lock.
- Device ranking honors policy and network-specific freshness; failed/unverified candidates cannot win, and speed experiments do not unexpectedly replace an active connection.
- Reconnection has cancellation, hysteresis/cooldowns, and truthful verifying/recovering UI; no success solely on TUN startup.
- All application tests run in Developer-sandbox. Publish only after regression and real E2E evidence; record untested native platforms explicitly.

## Observed baseline (live read-only audit)
- VPS: sing-box 1.13.13; memory 3868 MiB total, 1939 MiB available; root 85% used, 3615 MiB available at sample.
- Database: 10788 nodes, 1178 enabled/proxy_ok, only 103 with last_checked_at within six hours. Counts are database flags, not independently reverified working nodes.
- Collector: up to 500 TCP candidates, configured HTTP budget 80, 48 TCP workers; existing quota logic can exceed both candidate budgets.
- Health systemd unit unconditionally restarts sing-box-pool after each run.

## Confirmed code defects to remove
- Collector stores curl time_connect to loopback as remote latency and substitutes an invented 0.5 Mbps for failed throughput.
- ICMP loss calculation inverted.
- Untested candidates have proxy_ok=None but upsert advances failure counters; non-full run marks all failed.
- Selection takes feed prefixes each run, lacks persisted candidate rotation and verified-reserve refresh.
- Group rebuild deletes memberships of every enabled group, including groups it does not rebuild.
- Bot fabricates stable availability using other policies and a default count of 20.
- Client selector cache lacks network scope; probe call omits policy arguments; speed selection changes live connections.

## Continuation verification and boundaries
- Scheduler limits overdue refresh to 70% when other eligible candidates exist; remaining overdue entries cannot re-enter discovery tiers. Unused capacity is backfilled, so limits are not wasted.
- Country quorum excludes expired verification, stale feed sightings, failure history and active cooldown. This is scheduling evidence, not a guarantee that public sources contain enough working nodes.
- Integrated sandbox Python run: 133 tests passed across collector, health, scheduler, route availability and URI parsing.
- Sandbox Go: full suite, vet, API/pool/store race checks and daemon/CLI builds passed.
- Sandbox Flutter: 164 non-visual tests passed; targeted selector/monitor/API analysis passed; release web build passed.
- Browser smoke: release web served HTTP 200 and onboarding/skip/navigation rendered in sandbox Chromium, with no horizontal overflow at widths 1440 and 390. Two `VPN runtime is unavailable` errors occur after skip because the native daemon is not connected. This is not a clean runtime E2E result and does not prove native VPN traffic or candidate selection.
- Visual regression remains open: existing `mobile advanced tools` golden differs by 2086 pixels (0.63%). Its screen, test and golden are unchanged against HEAD; reference was NOT overwritten. Other mobile goldens passed. No claim of a completely clean visual suite.
- This continuation is local code only: no VPS deployment, no client release, no measured production pool or CPU improvement.

## Current continuation: measured probe accounting
- Reproduced a Go regression: policy-rejected and pre-cancelled probes reported 20 failed samples without sending any request.
- `CandidateProbeResult.samples` now counts attempted HTTP requests only; cancellation is checked before configuration/process setup.
- An interrupted/incomplete sweep cannot be successful; loss uses actual attempted requests, while zero attempts remains ineligible.
- Sandbox evidence: full `go test ./...`, `go vet ./...`, `go build ./cmd/mosaic ./cmd/mosaicd`, and race checks for API/pool/store passed. Real local TLS + authenticated SOCKS fixture tests cover bad credentials, HTTP 200, redirects and untrusted certificates; they do not prove public-node availability.
- Known platform gap: Android returns `unverified_android_candidate` with zero samples because no isolated native candidate runtime exists. Do not describe device-level Android candidate selection as complete.
- No production deployment or live pool-capacity claim is part of this verification.

## Status
- Collector/scheduler integration is implemented; isolated regression checks have passed. This does not establish live public-node availability or complete platform/network E2E. Additional integrated verification remains in progress.
- Persisted scheduler state (`pool_scheduler_state.json`) loaded and saved atomically across collector runs.
- Three-tier scheduling active in `bot/mosaic_pool_collector.py`:
  1. Overdue verified node refresh before TTL expiry.
  2. Country deficit priority matching target group allocations.
  3. Fair EWMA-weighted source rotation with anti-starvation.
- Strict CLI budget compliance: `--limit` and `--probe-limit` are hard ceilings.
- Truthful telemetry: source yield and failure counters advance solely on real proxy checks; untested nodes (`proxy_ok=None`) preserve state without penalty.
- Sandbox verification passed in `Developer-sandbox` under isolated `/tmp`. No production deployment or secrets exposure.

