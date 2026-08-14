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

