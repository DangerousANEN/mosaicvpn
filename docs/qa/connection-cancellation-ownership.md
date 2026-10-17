# Connection cancellation ownership: corrective verification

## Scope

Corrective client patch after v0.3.76. No payment/backend/provider configuration changes, no release tag or published APK replaced by this patch.

The selector's cancel-epoch fix did not by itself protect the dashboard or Android startup pipeline. Cancelling request A and starting request B could let A's late completion clear B's busy/route state, persist a cancelled route, or display a stale failure. On Android, permission/config validation could finish after disconnect and still invoke native `start`. The phone compass was disabled while busy instead of offering cancellation.

## Changes

- Dashboard attempt generation guards async continuations, persistence, notices, runtime-controller startup and `finally` cleanup.
- A tracked/coalesced teardown future prevents retry from starting before disconnect completes. A failed stop remains a visible failure and a subsequent retry must successfully stop first.
- The phone compass stays actionable during a pending connection, with accessible cancellation semantics and a visible cancellation instruction. Phone and desktop both show local pending work before the daemon's first connecting status.
- Android connect/disconnect generations propagate through group selection, permission, validation and native startup readiness. Cancellation is checked before native `start` and before committing the active route.
- Progress/hint timeout handles are owned and cancelled on widget disposal.
- Cancel button foreground/background are explicit and readable in the actual Atlas light/dark themes.
- The previous cancellation widget test now targets the actual compass and asserts a connect call and absence of an error notice, instead of tapping an arbitrary first gesture detector.
- Native Linux smoke testing exposed a separate blank-dashboard failure after Configure later without a daemon. The live subscription fallback dereferenced `AsyncError.value`; switching to `valueOrNull` now preserves cached routes or safely returns an empty list. Three regression tests cover daemon failure with cache, simultaneous daemon/cache failure, and authoritative empty live lists without resurrecting deleted cache entries.

## Behavioral RED evidence

New tests were executed against unmodified v0.3.76 sources in an isolated Ubuntu container. Observed failures included:

- New attempt expected `connectingRouteProvider == route-a`, but a cancelled request's completion changed it to null.
- Retry before delayed disconnect expected one connect request, but two were observed.
- A late failure from a cancelled request displayed a SnackBar.
- Completion after widget disposal accessed `ref` on the disposed widget.
- The phone compass had no usable cancellation action.
- Native permission/config-validation completion after disconnect returned success rather than cancellation and allowed native startup.

These were assertion/runtime failures, not merely missing API compilation errors. Environment/setup compilation issues were corrected before evaluating behavior.

## Verification

Sandbox: Ubuntu 24.04, Flutter 3.47.7 / Dart 3.13.5, bounded Docker container. No tests ran on the user's desktop.

```text
flutter analyze lib
No issues found!

flutter test --concurrency=2 --exclude-tags 'integration || visual'
401 tests passed

flutter test --concurrency=1 \
  test/features/dashboard_connect_ownership_test.dart \
  test/features/connect_cancel_feedback_test.dart \
  test/android_cancel_pipeline_test.dart
13 tests passed

flutter test --concurrency=1 test/android_group_connection_boundary_test.dart
8 tests passed (explicitly mocked MethodChannel/feed boundaries)

flutter test --update-goldens --tags visual --concurrency=1 \
  test/features/dashboard_cancellation_visual_test.dart
4 tests passed; pending and cancelled images for phone/desktop, light/dark
```

Real DejaVu fonts and MaterialIcons were explicitly loaded in the visual tests. Images were inspected, not inferred from widget text assertions. Initial inspection caught incorrect disconnected wording during local pending work and low-contrast cancellation text; both were corrected and re-rendered. The API in those images is a fixture; its traffic counters are not real VPN measurements.

## Boundaries

- Tests exercise real Flutter handlers and the Android facade with controlled native/API responses. They do not establish device-level Android VPN behavior or end-to-end internet egress.
- No physical Android device or Wi-Fi/LTE transition was tested in this patch.
- Existing mixed-language labels and other unrelated screens are not a claim of fully audited UI.
- A source patch does not retrofit changes into the already published v0.3.76 installers.
