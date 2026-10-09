#!/usr/bin/env python3
"""MosaicVPN MCP server — Model Context Protocol over stdio.

Lets any MCP client (Claude Desktop, Cursor, VS Code, any OS) control a
MosaicVPN desktop/mobile client through its local REST API
(http://127.0.0.1:19080) and read account state from the cloud API
(https://sub.zxc1x1.ru) when a token is configured.

Transport: stdio (JSON-RPC 2.0, MCP 2024-11-05).
No third-party deps: stdlib only, so it runs anywhere Python 3.10+ runs.
"""

import json
import os
import sys
import urllib.request
import urllib.error

LOCAL_BASE = os.environ.get("MOSAIC_LOCAL_API", "http://127.0.0.1:19080")
CLOUD_BASE = os.environ.get("MOSAIC_CLOUD_API", "https://sub.zxc1x1.ru")
CLOUD_TOKEN = os.environ.get("MOSAIC_API_TOKEN", "")

TOOLS = [
    {
        "name": "vpn_status",
        "description": "Current MosaicVPN tunnel status: connected, server, "
        "group, last error, tunnel mode.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "vpn_servers",
        "description": "List all available VPN servers/groups with latency.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "vpn_connect",
        "description": "Connect the VPN to a specific server or group id "
        "(get ids from vpn_servers).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Server or group id"}
            },
            "required": ["id"],
        },
    },
    {
        "name": "vpn_disconnect",
        "description": "Disconnect the VPN tunnel.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "vpn_find_stable",
        "description": "Auto-connect to the most stable reachable server.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "vpn_get_prefs",
        "description": "Read routing preferences incl. per-app split tunneling "
        "(bypass_packages = apps excluded from VPN; proxy_packages = apps "
        "forced through VPN).",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "vpn_set_prefs",
        "description": "Update routing preferences (partial update). Lists "
        "replace the whole list. Example: exclude bank apps by adding their "
        "package names to bypass_packages.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "routing_mode": {
                    "type": "string",
                    "enum": ["global", "rule", "direct"],
                },
                "bypass_packages": {
                    "type": "array",
                    "items": {"type": "string"},
                },
                "proxy_packages": {
                    "type": "array",
                    "items": {"type": "string"},
                },
                "adblock": {"type": "boolean"},
                "auto_connect": {"type": "boolean"},
                "kill_switch": {"type": "boolean"},
            },
        },
    },
    {
        "name": "account_profile",
        "description": "Cloud account state: days left, balance, traffic. "
        "Requires MOSAIC_API_TOKEN (issued in the app or bot).",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def _http_json(base, path, method="GET", body=None, timeout=12, token=""):
    url = base.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode() or "{}")
        except Exception:
            payload = {"error": str(e)}
        return e.code, payload
    except Exception as e:  # noqa: BLE001 — surfaced to the model as-is
        return 0, {"error": f"{type(e).__name__}: {e}"}


def call_tool(name, args):
    if name == "vpn_status":
        code, payload = _http_json(LOCAL_BASE, "/status")
        return code, payload
    if name == "vpn_servers":
        code, payload = _http_json(LOCAL_BASE, "/servers")
        return code, payload
    if name == "vpn_connect":
        sid = str(args.get("id", ""))
        code, payload = _http_json(LOCAL_BASE, f"/connect/{sid}", method="POST")
        return code, payload
    if name == "vpn_disconnect":
        code, payload = _http_json(LOCAL_BASE, "/disconnect", method="POST")
        return code, payload
    if name == "vpn_find_stable":
        code, payload = _http_json(LOCAL_BASE, "/find-stable", method="POST")
        return code, payload
    if name == "vpn_get_prefs":
        code, payload = _http_json(LOCAL_BASE, "/v1/prefs")
        return code, payload
    if name == "vpn_set_prefs":
        code, payload = _http_json(
            LOCAL_BASE, "/v1/prefs", method="PUT", body=args
        )
        return code, payload
    if name == "account_profile":
        if not CLOUD_TOKEN:
            return 401, {
                "error": "MOSAIC_API_TOKEN is not set. Issue a token in the "
                "MosaicVPN app (Settings → API) or via the bot, then set the "
                "MOSAIC_API_TOKEN environment variable."
            }
        code, payload = _http_json(
            CLOUD_BASE,
            "/api/billing/profile?token=" + CLOUD_TOKEN,
            token=CLOUD_TOKEN,
        )
        return code, payload
    return 404, {"error": f"unknown tool {name}"}


def rpc_result(req_id, result):
    sys.stdout.write(
        json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}) + "\n"
    )
    sys.stdout.flush()


def rpc_error(req_id, code, message):
    sys.stdout.write(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": code, "message": message},
            }
        )
        + "\n"
    )
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            rpc_error(None, -32700, "parse error")
            continue
        method = req.get("method", "")
        req_id = req.get("id")
        if method == "initialize":
            rpc_result(
                req_id,
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {
                        "name": "mosaicvpn",
                        "version": "1.0.0",
                    },
                },
            )
        elif method == "notifications/initialized":
            continue
        elif method == "ping":
            rpc_result(req_id, {})
        elif method == "tools/list":
            rpc_result(req_id, {"tools": TOOLS})
        elif method == "tools/call":
            name = req.get("params", {}).get("name", "")
            args = req.get("params", {}).get("arguments", {}) or {}
            http_code, payload = call_tool(name, args)
            ok = 200 <= http_code < 300
            rpc_result(
                req_id,
                {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(payload, ensure_ascii=False),
                        }
                    ],
                    "isError": not ok,
                },
            )
        elif method == "resources/list":
            rpc_result(req_id, {"resources": []})
        elif method == "prompts/list":
            rpc_result(req_id, {"prompts": []})
        elif req_id is not None:
            rpc_error(req_id, -32601, f"unknown method {method}")


if __name__ == "__main__":
    main()
