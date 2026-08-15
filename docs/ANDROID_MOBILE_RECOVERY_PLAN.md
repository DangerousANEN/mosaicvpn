# MosaicVPN Android and Mobile Recovery Plan

**Status:** proposed recovery backlog before further public Android releases.

## 1. Confirmed diagnosis

The current Android APK is a branded Flutter shell, not a production Android VPN client. The screenshot behaviour is explained by three confirmed implementation facts.

| Area | Confirmed cause | User-visible result | Severity |
|---|---|---|---|
| Account and subscription | `vpn_providers.dart` resolves a desktop lockfile and attempts to launch the external `mosaicd` executable. Android has neither the lockfile nor a bundled executable, so the provider falls back to `MockDaemonApi`. | `mock_user`, a synthetic Telegram ID, sample traffic and non-real payment history. | P0 |
| Tunnel activation | Android `MainActivity` is an empty `FlutterActivity`; the manifest contains no `VpnService`, no TUN implementation, no foreground VPN service and no Flutter native channel. | The Android system never displays a VPN permission request and no system tunnel can start. | P0 |
| Groups and routes | The connection dashboard exposes static fallback groups if a live route manifest is absent. | Cards look selectable but do not represent an authenticated user subscription. | P0 |
| Technical screens | Activity, statistics, egresses and routing reuse desktop-oriented layouts and are populated through the same mock backend. | Demonstration rows, false traffic/chart values, clipped columns and unusable controls. | P0 |
| Localization | Several technical and account labels are hard-coded in English and bypass `AppStrings`. | Mixed Russian/English interface despite the RU selector. | P1 |
| Mobile composition | Desktop density and fixed-width `Row`/table patterns were exposed through mobile navigation. | Vertical letter wrapping, clipped “Action” column, oversized charts, overflowing mode selector and repeated giant primary buttons. | P1 |

> **Immediate product rule:** Until the tunnel implementation passes on-device verification, Android must remain labelled *Technical Preview*. It must not present simulated account, traffic, active-flow or connected states as real service data.

## 2. Release containment

Before adding features, the next Android update will make the preview honest and safe.

1. Remove `MockDaemonApi` as a release fallback on Android. An unavailable account or tunnel backend must render an explicit unavailable/unlinked state with a retry action; it must never synthesize an account, payment, server, usage, event or connection.
2. Gate desktop-only engineering pages behind a desktop capability flag. Egresses, local listener ports, live process connections, raw daemon logs, cores and per-port proxy controls will not be presented as Android functionality.
3. Replace the mobile “Routes” tab with the account-provided route-group selector. The screen will use live group cards, one selected state and one connection action instead of one large action per card.
4. Change the Android download note and in-app onboarding to state the precise preview limitation until the native tunnel passes acceptance tests.

## 3. Account, entitlement and subscription data

Android must read the same server-side account as Telegram and the web cabinet. It must not depend on a desktop loopback daemon.

| Work item | Implementation | Acceptance criterion |
|---|---|---|
| Mobile auth client | Create a mobile API client configured for the Mosaic account service over HTTPS. It will use the existing 8-character Telegram pairing code and email/password flow, plus token refresh and logout. | A user can link once, close the app, reopen it and see the same account ID, balance, billing rate, freeze state and entitlement as on the website. |
| Secure session storage | Store session/refresh credentials only through Android encrypted secure storage. Never log or embed them into screenshots, diagnostics or release configuration. | Fresh install, relaunch, logout and expired-token paths are covered by unit tests and a device test. |
| Unified account provider | Replace the Android `MockDaemonApi` account path with `GET /me`, billing, payment history and current subscription-link endpoints authenticated with the mobile session. | `mock_user`, placeholder Telegram ID and sample traffic cannot appear in a release build. |
| Subscription manifest | Fetch the authenticated smart-group manifest and health metadata from the account service. Cache its last valid version with an expiry and show an explicit offline state when stale. | The same groups, access tier and disabled/expired status appear in client, website and bot for one test account. |
| Entitlement guard | Disable connection actions when access is frozen, expired or out of funds, and present the existing billing/freeze actions instead of a simulated connection. | Attempts are blocked locally with an actionable explanation; server-side entitlement remains authoritative. |

## 4. Android native tunnel implementation

### 4.1 Required design

Android does not allow a Flutter desktop process model to create a system tunnel. The client needs an Android-native `VpnService` with a foreground-service lifecycle and a native runtime that accepts the account-selected configuration.

The implementation must include the following pieces.

1. A Kotlin `MosaicVpnService` declared with `android.permission.BIND_VPN_SERVICE`, the required foreground-service permissions and Android-compatible notification metadata.
2. A Flutter `MethodChannel` for commands (`prepare`, `start`, `stop`, `status`) and an `EventChannel` for state transitions, fatal errors and byte counters. Flutter remains the interface layer; Kotlin owns the Android lifecycle.
3. A one-time system consent flow through `VpnService.prepare`. The app may only show **Connected** after the VPN permission, TUN descriptor and runtime start operation all succeed.
4. A runtime adapter that turns the authenticated smart-group selection into a local tunnel configuration. It must handle reconnect, active network changes, service recreation, `onRevoke`, explicit disconnect and crash-safe cleanup.
5. TUN configuration for IPv4/IPv6, DNS, allowed routes and application policy. The initial release will use an explicit, documented route policy rather than silently changing device traffic.
6. A foreground notification and persistent connection state so Android does not terminate an active tunnel as a background task.

