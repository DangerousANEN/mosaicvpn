# MosaicVPN: unified accounts, subscriptions, Smart Groups and mobile UX plan

**Status:** proposal for approval before implementation
**Scope:** Android first, then the shared Flutter implementation for Windows, Linux and future iOS builds.
**Security rule:** private physical pool nodes remain invisible to users. A client sees only provider-declared routes, imported nodes from a user-owned external subscription, and local nodes added by that user.

---

## 1. Findings from the current implementation

The present client mixes three different concepts that must be separated: a hosted provider account, a subscription feed, and a route collection. The old desktop-oriented account handlers create a local subscription with the fixed ID `mosaic-direct`, and the Android facade recreates a visible `MosaicVPN · Direct` entry after login. The backend also treats this same fixed ID as the sole source of the global active Smart Group manifest.

That special case is why the UI looks structurally wrong. Smart Groups logically belong to the account/provider subscription that declares them, but the implementation exposes them as an out-of-band global source. At the same time, ordinary imported subscriptions are only local collections. This prevents a consistent account model and makes multi-provider support impossible.

The Android profile is thin because Android intentionally receives a fallback `BillingProfile`, whereas the fuller `UnifiedAccountPanel` is disabled there. The richer component already contains access freeze, subscription-link rotation and checkout redirection, but these actions are not yet routed through a hosted Android account API.

The Android routes screen currently uses a desktop-like table/list model. It has actions in code, but the interaction density is too high for a phone. The technical Logs and Routing tabs are similarly designed around desktop daemon capabilities; Android needs platform-aware equivalents, not a desktop error message.

> **Decision:** account identity, subscription sources and route collections must be first-class and provider-scoped. `mosaic-direct` must be removed as a visible user-facing subscription name and retained only as a migration alias, if needed.

---

## 2. Immediate curl runbook: verify actual subscription parsing

There are two different paths. They must be tested separately.

| Path | Used by | What is parsed | Where parsing happens |
|---|---|---|---|
| Hosted direct feed | Mosaic account on Android | The personal HTTPS subscription feed | Android client locally, then native sing-box config is built |
| Local daemon subscription API | Windows/Linux and advanced diagnostics | Any imported subscription URL | `mosaicd` fetches and parses into local `Subscription` and `Server` records |

### 2.1 Test the hosted Mosaic feed without exposing it publicly

Do **not** paste a personal subscription URL into a public chat, shell history shared with others, screenshots, or issue trackers. On a trusted machine, put it into an environment variable.

```bash
export MOSAIC_SUB_URL='https://sub.zxc1x1.ru/<personal-opaque-id>'

curl --fail-with-body --silent --show-error \
  --location \
  --dump-header /tmp/mosaic-subscription.headers \
  --output /tmp/mosaic-subscription.txt \
  "$MOSAIC_SUB_URL"

head -n 20 /tmp/mosaic-subscription.headers
wc -c /tmp/mosaic-subscription.txt
head -c 120 /tmp/mosaic-subscription.txt; echo
```

Expected result: HTTP `200`, content type `text/plain`, and a non-empty feed. The current Mosaic feed is base64-encoded share URIs. Decode it only on a trusted device:

```bash
base64 --decode /tmp/mosaic-subscription.txt > /tmp/mosaic-subscription.decoded.txt
sed -n '1,5p' /tmp/mosaic-subscription.decoded.txt
```

Expected result: valid lines such as `vless://...`, `trojan://...`, or another supported share URI. Do not send the decoded file because it contains credentials.

### 2.2 Test the desktop/Linux daemon API exactly as Flutter uses it

Start the desktop client once. It writes a local lock file containing the loopback endpoint and Bearer token. Common locations include the portable folder, `%LOCALAPPDATA%\\MosaicVPN\\mosaicd.lock`, `~/.local/share/mosaicvpn/mosaicd.lock`, and `~/.mosaic/daemon.lock`.

The lock file is private; never publish it. Extract the base URL and token according to its JSON fields, then run:

```bash
export MOSAIC_API='http://127.0.0.1:<daemon-port>'
export MOSAIC_TOKEN='<token-from-mosaicd.lock>'
export MOSAIC_SUB_URL='https://sub.zxc1x1.ru/<personal-opaque-id>'

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $MOSAIC_TOKEN" \
  "$MOSAIC_API/v1/status" | jq .

curl --fail-with-body --silent --show-error \
  -X POST "$MOSAIC_API/v1/subscriptions" \
  -H "Authorization: Bearer $MOSAIC_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "$(jq -n --arg url "$MOSAIC_SUB_URL" --arg name 'Parser verification' '{url:$url,name:$name}')" \
  | tee /tmp/mosaic-add-subscription.json | jq .
```

