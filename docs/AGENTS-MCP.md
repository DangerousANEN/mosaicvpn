# Connecting an AI agent to Mosaic (MCP)

This document is for **end users** who already have Mosaic installed and want
their AI assistant — Claude Desktop, Cursor, Continue, or any other MCP-aware
client — to read Mosaic's state and (optionally) drive it: switch servers,
refresh subscriptions, run latency tests, manage auxiliary egresses.

> Looking for instructions on how to *develop* against Mosaic's MCP code, or
> how to author new MCP tools? That lives in
> `.agents/skills/mosaicvpn-mcp/SKILL.md` in this repo. This document is the
> opposite: zero source code, just "how do I plug my agent into the Mosaic
> that's already running on my machine?".

---

## TL;DR

1. Open Mosaic → **Folio → Agent & MCP** → make sure **MCP server** is on.
2. Pick a **Permission** level. Default is **Connect** (read state + switch
   servers, but cannot delete subscriptions). Leave **Confirm destructive**
   on if you want a UI prompt before any destructive action.
3. Open the discovery file:
   - **Windows:** `%LOCALAPPDATA%\Mosaic\mcp.json`
   - **macOS / Linux:** `~/.local/share/mosaic/mcp.json` (or whatever
     `MOSAIC_DATA_DIR` is set to).
4. Copy the `url` and `token` fields into your agent's MCP-server config
   (snippets below).
5. Restart the agent. Ask it: *"What servers does my Mosaic have in
   Germany?"* It should call `mosaic_list_servers` and answer.

---

## What's actually exposed

Mosaic's MCP endpoint is a **JSON-RPC 2.0 over HTTP** server bound to
loopback only (default `127.0.0.1:8731`). Authentication is a bearer token
shared with the regular daemon API and rotated on every Mosaic launch — it
is **not** a permanent secret.

### Tools (default = read & connect)

| Tool                          | minPerm  | Description                                                                                               |
| ----------------------------- | -------- | --------------------------------------------------------------------------------------------------------- |
| `mosaic_status`               | read     | Connection state, active server, bytes in/out, uptime, my-location.                                       |
| `mosaic_list_subscriptions`   | read     | All configured subscriptions with traffic / expiry info when the provider exposes Subscription-Userinfo.  |
| `mosaic_list_servers`         | read     | Servers across all subscriptions; filter by `subscription_id`, `country` (ISO-2), `city`, `protocol`, `limit`. |
| `mosaic_get_prefs`            | read     | Full Prefs object (DNS, kill-switch, anti-DPI, etc.).                                                     |
| `mosaic_list_egresses`        | read     | Auxiliary SOCKS5 / HTTP proxies (rc44) and their live status.                                             |
| `mosaic_connect`              | connect  | Connect the main tunnel to `server_id`; blocks until Connected or error.                                  |
| `mosaic_disconnect`           | connect  | Tear down the active tunnel.                                                                              |
| `mosaic_url_test`             | connect  | Run a Verify probe through `server_id`; persists RTT / status / error.                                    |
| `mosaic_refresh_subscription` | connect  | Re-fetch a subscription URL and replace its server list.                                                  |
| `mosaic_start_egress`         | connect  | Start an auxiliary egress's sing-box subprocess.                                                          |
| `mosaic_stop_egress`          | connect  | Stop an auxiliary egress.                                                                                 |
| `mosaic_add_subscription`     | full     | Add a new subscription URL (and immediately refresh).                                                     |
| `mosaic_remove_subscription`  | full     | Delete a subscription **and all its servers**. Irreversible.                                              |
| `mosaic_add_egress`           | full     | Create a new auxiliary egress.                                                                            |
| `mosaic_remove_egress`        | full     | Delete an auxiliary egress.                                                                               |

### Permission levels

- **read** — agent can only inspect. Nothing it does will change Mosaic's
  state. Safest for "give my LLM context about what's available" use cases.
- **connect** *(default)* — agent can switch servers, run probes, refresh
  subscriptions, and drive auxiliary egresses, but cannot add or delete
  subscriptions / egresses.
- **full** — agent can add and delete subscriptions and egresses too. Only
  flip this on if you actually trust the agent.

### Confirm-destructive

If `MCPConfirm = true` (default), Mosaic pops up a UI confirmation prompt
before any tool call that would *delete* something — even when the agent has
**full** permission. This is the recommended setting.

---

## Discovery file

Every Mosaic launch writes a fresh `mcp.json` next to the daemon's other
state:

- **Windows:** `%LOCALAPPDATA%\Mosaic\mcp.json`
- **Linux:** `$XDG_DATA_HOME/mosaic/mcp.json` (defaults to
  `~/.local/share/mosaic/mcp.json`)
- **macOS:** `~/Library/Application Support/mosaic/mcp.json`
- **Override:** if you start Mosaic with `MOSAIC_DATA_DIR=/path/...`, the
  file lives in that directory instead.

Contents:

```json
{
  "url":        "http://127.0.0.1:8731/",
  "token":      "5f3e…",
  "permission": "connect",
  "confirm":    true,
  "version":    "0.1.0",
  "pid":        12842,
  "started":    "2026-04-29T09:47:00Z"
}
```

