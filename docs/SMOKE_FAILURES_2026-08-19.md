# Smoke-test findings — 19 August 2026

## Reported blockers

| ID | Observed symptom | Required product behavior |
|---|---|---|
| S-01 | A subscription obtained through the website does not add reliably. | Website enrollment must add the user’s actual ordinary subscription URL and then attach the Mosaic cabinet profile to that subscription. |
| S-02 | The website-added subscription cannot be deleted. | A user must be able to delete the local subscription representation, including its linked cabinet session, from the subscription context menu; this must not cancel the remote service. |
| S-03 | Connection fails with “сначала войдите в MosaicVPN”. | Normal subscription connectivity must not depend on an authenticated cabinet session. A parsed subscription URL is sufficient for connection. Cabinet authentication only unlocks account controls. |
| S-04 | The site profile link fails to attach a client cabinet profile. | The profile attach flow must bind to the matching local subscription via provider/service identity and subscription URL identity, never invent a second generic import. |
| S-05 | Only URI/deep-link profile attach is perceived as available. | Offer both website return/deep-link and a manually entered short-lived, one-time profile connection code. The website must generate the same code, not only the bot. |
| S-06 | The Android Logs toolbar extends beyond the device width. | Logs actions must wrap or collapse into an overflow menu; no action may be clipped horizontally. |
| S-07 | Website subscription profile lacks management controls. | Authenticated cabinet must expose subscription URL, freeze/resume, link rotation, balance/top-up path, devices, usage and other supported account controls. |
| S-08 | Website admin panel lost broadcast, price editing and balance-allocation controls. | Administrator interface must restore explicitly authorized broadcast, plan-price management, individual/bulk balance allocation, plus audited server-side authorization. |
| S-09 | Website registration/recovery is missing. | Website must provide account registration with login/password, password reset with an out-of-band verification mechanism, secure session handling and Telegram linking as an optional account association. |

## Contract decisions requested by the user

1. A MosaicVPN subscription added from the website is **first an ordinary URL-backed subscription**. The client parses it exactly like a compatible subscription imported manually.
2. The Mosaic cabinet profile is a **separate optional attachment** to that existing subscription. It unlocks account functions but is not a prerequisite for route parsing or VPN connection.
3. Subscription identity is stable and local. Cabinet attachment is keyed to provider/service metadata plus a non-secret subscription/account reference; no private route pool is shown to users.
4. Account-link codes are single-use, short-lived, rate-limited and exchanged over HTTPS. They must never be treated as reusable subscription secrets.
5. A local delete removes local routes, local attachment/session tokens and Smart Group state; it must not revoke a remote subscription or change billing.

## Evidence from Android screenshots

The logs screen at phone width renders a horizontal action bar containing “All”, “Auto”, “Copy” and a further action that is clipped beyond the right edge. The subscription profile screen shows basic status values but no visible primary action to attach the cabinet, despite copy stating that website or Telegram-code attachment is supported. The generated plan must require an explicit, reachable manual-code action and a responsive toolbar redesign.
