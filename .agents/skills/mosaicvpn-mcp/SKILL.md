# MosaicVPN — MCP agent guide

Reusable playbook for an LLM agent (Devin, Claude, Cursor, etc.) to
connect to a running **Mosaic daemon** through its **MCP** (Model Context
Protocol) endpoint, inspect state, and drive the tunnel.

The Mosaic daemon exposes an MCP server on the loopback interface.
It speaks **JSON-RPC 2.0 over HTTP POST**. Auth is a bearer token
shared with the daemon's main API. Transport is simplified (no SSE);
every tool call is a single request/response.

## 1. Discover the endpoint

The daemon writes a discovery file at **`{DataDir}/mcp.json`** every
time it starts with `mcp_enabled=true`:

| OS      | DataDir (default)                                   |
|---------|-----------------------------------------------------|
| Windows | `%ProgramData%\Mosaic\mcp.json`                     |
| macOS   | `~/Library/Application Support/Mosaic/mcp.json`     |
| Linux   | `$XDG_DATA_HOME/mosaic/mcp.json` or `~/.local/share/mosaic/mcp.json` |

If `MOSAIC_DATA_DIR` is set, use `$MOSAIC_DATA_DIR/mcp.json` instead.

Contents:
```json
{
  "url": "http://127.0.0.1:8731/",
  "token": "<64-hex-char bearer token>",
  "permission": "read | connect | full",
  "confirm": false,
  "version": "0.1.0-rcN",
  "pid": 12345,
  "started": "2026-04-29T17:00:00Z"
}
```

If the file is missing, MCP is disabled or the daemon is not running.
Check the daemon's status with the Mosaic UI → Settings → MCP.

Health check (no auth):
```sh
curl -s http://127.0.0.1:8731/healthz
# {"ok":true}
```

## 2. Authenticate

Every JSON-RPC call must carry:
```
Authorization: Bearer <token>
Content-Type: application/json
```

Anything else gets a `-32000` "missing bearer token" / "bad token"
JSON-RPC error.

## 3. The MCP handshake

All MCP clients start with `initialize`. Do this once per session.

```sh
URL=$(jq -r .url   "$MCP_JSON")
TOK=$(jq -r .token "$MCP_JSON")

curl -s "$URL" \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
```

Expected result:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {"tools": {"listChanged": false}},
    "serverInfo": {
      "name": "mosaicvpn",
      "version": "0.1.0-rcN",
      "permission": "connect"
    }
  }
}
```

Then `tools/list` returns the tools you are allowed to call given the
configured permission level.

## 4. Permission model

The user picks a permission level in Settings → MCP. Tools are gated:

| Permission  | Allowed tools                                                                 |
|-------------|-------------------------------------------------------------------------------|
| `read`      | `mosaic_status`, `mosaic_list_subscriptions`, `mosaic_list_servers`, `mosaic_get_prefs` |
| `connect`   | everything in `read` + `mosaic_connect`, `mosaic_disconnect`, `mosaic_url_test`, `mosaic_refresh_subscription` |
| `full`      | everything + `mosaic_add_subscription`, `mosaic_remove_subscription`          |

If a tool is denied you get a JSON-RPC error telling you what
permission you need. Ask the user to raise it in Settings — never try
to work around it.

**Confirm flag:** if `mcp.json` reports `"confirm": true`, tools at
`connect` level and above currently fail with a clear error explaining
the user must disable confirm in Settings. A renderer-side confirm
modal is planned but not yet wired.

## 5. Tools

Every call has the shape:
```json
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}
```

Results carry both a human-readable `content[0].text` (JSON pretty-
printed) and a `structuredContent` object for programmatic consumption.
Errors set `isError: true` in the result body (not in the JSON-RPC
`error` field — reserve those for transport/permission issues).

### `mosaic_status`   *(read)*
No arguments. Returns the full `proto.Status` snapshot:
`state` (`disconnected` / `connecting` / `connected` / `error`),
`server` (when connected), `bytes_in` / `bytes_out`, `my_location`,
etc.

### `mosaic_list_subscriptions`   *(read)*
No arguments. Returns `[{id, name, url, server_count, last_fetched, last_error}]`.

### `mosaic_list_servers`   *(read)*
Arguments:
```json
{
  "subscription_id": "sub-xyz",
  "country":         "DE",
  "city":            "frankfurt",
  "protocol":        "vless",
  "limit":           50
}
```
All optional. Pass `"limit": -1` for no cap. Sorting: servers with a
recent successful URL-test first (by RTT ascending), then by name.

Returns `{total, returned, servers: [...]}`.

### `mosaic_connect`   *(connect)*
```json
{"server_id": "srv-abc"}
```
Blocks until the manager reports Connected or an error occurs.
Returns the fresh `Status` snapshot.

### `mosaic_disconnect`   *(connect)*
No arguments. Returns the fresh `Status`.

### `mosaic_url_test`   *(connect)*
```json
{"server_id": "srv-abc"}
```
Runs the same Verify probe the UI uses: spins up a transient sing-box
outbound, fetches `Prefs.URLTestEndpoint` (default: gstatic 204; user
may set this to Google, Cloudflare, or a custom URL in Settings →
Verify). Persists `last_url_test_*` on the server record and returns
the updated record.

### `mosaic_refresh_subscription`   *(connect)*
```json
{"subscription_id": "sub-xyz"}
```
Re-fetches from the subscription URL and replaces the server list.

### `mosaic_add_subscription`   *(full)*
```json
{"url": "https://example.com/sub.txt", "name": "my home"}
```
`format` optional (rare — usually empty). Triggers an immediate
refresh. Returns the stored Subscription record.

### `mosaic_remove_subscription`   *(full)*
```json
{"subscription_id": "sub-xyz"}
```
Irreversible. Returns `{"deleted": "<id>"}`.

### `mosaic_get_prefs`   *(read)*
No arguments. Returns the full `Prefs` object. Useful when you need
to know e.g. the current URLTestEndpoint, DPI settings, or SOCKS
listen addresses.

## 6. Common scenarios

### Show me what's going on
```
tools/call mosaic_status
tools/call mosaic_list_subscriptions
```

### Connect to the fastest DE server by RTT
```
tools/call mosaic_list_servers {"country":"DE","limit":1}
# → take servers[0].id
tools/call mosaic_connect {"server_id":"<id>"}
```

### Verify every server in a subscription and rank by working RTT
```
tools/call mosaic_list_servers {"subscription_id":"sub-xyz","limit":-1}
for id in <each>:
  tools/call mosaic_url_test {"server_id": id}
