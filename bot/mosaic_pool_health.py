#!/usr/bin/env python3
"""mosaic_pool_health.py — Sing-box Pool Health Verifier & Config Harmonizer v3.

Changes in v3:
- interrupt_exist_connections: False (CRITICAL: prevents tearing down live TCP sessions)
- interval: 3m, tolerance: 50, idle_timeout: 10m
- Safe field access for outbounds (.get('server') / .get('server_port'))
- Non-destructive: keeps config valid even if transient network hiccups occur
"""
import json
import os
import socket
import subprocess
import tempfile

CONFIG = "/etc/sing-box-pool/config.json"

try:
    with open(CONFIG, encoding="utf-8") as stream:
        config = json.load(stream)
except Exception as exc:
    raise SystemExit(f"Failed to load pool config: {exc}")

outbounds = {item.get("tag"): item for item in config.get("outbounds", []) if isinstance(item, dict)}
references = sorted({
    tag
    for group in config.get("outbounds", [])
    if isinstance(group, dict) and group.get("type") == "urltest"
    for tag in group.get("outbounds", [])
})

def alive(tag):
    outbound = outbounds.get(tag, {})
    server = outbound.get("server") or outbound.get("server_address")
    port = outbound.get("server_port") or outbound.get("port")
    if not server or not port:
        return False
    try:
        with socket.create_connection((str(server), int(port)), timeout=2.5):
            return True
    except Exception:
        return False

dead = {tag for tag in references if not alive(tag)}
changed = False

for group in config.get("outbounds", []):
    if not isinstance(group, dict) or group.get("type") != "urltest":
        continue
    old = list(group.get("outbounds", []))
    new = [tag for tag in old if tag not in dead]
    if not new:
        # Refuse to empty out a group completely on transient failure
        continue
    if new != old:
        group["outbounds"] = new
        changed = True

    desired = {
        "interval": "3m",
        "idle_timeout": "10m",
        "tolerance": 50,
        "interrupt_exist_connections": False,
    }
    for key, value in desired.items():
        if group.get(key) != value:
            group[key] = value
            changed = True

if changed:
    fd, temporary = tempfile.mkstemp(prefix="pool.", dir=os.path.dirname(CONFIG), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(config, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        subprocess.run(
            ["/usr/local/bin/sing-box", "check", "-c", temporary],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        os.replace(temporary, CONFIG)
    except Exception as exc:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise SystemExit(f"Health update validation failed: {exc}")

print(f"pool_health changed={int(changed)} checked={len(references)} dead={len(dead)}")