The `token` rotates on every Mosaic launch. Agents that hard-code the
token will break after the next reboot — use the discovery file or a
launch-time environment variable instead.

---

## Plug-in snippets

### Claude Desktop

Edit `claude_desktop_config.json` (Claude → Settings → Developer → "Edit
Config"):

```json
{
  "mcpServers": {
    "mosaic": {
      "url":     "http://127.0.0.1:8731/",
      "headers": {
        "Authorization": "Bearer PASTE_TOKEN_FROM_MCP_JSON_HERE"
      }
    }
  }
}
```

Restart Claude Desktop. Mosaic's tools should appear under the hammer/tools
icon.

### Cursor

Cursor reads `~/.cursor/mcp.json` (or per-project `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "mosaic": {
      "url":     "http://127.0.0.1:8731/",
      "headers": {
        "Authorization": "Bearer PASTE_TOKEN_FROM_MCP_JSON_HERE"
      }
    }
  }
}
```

Cursor's docs:
<https://docs.cursor.com/context/model-context-protocol>.

### Continue (VS Code / JetBrains plugin)

Add to your Continue config (`~/.continue/config.json` or the equivalent
on Windows):

```json
{
  "mcpServers": [
    {
      "name":    "mosaic",
      "url":     "http://127.0.0.1:8731/",
      "headers": {
        "Authorization": "Bearer PASTE_TOKEN_FROM_MCP_JSON_HERE"
      }
    }
  ]
}
```

### Generic / DIY

Any client that understands MCP-over-HTTP works the same way:

- **Endpoint:** the `url` from `mcp.json`.
- **Auth:** an `Authorization: Bearer <token>` header on every request,
  including the initial `tools/list`.
- **Wire format:** standard JSON-RPC 2.0 (`tools/list` and `tools/call`).
- **Health check:** `GET /healthz` (no auth required) returns `200 OK`.

---

## Things to ask your agent

Once the connection is live, try:

- *"What's my current Mosaic status?"* → `mosaic_status`
- *"Show me all servers in DE sorted by latency."* → `mosaic_list_servers`
  filtered by country.
- *"Connect to the fastest tested server in Germany."* → `mosaic_list_servers`
  + `mosaic_connect`.
- *"Run a URL test against every server in subscription X."* →
  `mosaic_list_servers` + repeated `mosaic_url_test`.
- *"Refresh my main subscription."* → `mosaic_refresh_subscription`.
- *"Set up an auxiliary SOCKS5 proxy on port 10808 pinned to the fastest
  Netherlands server, so I can route Telegram through it without changing
  my main tunnel."* → `mosaic_add_egress` + `mosaic_start_egress`.
- *"Stop all auxiliary egresses."* → `mosaic_list_egresses` +
  `mosaic_stop_egress`.

The agent does the orchestration; you just describe the outcome.

---

## Security & sanity

- **Loopback only.** The daemon refuses to bind MCP anywhere other than
  `127.0.0.1` / `::1`. There is no path to expose this off-host short of
  the user explicitly running an SSH tunnel or reverse proxy.
- **Token rotates per launch.** No long-lived secret to leak.
- **No telemetry.** MCP calls are local IPC. They do not phone home.
- **`MCPPermission` is enforced server-side.** The agent cannot escalate by
  asking nicely — Mosaic returns `permission denied` for any tool whose
  `minPerm` exceeds the configured level.
- **`MCPConfirm` is enforced server-side too.** When on, every destructive
  tool call pops a Mosaic UI prompt; the agent's call blocks until the user
  approves or rejects.
- **To revoke immediately:** Folio → Agent & MCP → toggle off, or restart
  Mosaic (rotates token + lets you take a different stance on relaunch).

---

## Troubleshooting

- **Agent says "MCP server not found" / connection refused.**
  - Is Mosaic running? `mosaicd` writes the discovery file only after it
    has bound the listener.
  - Did the **Folio → Agent & MCP** toggle get flipped off? Turn it on,
    save, and re-read `mcp.json`.
  - Is something else holding port 8731? Change the listen port in
    Folio → Agent & MCP → "Bind address".

- **Agent says `401 missing bearer token` or `bad token`.**
  - The token in your agent config is stale. Mosaic rotated it at the last
    launch. Copy the fresh `token` from `mcp.json`.

- **Agent says `permission denied`.**
  - The tool's `minPerm` exceeds your current `MCPPermission`. Folio →
    Agent & MCP → bump the level (read → connect → full).

- **Agent calls `mosaic_remove_subscription` and nothing happens.**
  - `MCPConfirm` is on (good!). Check Mosaic — there is a confirmation
    dialog waiting for your click.

- **Tools list is empty.**
  - `MCPPermission=none` (everything blocked). Or the agent forgot to
    send the bearer header on `tools/list` — most clients do, but a
    hand-rolled one might not.

- **Tools list contains only `mosaic_status` / `mosaic_list_*`.**
  - You are on `read`. Bump to `connect` or `full` to see the rest.

---

## Living off-line

Mosaic does not need internet to run the MCP server itself; the only
network calls go to whatever VPN / probe targets you ask for. If you want
to keep an LLM workflow purely local, point your agent at a local model
and at Mosaic — neither leaves the box.