The response is expected to include an `id`, `server_count`, `format`, `last_fetched`, and possibly `last_error`. A successful parsing result has `server_count > 0` and empty `last_error`.

```bash
export MOSAIC_SUB_ID="$(jq -r '.id' /tmp/mosaic-add-subscription.json)"

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $MOSAIC_TOKEN" \
  "$MOSAIC_API/v1/subscriptions" | jq .

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $MOSAIC_TOKEN" \
  "$MOSAIC_API/v1/servers?subscription_id=$MOSAIC_SUB_ID" \
  | jq '[.[] | {id,name,protocol,address,port,subscription_id,last_test_ms,last_test_error}]'
```

To retest a single source after a change:

```bash
curl --fail-with-body --silent --show-error \
  -X POST "$MOSAIC_API/v1/subscriptions/$MOSAIC_SUB_ID/refresh" \
  -H "Authorization: Bearer $MOSAIC_TOKEN" | jq .
```

### 2.3 Interpret parser outcomes

| Observation | Meaning | Correct next action |
|---|---|---|
| `server_count > 0`, `last_error` empty | Feed fetch and parser succeeded | Test a specific imported server through the routes action sheet |
| `server_count = 0`, `last_error` starts with `fetch:` | URL, DNS, TLS, access token or network problem | Check HTTP headers and response body with the hosted feed command |
| `server_count = 0`, `last_error` starts with `parse:` | Unsupported or malformed feed format | Save only the first non-sensitive format markers and extend parser support |
| HTTP `401/403` from hosted provider | Feed authentication/rotation issue | Reissue or re-authorize the provider account; do not alter parser code |
| HTTP `200` but HTML body | URL points to a landing/login page instead of a feed | Use the provider’s actual subscription URL |

The Android path should later gain an **in-app diagnostic export** with these same safe assertions: response status, byte count, detected format, supported row count and unsupported row count — without writing the subscription URI or credentials to logs.

---

## 3. Target architecture: provider account → provider subscription → routes

### 3.1 Canonical model

The user-facing hierarchy must be:

```text
Wallet / Client installation
└── Provider account (MosaicVPN, Provider B, Provider C)
    ├── Account session and cabinet permissions
    ├── One or more provider subscriptions
    │   ├── Provider manifest (route metadata and policies)
    │   ├── Smart Group routes
    │   ├── Published ordinary server routes, if provider allows them
    │   └── Private candidate pool: never rendered or exported
    └── Billing / devices / access state / rotation controls

Local collection (not an account)
└── User-added subscription URL, file, clipboard or manual nodes
    ├── Ordinary parsed server routes
    └── User-created collections/folders
```

A provider account is not a subscription URL. It may issue several feeds, have its own cabinet, billing and device rules. A local collection is not an account and must not pretend to contain billing or provider actions.

### 3.2 Remove visible `MosaicVPN · Direct`

`mosaic-direct` will be replaced with a migration-only internal alias, for example `provider:<provider-id>:primary`. It must never be displayed as a source name.

The visible row becomes the provider subscription supplied by the manifest, for example:

| Type | Subscription/source name | Route rows within it |
|---|---|---|
| Provider account | `MosaicVPN` | `Smart Group · Automatic`, `Smart Group · Germany`, `VLESS · Frankfurt 01` only if provider publishes an ordinary route |
| Local collection | `My imported links` | Parsed VLESS/Trojan/Shadowsocks rows added by the user |
| Other provider account | Provider-declared name | Routes declared by that provider manifest |

Physical Mosaic pool entries will remain inaccessible in all three cases. A Smart Group route is rendered in exactly the same route list as any other route, with type `Smart Group`, and connects through the provider-defined policy.

### 3.3 Per-subscription provider manifest

Replace the single `activeManifest` with a manifest keyed by `provider_subscription_id`.

```text
ProviderSubscriptionManifest
- provider_id
- subscription_id
- title, icon, support_url
- account_capabilities
- route_items[]
  - id
  - route_type: smart_group | server | policy_route
  - title, description, icon
  - client_policy
  - disabled / disabled_reason
- billing_capabilities
- auth_capabilities
- refresh metadata
```

