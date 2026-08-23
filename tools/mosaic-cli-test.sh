#!/usr/bin/env bash
# mosaic-cli-test.sh — CLI sandbox for MosaicVPN tunnel logic on Windows (git-bash).
# Proves the exact chain the app uses BEFORE touching the app:
#   sing-box (libbox-compatible config) -> ws node from real subscription -> proxied traffic.
#
# Usage:
#   bash mosaic-cli-test.sh proxy     # socks/http inbound test via curl
#   bash mosaic-cli-test.sh tun       # TUN inbound test (requires elevated shell)
set -euo pipefail

WORK="${MOSAIC_CLI_WORK:-$HOME/kwtmp/mosaic-cli}"
SB_BIN="${SING_BOX:-$WORK/sing-box.exe}"
SUB_URL="https://sub.zxc1x1.ru/reftcT_frzSCwhav"
mkdir -p "$WORK"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

fetch_nodes() {
  log "Fetching subscription"
  local raw
  raw=$(curl -sk --max-time 20 -A sing-box "$SUB_URL")
  echo "$raw" | base64 -d 2>/dev/null | grep '^vless://' > "$WORK/nodes.txt" \
    || echo "$raw" | grep '^vless://' > "$WORK/nodes.txt"
  wc -l < "$WORK/nodes.txt" | xargs echo "vless nodes:"
}

build_proxy_config() {
  log "Building sing-box config (proxy mode, ws only — xhttp unsupported by libbox)"
  local ws_url
  ws_url=$(grep 'type=ws' "$WORK/nodes.txt" | head -1)
  [ -n "${ws_url:-}" ] || { echo "NO ws NODE"; exit 1; }
  python3 - "$ws_url" "$(cygpath -w "$WORK/proxy.json")" <<'PYEOF'
import sys, json
from urllib.parse import urlparse, parse_qs, unquote
raw = sys.argv[1]; out = sys.argv[2]
u = urlparse(raw); q = {k: v[0] for k, v in parse_qs(u.query).items()}
host_header = unquote(q.get("host", "")) or u.hostname
path = unquote(q.get("path", "/"))
uuid = u.username
port = u.port or 443
cfg = {
  "log": {"level": "info"},
  "inbounds": [{
      "type": "socks", "tag": "socks-in",
      "listen": "127.0.0.1", "listen_port": 10808
  }],
  "outbounds": [{
      "type": "vless", "tag": "mosaic-ws",
      "server": u.hostname, "server_port": port,
      "uuid": uuid, "flow": q.get("flow", ""),
      "tls": {"enabled": True, "server_name": host_header,
              "insecure": False},
      "transport": {"type": "ws", "path": path,
                    "headers": {"Host": host_header}}
  }]
}
json.dump(cfg, open(out, "w"), indent=2)
print("config:", out)
print(f"node: {u.hostname}:{port} path={path} sni={host_header}")
PYEOF
}

run_proxy_test() {
  build_proxy_config
  local cfg_win; cfg_win=$(cygpath -w "$WORK/proxy.json")
  log "sing-box check"
  "$SB_BIN" check -c "$cfg_win"
  log "Starting sing-box (proxy)"
  "$SB_BIN" run -c "$cfg_win" > "$WORK/singbox.log" 2>&1 &
  SB_PID=$!
  trap 'kill $SB_PID 2>/dev/null || true' EXIT
  sleep 4
  log "Traffic test through socks5 10808"
  ip_direct=$(curl -s --max-time 10 https://api.ipify.org || echo fail)
  echo "direct IP: $ip_direct"
  ip_proxy=$(curl -s --max-time 15 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org || echo fail)
  echo "proxy IP:  $ip_proxy"
  if [ "$ip_proxy" = "$ip_direct" ]; then
    echo "RESULT: FAIL — proxy IP equals direct IP"
    exit 2
  fi
  echo "RESULT: PASS — traffic exits via $ip_proxy"
  kill $SB_PID 2>/dev/null || true
}

run_tun_test() {
  build_tun_config
  log "sing-box check (tun)"
  "$SB_BIN" check -c "$WORK/tun.json"
  log "Starting sing-box with TUN (needs admin)"
  "$SB_BIN" run -c "$WORK/tun.json" > "$WORK/singbox-tun.log" 2>&1 &
  SB_PID=$!
  trap 'kill $SB_PID 2>/dev/null || true' EXIT
  sleep 6
  grep -qiE "error|FATAL" "$WORK/singbox-tun.log" && { echo "singbox errors:"; tail -5 "$WORK/singbox-tun.log"; }
  log "Traffic test via TUN interface"
  ip_tun=$(curl -s --max-time 15 https://api.ipify.org || echo fail)
  echo "routed IP: $ip_tun"
  netsh interface ipv4 show interfaces | grep -A2 wintun || true
  kill $SB_PID 2>/dev/null || true
  echo "RESULT: see routed IP above (must be VPS IP, not home IP)"
}

case "${1:-}" in
  proxy) fetch_nodes; run_proxy_test ;;
  tun)   fetch_nodes; run_tun_test ;;
  *) echo "usage: $0 {proxy|tun}"; exit 1 ;;
esac
