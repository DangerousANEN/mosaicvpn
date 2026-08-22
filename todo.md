# MosaicVPN Client — next account controls

Client code is deliberately unchanged in the current iteration. The user asked to stabilise the Telegram-bot presentation first.

| Priority | Item | Acceptance criterion |
| --- | --- | --- |
| P1 | Show shared account state | The linked-account screen reads `status`, balance and billing rate from the unified account API with a client session token. |
| P1 | Pause and resume access | The client calls authenticated freeze/unfreeze endpoints; the UI refreshes the profile and renders insufficient-funds feedback without exposing tokens. |
| P1 | Provider-neutral top-up | The client obtains available providers from checkout options, asks for a RUB amount between 10 and 365, opens the returned hosted payment URL and refreshes invoice state. |
| P2 | Lava.ru / SBP adapter | Enable it only after server credentials, webhook validation and reconciliation tests are configured; no client UI redesign should be required. |
| P2 | End-to-end checks | Verify Telegram, website and client show one balance and one access state; test active, frozen and insufficient-funds paths. |

No legacy relay route should be changed as part of these client tasks.


## Subscription-link security

| Priority | Item | Acceptance criterion |
| --- | --- | --- |
| P1 | Show and copy current subscription link | A linked user can copy the current account-bound link without exposing it in diagnostics or logs. |
| P1 | Rotate exposed link | After an explicit confirmation, the client calls the authenticated rotation endpoint, replaces the displayed URL, and explains that the old link and connection credentials stopped working. |
| P2 | Recovery UX | The import flow offers the new link immediately after rotation and displays the server cooldown response without retry loops. |


## Android and mobile recovery — P0 before next public APK

> The current Android APK is a technical preview only. It falls back to `MockDaemonApi` because Android cannot discover or launch the desktop `mosaicd` process; `MainActivity` has no `VpnService`. Do not label an Android build as a working system tunnel until every P0 acceptance criterion below passes.

| Priority | Item | Dependencies | Acceptance criterion |
| --- | --- | --- | --- |
| P0 | Remove release-mode `MockDaemonApi` fallback on Android | Mobile backend client | If the backend is unavailable, Android shows an explicit unavailable/unlinked state; it never renders synthetic username, Telegram ID, balance, traffic, payment, server, group, event or connection data. |
| P0 | Add mobile HTTPS account client | Auth API contract | Android signs in with the existing 8-character Telegram pairing code or email/password and receives the same unified account as website and bot. |
| P0 | Persist mobile session securely | Android encrypted storage | Session survives relaunch, refreshes safely and is removed on logout; tokens are never logged or committed. |
| P0 | Fetch authenticated subscription manifest | Unified account and manifest endpoints | Only groups/tiers available to the linked account are rendered; stale/offline manifest state is explicit. |
| P0 | Replace Android account UI states | Mobile auth client | Account has truthful loading, unlinked, active, frozen, expired, insufficient-funds and server-error states; no `mock_user` or sample usage remains. |
| P0 | Decide Android native runtime and licence route | Owner approval | Either approve GPL-compliant libbox distribution with notices/source obligations, or select a separately licensed Android runtime. Do not copy GPL code or ship an unreviewed binary. |
| P0 | Implement Android `VpnService` | Approved runtime | Service is declared with `BIND_VPN_SERVICE`, foreground lifecycle and notification; Android displays system VPN consent only after user action. |
| P0 | Add Flutter ↔ Android tunnel bridge | `VpnService` | `prepare`, `start`, `stop` and `status` MethodChannel commands plus EventChannel states accurately represent the native service. |
| P0 | Implement real tunnel lifecycle | `VpnService`, account manifest | Connect, permission denial, reconnect, network change, revoke, explicit stop and service recreation never produce a false Connected state. |
| P0 | Physical-device Android acceptance | Signed APK and test account | System VPN indicator/notification appears; browser traffic follows a permitted group; disconnect/revoke clear system state and UI state. |
| P1 | Replace mobile route selector | Live manifest | One selected group and one persistent connection CTA; no repeated giant “Autoconnect” buttons. |
| P1 | Hide desktop-only engineering pages on Android | Capability registry | Egresses, per-port local proxy listeners, process connection tables, raw logs and cores are unavailable on Android until a mobile-specific implementation exists. |
| P1 | Repair 320–412 dp mobile layouts | Widget tests | No vertically wrapped labels, clipped Action columns, overflowing segmented controls or unsafe status/navigation-bar overlap in light/dark RU/EN modes. |
| P1 | Replace mobile routing editor | Capability registry | Use a one-column mode selector and a desktop handoff until a dedicated mobile editor is designed; no horizontal overflow. |
| P1 | Make stats/activity truthful | Live tunnel counters | Empty state is shown before native counters exist; no fake charts, fake hosts, fake processes or sample connections. |
| P1 | Complete localization in technical/account UI | `AppStrings` | RU/EN selection changes every visible account, routes and technical label; no mixed-language cards remain. |
| P1 | Add Android test matrix | Native bridge and auth | Unit, widget and instrumentation coverage includes auth expiry, 320/360/412 dp layouts, permission accept/deny, lifecycle, theme and locale. |
| P2 | Add mobile diagnostics | Stable tunnel runtime | A compact, privacy-safe connection summary replaces desktop raw process/flow tables. |
| P2 | Publish production Android APK | All P0/P1 completed | Release notes, website status and APK behaviour agree; source/licence notices and signing/rollback process are verified. |

Detailed design, constraints and physical-device test matrix: [`docs/ANDROID_MOBILE_RECOVERY_PLAN.md`](./docs/ANDROID_MOBILE_RECOVERY_PLAN.md).

## Windows and Linux follow-up

| Priority | Item | Acceptance criterion |
| --- | --- | --- |
| P1 | Smoke-test Windows Setup and Portable on a clean Windows device | Install/update/uninstall, start tunnel, reconnect and account session flow work without relying on development paths. |
| P1 | Smoke-test Linux DEB and Portable on clean supported distributions | Installer, desktop launcher, daemon/runtime discovery, tunnel lifecycle and removal work on Ubuntu/Debian. |
| P2 | Add release artifact signing and update verification | Windows/Linux user experience explains unsigned state until code signing is configured; release checksums and verification instructions are present for each artifact. |

No mock/demo state may be presented in any public release as real account, billing, traffic, route or VPN status.
