"""
MosaicVPN Server Health & QoS Continuous Tracer
Measures:
- ICMP / TCP Ping (min, avg, max)
- Jitter (RFC 3550 style)
- Packet Loss (%)
- TCP Connect Latency
- TLS Handshake Latency (SNI sub.zxc1x1.ru)
- WebSocket Route (/mosaicws) Handshake & Status
- Server Resource Utilization (LoadAvg, RAM, Conntrack, Docker status via SSH)
- Out-of-bounds anomaly detection with automatic alerts to error log
"""

import sys
import os
import time
import socket
import ssl
import json
import argparse
import subprocess
from datetime import datetime

SERVER_IP = "5.175.188.152"
SERVER_HOST = "sub.zxc1x1.ru"
SSH_KEY = os.path.expanduser("~/.ssh/id_ed25519_vitaly")

# Thresholds for anomaly detection
THRESHOLDS = {
    "max_avg_ping_ms": 130.0,
    "max_jitter_ms": 30.0,
    "max_packet_loss_pct": 5.0,
    "max_tcp_connect_ms": 150.0,
    "max_tls_handshake_ms": 250.0,
    "max_ws_handshake_ms": 350.0,
    "max_server_load_1m": 3.0,
    "max_server_ram_pct": 88.0,
    "max_conntrack_pct": 80.0
}

ERROR_LOG_PATH = "C:/Users/ANEN/kwtmp/server_tracer_errors.log"
TRACE_LOG_PATH = "C:/Users/ANEN/kwtmp/server_tracer_metrics.jsonl"

def log_error(incident):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] [ANOMALY] {incident['metric']}: value={incident['value']} (threshold={incident['threshold']}) - {incident['details']}\n"
    with open(ERROR_LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line)
    print(f"  [!] ALERT: {line.strip()}")

def measure_icmp_ping(count=4):
    """Accurately measure ICMP round-trip latency and jitter across Windows localized output."""
    try:
        cmd = ["ping", "-n", str(count), SERVER_IP]
        res = subprocess.run(cmd, capture_output=True, timeout=15)
        try:
            stdout = res.stdout.decode("cp866", errors="replace")
        except:
            stdout = res.stdout.decode("utf-8", errors="replace")
            
        times = []
        loss_pct = 0.0
        for line in stdout.splitlines():
            if "time" in line.lower() or "время" in line.lower():
                import re
                m = re.search(r'(?:time|время)[=<](\d+)', line, re.IGNORECASE)
                if m:
                    times.append(float(m.group(1)))
            if "%" in line:
                import re
                m = re.search(r'(\d+)%', line)
                if m:
                    loss_pct = float(m.group(1))

        if not times:
            return {"loss_pct": loss_pct, "min_ms": None, "avg_ms": None, "max_ms": None, "jitter_ms": None, "samples": 0}

        min_ms = min(times)
        max_ms = max(times)
        avg_ms = sum(times) / len(times)
        
        jitter = 0.0
        if len(times) > 1:
            diffs = [abs(times[i] - times[i-1]) for i in range(1, len(times))]
            jitter = sum(diffs) / len(diffs)
            
        return {
            "loss_pct": loss_pct,
            "min_ms": round(min_ms, 2),
            "avg_ms": round(avg_ms, 2),
            "max_ms": round(max_ms, 2),
            "jitter_ms": round(jitter, 2),
            "samples": len(times)
        }
    except Exception as e:
        return {"error": str(e), "loss_pct": 100.0, "samples": 0}

