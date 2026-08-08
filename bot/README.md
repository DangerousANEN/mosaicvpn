# MosaicVPN Telegram Bot

The bot that sells and provisions subscriptions: `@mosaicvpnbot`.
It runs on the VPS as the `mosaic-bot` systemd service and talks to the
Remnawave panel to create and renew users.

## Why this directory exists

The bot lived only at `/opt/mosaic-bot/bot.py` on the server and was never
under version control. A single bad `rm` would have destroyed it, and there
was no history to answer "when did this break?". This is that code, with the
credentials stripped out.

## Credentials

Nothing secret belongs in this file. The bot reads three values from the
environment and refuses to start if the required ones are missing, rather
than running half-authenticated and failing later at an unrelated call site:

| Variable | Required | Purpose |
|---|---|---|
| `MOSAIC_BOT_TOKEN` | yes | Telegram Bot API token |
| `MOSAIC_REMNAWAVE_TOKEN` | yes | Remnawave panel API bearer token |
| `MOSAIC_CRYPTO_PAY_TOKEN` | no | CryptoBot payments |
| `MOSAIC_REMNAWAVE_URL` | no | Panel base URL (default `https://panel.zxc1x1.ru`) |

On the server these live in `/etc/mosaic-bot.env`, owned by root with mode
`600`, and are loaded via `EnvironmentFile=` in the unit.

## Reaching the panel

`MOSAIC_REMNAWAVE_URL` must point at the **public HTTPS** address, not at
`http://localhost:3000`. Remnawave runs a `ProxyCheckMiddleware` that drops
any request which did not arrive through the reverse proxy, answering with a
closed connection rather than a status code. Calling the container port
directly therefore fails with `RemoteDisconnected` while the container still
reports `healthy` — the panel is fine, it is refusing the route on purpose.

## Deploying a change

```bash
scp bot/bot.py root@<vps>:/opt/mosaic-bot/bot.py.new
ssh root@<vps> '
  cd /opt/mosaic-bot &&
  venv/bin/python -m py_compile bot.py.new &&   # syntax gate before swapping
  cp bot.py bot.py.bak.$(date +%Y%m%d_%H%M%S) &&
  mv bot.py.new bot.py &&
  systemctl restart mosaic-bot &&
  sleep 20 && systemctl is-active mosaic-bot'
```

`py_compile` catches syntax errors but **not** ordering mistakes: a call
placed above its own `def` compiles cleanly and then dies at startup with
`NameError`. After restarting, read the log before declaring success:

```bash
journalctl -u mosaic-bot --since '1 minute ago' --no-pager | \
  grep -E 'Traceback|SystemExit|missing required|polling'
```

Note that `scp` of this ~160 KB file drops often on this host. Retry, or for
a one-line change patch it in place server-side instead.

## Blocked users

Telegram answers `403 Forbidden: bot was blocked by the user` forever once
someone blocks the bot. The funnel records a notification only after a
successful send, so a blocked user was re-selected on every pass — 204 futile
sends in two hours, against one user.

`users.blocked` (with `blocked_at`) now records that state.
`send_funnel_notification` flags the user when Telegram reports them
unreachable, the funnel query skips flagged users, and `clear_blocked_flag`
lifts the flag if they come back. The migration is idempotent and runs at
startup.