Backend requirements:

1. Save the manifest together with the provider subscription record, not as an application-global object.
2. Build virtual Smart Group route rows for **every subscription with a provider manifest**, not only for the old `mosaic-direct` ID.
3. Scope candidate shard endpoints to `{provider_account_id, provider_subscription_id, group_id}` and validate all three server-side.
4. Keep `handleListServers` filtering private physical nodes by policy flag rather than by a hard-coded ID.
5. Let a provider explicitly declare whether it publishes ordinary server rows. Local collection rows are always visible because the user imported them.
6. Preserve the disabled `Free LTE` placeholder as manifest-owned provider metadata; do not manufacture it in the client.

### 3.4 Multi-provider accounts

The client supports multiple accounts by storing one secure `ProviderAccountSession` per provider account.

| Field | Purpose |
|---|---|
| `account_id` | Local stable ID |
| `provider_id` | Domain/key of the provider authority |
| `display_name`, `icon_url` | User-facing provider identity |
| `issuer_url` | OAuth/cabinet authority |
| `session_ref` | Secure-storage reference, never plain token in preferences |
| `capabilities` | Login, billing, freeze, link rotation, devices, manifest support |
| `default_subscription_id` | The provider source selected after login |
| `last_sync`, `last_error` | Account-level transparent status |

A user may have two Mosaic accounts only if the provider issues distinct account identities; otherwise one Mosaic account can contain multiple plans/subscriptions. A user may also add independent Provider B and Provider C accounts. The subscription picker groups routes under the selected provider subscription; the account switcher is a separate control.

---

## 4. Website-first authorization

### 4.1 Required experience

The primary entry point is **“Sign in to MosaicVPN”**, not `/link`.

1. The client opens the provider’s website in the system browser or Android Custom Tab.
2. The website presents sign-in, registration, password recovery, Telegram linking and any provider-defined access checks.
3. After success, the website redirects to a verified app link or custom URI containing a short-lived authorization code.
4. The client exchanges the code using PKCE and stores only the resulting session reference in secure storage.
5. The app syncs account summary, provider subscriptions, manifest routes and capabilities.

Telegram `/link` becomes a secondary **“Link Telegram to this existing account”** action, useful only after the user is signed in through the website or when recovering a device session.

### 4.2 Protocol

Use OAuth 2.1 Authorization Code with PKCE. Do not pass passwords, long-lived web sessions or subscription links through app deep links.

```text
MosaicVPN app
  → GET https://sub.zxc1x1.ru/oauth/authorize?...&code_challenge=...
  → Website authentication / registration / Telegram binding
  → mosaicvpn://auth/callback?code=<one-time-code>&state=<state>
  → POST /oauth/token { code, code_verifier }
  → account session + provider subscription metadata
```

For Android, prefer verified HTTPS App Links such as `https://sub.zxc1x1.ru/app/auth/callback`, with a custom URI only as a fallback. For Windows/Linux, use a loopback callback listener and system browser.

### 4.3 Website account API required for the app

The site must expose versioned account endpoints protected by the access token:

```text
GET    /api/v2/me
GET    /api/v2/accounts/{account_id}/subscriptions
GET    /api/v2/accounts/{account_id}/subscriptions/{subscription_id}/manifest
POST   /api/v2/accounts/{account_id}/access/freeze
POST   /api/v2/accounts/{account_id}/access/unfreeze
POST   /api/v2/accounts/{account_id}/subscription-link/rotate
GET    /api/v2/accounts/{account_id}/devices
DELETE /api/v2/accounts/{account_id}/devices/{device_id}
GET    /api/v2/accounts/{account_id}/billing/summary
GET    /api/v2/accounts/{account_id}/billing/checkout-url
GET    /api/v2/accounts/{account_id}/billing/history
```

The client does not process Russian payment card/SBP data. It opens the short-lived checkout URL in the browser and refreshes account status after the return link or polling callback.

---

## 5. Profile and billing: mobile parity with the web cabinet

The phone profile should reuse the capability model from the web cabinet, not a separate partial feature list.

### 5.1 Mobile profile structure