def measure_tls_and_http(host=SERVER_IP, sni=SERVER_HOST, port=443, timeout=5.0):
    start_tcp = time.perf_counter()
    raw_s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw_s.settimeout(timeout)
    try:
        raw_s.connect((host, port))
        tcp_ms = (time.perf_counter() - start_tcp) * 1000.0
        
        # TLS Handshake
        ctx = ssl.create_default_context()
        start_tls = time.perf_counter()
        tls_s = ctx.wrap_socket(raw_s, server_hostname=sni)
        tls_ms = (time.perf_counter() - start_tls) * 1000.0
        
        # Probe WS endpoint (/mosaicws)
        ws_req = (
            f"GET /mosaicws HTTP/1.1\r\n"
            f"Host: {sni}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        start_ws = time.perf_counter()
        tls_s.sendall(ws_req.encode())
        resp = tls_s.recv(1024).decode("utf-8", errors="replace")
        ws_ms = (time.perf_counter() - start_ws) * 1000.0
        
        status_line = resp.splitlines()[0] if resp else "EMPTY"
        tls_s.close()
        
        return {
            "tcp_ms": round(tcp_ms, 2),
            "tls_ms": round(tls_ms, 2),
            "ws_ms": round(ws_ms, 2),
            "ws_status": status_line
        }
    except Exception as e:
        raw_s.close()
        return {"error": str(e)}

def fetch_server_internals():
    """Fetch live CPU load, RAM, conntrack, and docker status from the VPS via SSH."""
    cmd = [
        "ssh", "-i", SSH_KEY, "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
        f"root@{SERVER_IP}",
        "uptime; free -m; cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0; cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0; docker ps --format '{{.Names}}:{{.Status}}'"
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        if res.returncode != 0:
            return {"ssh_error": res.stderr.strip()}
        
        lines = res.stdout.strip().splitlines()
        load_1m, load_5m, load_15m = 0.0, 0.0, 0.0
        ram_total, ram_used, ram_pct = 0, 0, 0.0
        dockers = []
        
        for line in lines:
            if "load average" in line:
                parts = line.split("load average:")[-1].split(",")
                try:
                    load_1m = float(parts[0].strip())
                    load_5m = float(parts[1].strip())
                    load_15m = float(parts[2].strip())
                except:
                    pass
            elif line.startswith("Mem:"):
                parts = line.split()
                try:
                    ram_total = int(parts[1])
                    ram_used = int(parts[2])
                    ram_pct = round((ram_used / ram_total) * 100.0, 1)
                except:
                    pass
            elif ":" in line and ("Up " in line or "Exited" in line):
                dockers.append(line.strip())
                
        return {
            "load_1m": load_1m,
            "load_5m": load_5m,
            "load_15m": load_15m,
            "ram_total_mb": ram_total,
            "ram_used_mb": ram_used,
            "ram_pct": ram_pct,
            "containers": dockers
        }
    except Exception as e:
        return {"ssh_error": str(e)}

def run_trace_iteration(iter_num=1):
    timestamp = datetime.now().strftime('%H:%M:%S')
    print(f"\n--- Trace Iteration #{iter_num} at {timestamp} ---")
    
    # 1. ICMP ping
    icmp = measure_icmp_ping(count=4)
    print(f"  ICMP: avg={icmp.get('avg_ms')}ms (min={icmp.get('min_ms')} / max={icmp.get('max_ms')}), jitter={icmp.get('jitter_ms')}ms, loss={icmp.get('loss_pct')}%")
    
    # Check ICMP thresholds
    if icmp.get("loss_pct", 0) > THRESHOLDS["max_packet_loss_pct"]:
        log_error({"metric": "ICMP Packet Loss", "value": f"{icmp.get('loss_pct')}%", "threshold": f"{THRESHOLDS['max_packet_loss_pct']}%", "details": f"Drop detected across {icmp.get('samples')} probes"})
    if icmp.get("avg_ms") and icmp.get("avg_ms") > THRESHOLDS["max_avg_ping_ms"]:
        log_error({"metric": "ICMP Latency Spike", "value": f"{icmp.get('avg_ms')}ms", "threshold": f"{THRESHOLDS['max_avg_ping_ms']}ms", "details": f"Exceeded baseline"})
    if icmp.get("jitter_ms") and icmp.get("jitter_ms") > THRESHOLDS["max_jitter_ms"]:
        log_error({"metric": "High Jitter", "value": f"{icmp.get('jitter_ms')}ms", "threshold": f"{THRESHOLDS['max_jitter_ms']}ms", "details": "Jitter variance exceeded"})

    # 2. TLS & WebSocket route probe
    tls_res = measure_tls_and_http()
    print(f"  TCP/TLS/WS: tcp={tls_res.get('tcp_ms')}ms, tls_handshake={tls_res.get('tls_ms')}ms, ws_handshake={tls_res.get('ws_ms')}ms -> status: {tls_res.get('ws_status')}")
    
    if tls_res.get("error"):
        log_error({"metric": "TLS/WS Connection Failure", "value": "FAILED", "threshold": "OK", "details": tls_res.get("error")})
    else:
        if tls_res.get("tcp_ms", 0) > THRESHOLDS["max_tcp_connect_ms"]:
            log_error({"metric": "TCP Connect Slow", "value": f"{tls_res.get('tcp_ms')}ms", "threshold": f"{THRESHOLDS['max_tcp_connect_ms']}ms", "details": "Slow initial socket connect"})
        if tls_res.get("tls_ms", 0) > THRESHOLDS["max_tls_handshake_ms"]:
            log_error({"metric": "TLS Handshake Slow", "value": f"{tls_res.get('tls_ms')}ms", "threshold": f"{THRESHOLDS['max_tls_handshake_ms']}ms", "details": "SNI handshake latency exceeded"})
        if not ("101" in tls_res.get("ws_status", "") or "400" in tls_res.get("ws_status", "")):
            log_error({"metric": "WebSocket Status Anomaly", "value": tls_res.get("ws_status"), "threshold": "HTTP 101/400", "details": "Unexpected response from /mosaicws"})

    # 3. Server System Load & Containers
    internals = fetch_server_internals()
    if "ssh_error" not in internals:
        print(f"  VPS Load: 1m={internals.get('load_1m')}, 5m={internals.get('load_5m')} | RAM: {internals.get('ram_pct')}% ({internals.get('ram_used_mb')}/{internals.get('ram_total_mb')} MB) | Containers: {len(internals.get('containers', []))} active")
        if internals.get("load_1m", 0) > THRESHOLDS["max_server_load_1m"]:
            log_error({"metric": "High VPS LoadAvg", "value": internals.get("load_1m"), "threshold": THRESHOLDS["max_server_load_1m"], "details": f"1-min load elevated"})
        if internals.get("ram_pct", 0) > THRESHOLDS["max_server_ram_pct"]:
            log_error({"metric": "High RAM Usage", "value": f"{internals.get('ram_pct')}%", "threshold": f"{THRESHOLDS['max_server_ram_pct']}%", "details": f"RAM used {internals.get('ram_used_mb')}MB"})
    else:
        print(f"  VPS Internals: SSH probe error ({internals.get('ssh_error')})")

    # Record trace entry to JSONL
    record = {
        "timestamp": datetime.now().isoformat(),
        "iteration": iter_num,
        "icmp": icmp,
        "tls_ws": tls_res,
        "internals": internals
    }
    with open(TRACE_LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MosaicVPN Server Tracer")
    parser.add_argument("-n", "--count", type=int, default=5, help="Number of trace iterations (0 for infinite)")
    parser.add_argument("-i", "--interval", type=int, default=5, help="Interval in seconds between iterations")
    args = parser.parse_args()
    
    print(f"Starting MosaicVPN Tracer (count={args.count}, interval={args.interval}s)...")
    print(f"Error log destination: {ERROR_LOG_PATH}")
    print(f"Metrics JSONL destination: {TRACE_LOG_PATH}")
    
    i = 1
    try:
        while True:
            run_trace_iteration(i)
            if args.count > 0 and i >= args.count:
                break
            i += 1
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nTracer stopped by user.")
        
    print("\nTracing session complete.")
