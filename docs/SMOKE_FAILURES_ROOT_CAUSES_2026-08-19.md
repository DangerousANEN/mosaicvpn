# Root-cause inspection — smoke-test failures

## Confirmed findings

| Failure | Confirmed implementation cause | Impact |
|---|---|---|
| Website-added Mosaic subscription is not an ordinary URL source | `AndroidHostedDaemonApi._asMosaicProviderSource` converts every `https://sub.zxc1x1.ru/...` import into a provider row and sets `hidePhysicalNodes: true`. `listSubscriptions` silently migrates stored URL rows the same way. | A user-owned Mosaic URL cannot follow the same parse/connect lifecycle as other URL subscriptions. |
| Website-added subscription cannot be deleted | Android `deleteSubscription` rejects `_mosaicProviderSubscriptionID` with “Основную подписку MosaicVPN нельзя удалить.” | The local source cannot be removed, contradicting the requested subscription ownership model. |
| Android cannot connect until Mosaic account login | Group connection calls `AndroidMosaicAccountService.buildNativeTunConfig`; it exits with “Сначала войдите в MosaicVPN.” when there is no stored direct token. | VPN connectivity is incorrectly coupled to an optional cabinet session instead of deriving config from the subscription URL. |
| Website profile attach is not discoverable | `SubscriptionCabinetScreen` renders `_CabinetUnavailable`, a passive text-only placeholder. There is no website-login CTA or manual short-code action. | The user cannot attach a compatible cabinet to the selected subscription from the app UI. |
| Website enrollment conflates source and cabinet attachment | Android/desktop callbacks call `enrollProviderSubscription`, which creates or replaces a special provider source and stores global account material. The Go daemon follows the same provider-source strategy. | New flow violates the required “ordinary subscription first; profile attachment second” contract and makes multi-provider separation harder. |
| Logs toolbar overflows on Android | `LogsScreen` places filter, Auto, Copy, Save and Clear in a single non-wrapping `Row` with a `Spacer`. | Controls clip beyond the right screen edge at phone width, as reported. |
| Website cabinet lost controls despite server support | `cabinet.html` renders status, payment and “Add to app” only. Backend already exposes authenticated `/api/account/freeze`, `/api/account/unfreeze` and `/api/subscription/link/rotate`; profile payload already includes `subscription_url`. | Missing UI wiring, refresh-state handling and subscription-link display hide supported service controls. |
| Website admin surface is reduced | `admin.html` only provides individual balance credit/history. Bot still implements `/broadcast`; no web broadcast or rate/price endpoints/UI exist. | Required administration actions are absent from the web interface. |
| Website registration/password recovery are not implemented | SQLite `users` is Telegram-ID-primary with no email/password credentials, verification/challenge or reset schema. Cabinet only accepts an 8-character Telegram pairing code. | This requires a new account-identity and recovery subsystem, not a cosmetic login-form addition. |

## Architectural correction required

The stable local object must be a `Subscription` with an ordinary URL/import lifecycle. A compatible provider profile is an attachment (`SubscriptionCabinetBinding`) identified by the local subscription ID plus provider identifier and account-binding material. Its presence controls cabinet capabilities only; it must not determine subscription parsing, user-controlled deletion or route connection.

Website enrollment and manual code entry should both be transports that establish the same binding. Both exchange a short-lived, one-time authorization artifact over HTTPS, then locate the matching URL-backed subscription by canonical URL (or add it once if absent) and store the binding against its local ID.