tools/call mosaic_list_servers {"subscription_id":"sub-xyz","limit":-1}
# now sorted: successful URL-tests first, ascending RTT
```

### Rotate egress every 6 hours
```
loop every 6h:
  tools/call mosaic_disconnect
  tools/call mosaic_list_servers {"country":"SG","limit":20}
  pick = random(servers)
  tools/call mosaic_connect {"server_id": pick.id}
```

### Add a subscription and connect to its best server
```
tools/call mosaic_add_subscription {"url":"http://…/sub.txt"}
# wait a moment for geo backfill
tools/call mosaic_list_servers {"subscription_id":"<new-sub-id>","limit":-1}
tools/call mosaic_url_test {"server_id": servers[0].id}
# if ok → connect
```

## 7. Troubleshooting

- **`connection refused` on port 8731** — daemon not running OR MCP
  disabled in Prefs OR a different MCPAddr was set. Check
  `mcp.json` → `url`.
- **`missing bearer token`** — read the token from `mcp.json`, don't
  guess. The token rotates every daemon start.
- **`tool X requires connect permission`** — tell the user to change
  Settings → MCP → Permission. Don't retry, it will keep failing.
- **`tool X requires user confirmation`** — tell the user to disable
  the confirm switch in Settings → MCP, or wait for the future
  renderer-side confirm UI (not yet implemented).
- **Discovery file is stale / wrong token** — the daemon rewrites
  `mcp.json` on every start. If you see stale values, ask the user
  to restart Mosaic. The PID in `mcp.json` should match a live
  process.
- **`mcp_addr must bind to 127.0.0.1/::1 only`** — MCP refuses to
  bind to non-loopback addresses by design (the token lives in a
  local file). Tell the user to revert MCPAddr to `127.0.0.1:<port>`.

## 8. Non-MCP agents (Devin with shell access)

You don't strictly need an MCP client library — any shell with
`curl` + `jq` can drive the server. The discovery file + bearer
token + JSON-RPC are simple enough to script:

```sh
MCP_JSON="${MOSAIC_DATA_DIR:-$HOME/.local/share/mosaic}/mcp.json"
URL=$(jq -r .url   "$MCP_JSON")
TOK=$(jq -r .token "$MCP_JSON")

rpc() {
  curl -s "$URL" \
    -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

# status
rpc tools/call '{"name":"mosaic_status","arguments":{}}' | jq .result.structuredContent

# list DE servers
rpc tools/call '{"name":"mosaic_list_servers","arguments":{"country":"DE","limit":5}}' \
  | jq '.result.structuredContent.servers[] | {id,name,city,last_url_test_ms}'
```

Keep the `mcp.json` path dynamic — never hardcode the token.

## 9. Protocol reference

- MCP: https://modelcontextprotocol.io/
- JSON-RPC 2.0: https://www.jsonrpc.org/specification
- Source: `internal/mcp/server.go` in this repo. Adding a new tool
  means appending to `Server.tools()` with a `minPerm` and a handler
  that delegates to `*store.Store` / `*state.Manager` / the
  injected `URLTestFn` / `RefreshFn`.