### 4.2 Runtime and licence decision

The currently researched `sing-box/libbox` Android route is GPLv3-or-later. Before it is linked into MosaicVPN, the project owner must choose one of two compliant paths.

| Option | Consequence | Required decision before implementation |
|---|---|---|
| GPL-compliant Android client | Publish corresponding client source, notices and license terms for the combined Android work; preserve source availability for the released APK. | Approve GPLv3-or-later distribution for the Android client and add the required notices/source-offer process. |
| Alternative approved runtime | Use a runtime whose licence and Android API satisfy the business distribution model. | Select and validate the runtime; no borrowed GPL source or binary is allowed until then. |

The implementation cannot safely proceed by copying code from another Android client or by presenting a placeholder `VpnService` that does not carry traffic.

## 5. Mobile UI recovery

The mobile information architecture will remain intentionally small: **Connection**, **Routes**, **Account** and **More**. Desktop engineering functions stay desktop-only unless a mobile-specific purpose is implemented.

| Screenshot area | Repair | Mobile acceptance criterion |
|---|---|---|
| Connection / group cards | Render one-line group title, short localized quality badge and a selected state. Place the connection CTA once in a persistent bottom action area. | Six groups remain comfortably scannable on a 360 dp wide phone without repeated full-width connect controls. |
| Account | Replace synthetic cards with loading, unlinked, authenticated, frozen, expired and API-error states. Localize every label. | No synthetic username, traffic or payment item is displayed in release mode. |
| Statistics | Hide until a live tunnel publishes actual counters. Replace the desktop-height chart with a compact 24-hour chart only when data exists. | Empty state is truthful; labels do not truncate at 360 dp; no one-point fake chart. |
| Activity | Do not expose desktop process/flow tables on Android in the first release. Provide an optional compact “Connection diagnostics” summary later. | No clipped columns, process names or fake hosts appear on phone. |
| Egresses | Remove from Android navigation. Desktop local port listeners are not an Android `VpnService` control surface. | No vertical letter wrapping or 127.0.0.1 proxy controls on Android. |
| Routing | Replace horizontal segmented control and dense rule cards with a one-column mode selector and a “Manage advanced rules on desktop” link until a mobile editor is designed. | Entire control remains within 320–360 dp and is fully localized. |
| Status and safe areas | Use `SafeArea`, compact mobile app bars and status-aware top padding; test with gesture navigation and display cutouts. | Page title is not obscured by the Android status bar or navigation area. |
| Theme and language | Move all remaining account/technical labels to `AppStrings`, use theme palette tokens, and check contrast in light/dark modes. | No mixed RU/EN labels in the selected locale; text meets readable contrast on dark cards. |

## 6. Verification strategy

### Automated checks

1. Unit-test release provider selection: Android never resolves to `MockDaemonApi` in a production flavour.
2. Unit-test auth persistence, expiry and unlinked/frozen/expired account states.
3. Widget-test the 320 dp, 360 dp and 412 dp mobile layouts in light and dark themes, in Russian and English.
4. Add golden snapshots only after the mobile layouts are stable; include routes, account, unavailable tunnel, group selection and settings.
5. Add Android instrumentation tests for permission denial, permission approval, foreground notification, service restart, `onRevoke` and explicit disconnect.

### Physical-device acceptance matrix

| Test | Required result |
|---|---|
| Fresh install and onboarding | User can pair the real account and sees its server-side profile, not a mock. |
| VPN permission | Android permission prompt appears exactly when the user requests a connection. Denial leaves the app disconnected with recovery guidance. |
| Start and traffic | System VPN indicator and foreground notification appear; a real browser traffic check follows the selected group. |
| Network changes | Wi-Fi ↔ mobile data transition reconnects or gives a truthful recoverable state. |
| Stop / revoke | Disconnect removes the VPN state; revocation is reflected in the UI within seconds. |
| Lifecycle | Background/foreground, process recreation and device restart do not claim a connection that no longer exists. |
| Account parity | Client, bot and website agree on balance, frozen state, access end time and subscription rotation outcome. |

## 7. Delivery sequence

1. **P0 containment:** eliminate Android release mocks, hide desktop-only technical pages and correct release/site language.
2. **P0 data integration:** mobile authentication, secure session, real unified account and subscription manifest.
3. **P0 native tunnel:** approve runtime/licence path, implement `VpnService`, foreground lifecycle and actual route configuration.
4. **P1 mobile UI:** replace the affected group/account/routes pages and remove desktop table patterns.
5. **P1 validation:** automated layout tests plus physical-device matrix.
6. **P2 publication:** signed APK, exact release notes, direct site link and rollback instructions only after all P0 tests pass.

## 8. Definition of done for Android production release

Android becomes a public production download only when all conditions below are true.

- It has no mock account, subscription, traffic, activity, route or connection data.
- It authenticates against the unified Mosaic account and observes server-side entitlement.
- It requests Android VPN permission and operates a real `VpnService` tunnel through an approved, licence-compliant runtime.
- It accurately reports connecting, connected, reconnecting, disconnected and error states.
- Account, groups, language, light/dark themes and mobile layouts pass automated and physical-device verification.
- The signed APK, source/licence notices, privacy documentation and release notes match the implemented behaviour.