| Section | Required actions |
|---|---|
| Account overview | Account ID, provider, access status, expiry, balance, traffic, device limit, plan |
| Access | Freeze/unfreeze, explain consequences, access history |
| Subscription security | Copy current link only if policy permits, regenerate/rotate leaked link, revoke device sessions |
| Devices | View linked devices, rename, revoke selected device, show limit |
| Billing | Balance, history, tariffs, promo status, **Top up on website** button |
| Identity | Link/unlink Telegram, change email/password via browser, export account ID |
| Support and diagnostics | Open support, copy safe diagnostics ID, export sanitized logs |
| Provider actions | Render only capabilities declared by that provider account |

The existing `UnifiedAccountPanel` already covers several items. The implementation task is to make it responsive, capability-driven and usable on Android by backing it with the hosted account API rather than returning `null` on Android.

### 5.2 Top up flow

The client displays a primary `Top up balance` button. It requests a one-time `checkout_url` from the website, opens it externally and returns through an app link. The profile then refreshes balance/history. This keeps Lava/SBP/card payment collection on the approved website and avoids a fragile in-app payment implementation.

---

## 6. Routes UX redesign for phones

### 6.1 Replace table-first UI with a route list

A phone must not use a wide table as its primary routes UI. The new screen uses a flat, filterable list grouped by selected source.

```text
[ Provider / collection switcher ]
[ All ] [ Smart Groups ] [ Servers ] [ Available ] [ Failed ]

MosaicVPN
  Smart Group     Automatic                  Ready        ›
  Smart Group     Germany                    54 ms        ›

My imported links
  VLESS           Frankfurt                  82 ms        ›
  Trojan          Netherlands                Not tested   ›
```

Every row has a fixed-height compact layout: type pill, name, short status/ping, and an overflow button. No horizontal page scrolling is needed.

### 6.2 Route action sheet

Tapping a row opens a bottom sheet. Long press opens it directly on Android.

| Route type | Actions |
|---|---|
| Smart Group | Connect, evaluate now, refresh provider metadata, show policy description, copy route ID, report issue |
| Imported/ordinary server | Connect, test ping, test HTTPS reachability, copy share URI, edit local metadata, move to collection, delete from local collection |
| Provider-published normal server | Connect, test ping if provider allows it, show public metadata, report issue; no delete unless user-owned |

“Test ping” must be explicit. For a single server it triggers the existing test endpoint/local probe and updates that row only. For a Smart Group it must never show pool candidates; it runs the group’s permitted local quality evaluation and reports only aggregate result such as `best available route selected`.

### 6.3 Add and import

The `+` action opens:

1. Add provider account;
2. Add subscription URL;
3. Import from clipboard;
4. Import from file;
5. Add manually;
6. Create local collection.

The import result must show a preview before saving: detected format, supported count, unsupported count, and intended destination collection. It must never silently discard parsing failures.

---

## 7. Logs, Routing and advanced technical tabs

### 7.1 Logs

The client should provide one unified logs tab, with platform source labels.

- **Android:** in-app ring buffer from account operations, subscription parser, VPN bridge state, native `libbox` errors and connect lifecycle. Export through Android share sheet.
- **Windows/Linux:** daemon logs, sing-box logs, parser logs and application UI logs.
- Filters: `All`, `Connection`, `Subscription`, `Account`, `Billing`, `Warning`, `Error`.
- Sanitization: redact subscription URLs, auth codes, bearer tokens, passwords, UUIDs and secret query values by default.

The mobile Logs tab must not invoke desktop-only file manager commands. It should use share/save APIs provided by Android.

### 7.2 Routing

Split the screen into a simple and advanced tier.

- **Simple:** chosen route, split-tunnel toggle, included/excluded apps, DNS mode, local-network access.
- **Advanced:** rule list, ordering, domain/IP rules, custom DNS. It is visible only after enabling Advanced mode.

On Android, settings must be applied to the next native TUN configuration and the UI must say `Saved. Applies on next connection` or perform a controlled reconnect with explicit confirmation. It must never claim it restarted a desktop daemon.

### 7.3 Egresses and unsupported desktop-only tabs

Do not leave broken navigation destinations on mobile. A capability registry decides whether a screen is available.

| Screen | Mobile rule |
|---|---|
| Egresses | Hide from normal mobile navigation; expose only if current provider explicitly supports editable egress policies |
| Cores | Hide on Android; native runtime version belongs in Diagnostics |
| Logs | Keep, using mobile log source |
| Routing | Keep, with mobile-first simple UI |
| Advanced diagnostics | Move to More → Diagnostics |

---

## 8. Implementation sequence

### Phase A — Contracts and data migration

