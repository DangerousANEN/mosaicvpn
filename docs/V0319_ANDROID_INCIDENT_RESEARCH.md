# v0.3.19 Android incident research

## Confirmed production observations

On 2026-08-18, the user-provided `https://sub.zxc1x1.ru/reftcT_frzSCwhav` returned a base64 subscription feed (`text/plain`, 9,904 bytes) containing VLESS share URIs. The public paths `/api/manifest.json` and `/api/manifest.json?subscription_id=reftcT_frzSCwhav` returned HTTP 404 from the deployed `sub.zxc1x1.ru` authority. This explains why Android cannot fetch authoritative provider Smart Group metadata from its current hosted endpoint and instead renders the plain feed rows as VLESS servers.

The supplied Android screenshot showed the native libbox error `outbounds[0].encryption: json: unknown field "encryption"`. The Android VLESS URI parser was serialising the URI compatibility parameter `encryption=none` into the sing-box VLESS outbound. The official VLESS outbound schema lists `server`, `server_port`, `uuid`, `flow`, `network`, `tls`, `packet_encoding`, `multiplex` and `transport`; `encryption` is not a supported outbound field. The parser must omit it.[1]

The existing Android website-enrollment flow registers custom-scheme callbacks and consumes them only through a native MethodChannel slot. Official Android guidance confirms that custom schemes can dispatch from browser intents but are not a trusted web-link association; for a domain owned by the service, verified HTTPS Android App Links are the recommended seamless route. Flutter also documents that incoming deep links reach the framework differently for a cold and warm Android application; manual native interception and Flutter's default deep-link handler must not compete for the same callback.[2][3]

## Sources

[1]: https://sing-box.sagernet.org/configuration/outbound/vless/ "sing-box VLESS outbound schema"
[2]: https://developer.android.com/training/app-links/create-deeplinks "Android Developers: Create deep links"
[3]: https://docs.flutter.dev/ui/navigation/deep-linking "Flutter documentation: Deep linking"

