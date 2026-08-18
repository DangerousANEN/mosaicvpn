# v0.3.19 Android incident research

## Confirmed production observations

On 2026-08-18, the user-provided `https://sub.zxc1x1.ru/reftcT_frzSCwhav` returned a base64 subscription feed (`text/plain`, 9,904 bytes) containing VLESS share URIs. The public paths `/api/manifest.json` and `/api/manifest.json?subscription_id=reftcT_frzSCwhav` returned HTTP 404 from the deployed `sub.zxc1x1.ru` authority. This explains why Android cannot fetch authoritative provider Smart Group metadata from its current hosted endpoint and instead renders the plain feed rows as VLESS servers.

The supplied Android screenshot showed the native libbox error `outbounds[0].encryption: json: unknown field "encryption"`. The Android VLESS URI parser was serialising the URI compatibility parameter `encryption=none` into the sing-box VLESS outbound. The official VLESS outbound schema lists `server`, `server_port`, `uuid`, `flow`, `network`, `tls`, `packet_encoding`, `multiplex` and `transport`; `encryption` is not a supported outbound field. The parser must omit it.[1]

The existing Android website-enrollment flow registers custom-scheme callbacks and consumes them only through a native MethodChannel slot. Official Android guidance confirms that custom schemes can dispatch from browser intents but are not a trusted web-link association; for a domain owned by the service, verified HTTPS Android App Links are the recommended seamless route. Flutter also documents that incoming deep links reach the framework differently for a cold and warm Android application; manual native interception and Flutter's default deep-link handler must not compete for the same callback.[2][3]

## Sources

[1]: https://sing-box.sagernet.org/configuration/outbound/vless/ "sing-box VLESS outbound schema"
[2]: https://developer.android.com/training/app-links/create-deeplinks "Android Developers: Create deep links"
[3]: https://docs.flutter.dev/ui/navigation/deep-linking "Flutter documentation: Deep linking"


## Public subscription profile audit (2026-08-18)

The user-provided subscription response includes standard headers (`profile-title`, `profile-update-interval`, `subscription-userinfo`) but its current `subscription-userinfo` value is `upload=0; download=0; total=0; expire=0`; it therefore cannot supply a useful base cabinet by itself. The deployed legacy `GET /stats-api/stats/<opaque-link>` response did return high-level account-like values, but also returned VLESS UUIDs and host objects with addresses, SNI and transport metadata. That response must **not** be consumed by the client cabinet or treated as a safe public profile API, because it breaks the private-pool boundary.

The required remediation is a distinct minimal endpoint keyed by the opaque subscription capability that returns an allow-listed base profile only: provider subscription status, expiry/days left, used/limit/lifetime traffic, device limit, and a non-sensitive profile label. It must exclude server rows, UUIDs, share URLs, session/direct tokens, payment data, balance operations, device identifiers and all account-control actions. Expanded profile actions remain behind authenticated `/api/billing/*` and checkout routes.