1. Define `ProviderAccount`, `ProviderSubscription`, `RouteItem`, `ProviderCapabilities`, and `ProviderSubscriptionManifest` in Go/Dart.
2. Create a migration that maps legacy `mosaic-direct` to internal provider account/subscription records. Remove its user-visible title.
3. Replace single `activeManifest` with manifests indexed by provider subscription.
4. Make virtual Smart Group rows per provider subscription. Preserve private node filtering through an explicit `visibility`/`provider_managed` policy, not fixed string IDs.
5. Add contract tests: no raw private node appears in API/UI list, every Smart Group belongs to exactly one provider subscription, all candidate endpoints validate provider/subscription/group scope.

### Phase B — Auth and account authority

1. Implement provider discovery and account switching.
2. Implement website-first OAuth 2.1 + PKCE callback flow on Android and desktop.
3. Migrate `/link` to a secondary Telegram-binding/recovery flow.
4. Add secure storage namespaces per provider account.
5. Add account removal, logout and stale-session recovery.

### Phase C — Cabinet and billing parity

1. Implement hosted account v2 API endpoints and capabilities.
2. Enable full `UnifiedAccountPanel` on Android, then adapt it to compact mobile sections.
3. Add top-up external checkout, return app link and automatic account refresh.
4. Add freeze, unfreeze, link rotation and device management.

### Phase D — Subscription and routes experience

1. Introduce the provider/collection switcher.
2. Replace mobile route table with responsive list + action sheet.
3. Add parser preview/import results and per-server diagnostics.
4. Add Android parser support incrementally, beginning with VLESS xHTTP/Reality, Trojan, Shadowsocks and VMess; advertise exactly which formats are runnable in the native runtime.
5. Implement per-source refresh/error state; never catch and erase parser errors.

### Phase E — Technical tabs and cross-platform test matrix

1. Implement the unified sanitized in-app log store.
2. Rework Android routing settings around TUN config persistence/reconnect.
3. Capability-gate Egresses/Cores/desktop-only operations.
4. Test the same account with Android, Windows and Linux; test multiple provider accounts; test local collections; test freeze/payment return; test subscription-link rotation; test Smart Group failover without pool disclosure.

### Phase F — Release criteria

A build is not marked production-ready until all rows below pass:

| Criterion | Required proof |
|---|---|
| Website-first sign-in | Browser login → app callback → account sync on Android and desktop |
| Telegram binding | Existing web account can link Telegram; code flow is optional and clear |
| Multiple providers | Two provider accounts + one local collection remain independent |
| Smart Groups | Render inside correct provider subscription; raw pool nodes never visible |
| Subscription parser | HTTPS fetch, detected format, count/error shown; supported nodes connect |
| Billing | App opens hosted checkout, return refreshes balance/history |
| Mobile routes | No horizontal table scroll; test/delete/edit actions are reachable |
| Technical tabs | Logs/Routing work on Android; unsupported areas are capability-gated |
| VPN | Real Android `VpnService` connect/disconnect and failover test on a device |

---

## 9. Decisions needed before implementation

1. Should third-party providers be supported only through their public subscription URL, or must they also be able to implement the full OAuth/cabinet/Smart Group provider protocol?
2. Is `MosaicVPN` the permanent display name for the first provider, or should the account screen display a brand selected from the manifest?
3. When a user has several Mosaic accounts, should each one be allowed simultaneously on the same device, or must selecting one sign out the other?
4. Should a user be allowed to add the same provider personal subscription URL manually, or should the client recognize it and convert it to the provider-account source?
5. Which actions must remain available offline: viewing cached account state, connecting cached routes, route testing, freeze/unfreeze queueing?
6. Confirm that **top-up always opens the website** rather than accepting payment inside the app.
7. Confirm whether provider-published standalone routes may be visible. If yes, define the policy fields; if no, Mosaic subscriptions will show only Smart Group/policy routes.
8. Confirm which Android protocol set is required for first production release: VLESS xHTTP/Reality, Trojan, Shadowsocks, VMess, Hysteria2, TUIC, WireGuard and others.

---

## 10. Recommendation

Approve the target hierarchy and website-first authentication before continuing code changes. The highest-value first implementation is **Phase A plus Phase B**: remove visible `MosaicVPN · Direct`, make Smart Groups subscription-bound, and establish secure provider accounts. The mobile profile, billing and routes redesign then become straightforward views over a coherent model rather than more patches around special cases.
