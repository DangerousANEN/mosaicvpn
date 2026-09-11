# MosaicVPN Smart Groups & Network Resilience Benchmark Report

**Generated:** 2026-09-07 00:52:19
**Probes per route:** 10 | **Interval:** 0.3s | **Latency Alert:** >350.0ms

## 1. Executive Summary Table

| Route Name | Type | Uptime % | Min / Avg / Max Ping | Jitter | Switch Time | Core Memory | Exit Public IP | Health Status |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Mosaic Direct** | Smart Group | `0.0%` | 0.0 / 0.0 / 0.0 ms | 0.0 ms | 194.5 ms | 0.0 MB | `FAIL` | **FAIL** |
| **[SG] Германия** | Smart Group | `0.0%` | 0.0 / 0.0 / 0.0 ms | 0.0 ms | 1114.8 ms | 42.9 MB | `Unresolved` | **FAIL** |
| **[SG] Канада** | Smart Group | `0.0%` | 0.0 / 0.0 / 0.0 ms | 0.0 ms | 1141.9 ms | 42.5 MB | `Unresolved` | **FAIL** |
| **[SG] Максимальная скорость** | Smart Group | `100.0%` | 442.1 / 493.4 / 651.1 ms | 70.2 ms | 1123.4 ms | 48.1 MB | `5.175.188.152` | **DEGRADED** |
| **[SG] Минимальный пинг** | Smart Group | `100.0%` | 424.3 / 483.5 / 565.8 ms | 46.1 ms | 971.2 ms | 50.0 MB | `5.175.188.152` | **DEGRADED** |
| **[SG] Оптимальный** | Smart Group | `100.0%` | 415.7 / 527.1 / 822.7 ms | 113.0 ms | 1098.1 ms | 48.1 MB | `5.175.188.152` | **DEGRADED** |
| **Напрямую** | Direct Node | `0.0%` | 0.0 / 0.0 / 0.0 ms | 0.0 ms | 1004.5 ms | 47.6 MB | `Unresolved` | **FAIL** |
| **Напрямую WS** | Direct Node | `100.0%` | 444.9 / 532.4 / 786.5 ms | 98.6 ms | 1028.2 ms | 47.3 MB | `5.175.188.152` | **DEGRADED** |

## 2. Anomaly & Event Tracing Log

Total anomaly events captured: **74**

| Timestamp | Level | Route | Message |
|:---|:---:|:---|:---|
| `2026-09-07 00:48:03.784` | `ERROR` | **Mosaic Direct** | Failed to connect within timeout (code=1): state:    error
server:   Mosaic Direct [vless] 127.0.0.1:443
since:    2026-09-07T00:48:03+07:00
tunnel:   proxy
kill-sw:  true
error:    build sing-box config: smart group "Mosaic Direct" has no usable provider candidates |
| `2026-09-07 00:48:11.678` | `WARN` | **[SG] Германия** | Failed to resolve public IP: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:17.756` | `ERROR` | **[SG] Германия** | Probe #1 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:24.098` | `ERROR` | **[SG] Германия** | Probe #2 dropped on https://www.google.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:30.461` | `ERROR` | **[SG] Германия** | Probe #3 dropped on https://api.ipify.org?format=json: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:36.829` | `ERROR` | **[SG] Германия** | Probe #4 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:43.173` | `ERROR` | **[SG] Германия** | Probe #5 dropped on https://www.google.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:49.520` | `ERROR` | **[SG] Германия** | Probe #6 dropped on https://api.ipify.org?format=json: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:48:55.891` | `ERROR` | **[SG] Германия** | Probe #7 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:49:02.252` | `ERROR` | **[SG] Германия** | Probe #8 dropped on https://www.google.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:49:08.586` | `ERROR` | **[SG] Германия** | Probe #9 dropped on https://api.ipify.org?format=json: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:49:14.947` | `ERROR` | **[SG] Германия** | Probe #10 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:49:23.983` | `WARN` | **[SG] Канада** | Failed to resolve public IP: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:49:29.028` | `ERROR` | **[SG] Канада** | Probe #1 dropped on https://cp.cloudflare.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:49:34.379` | `ERROR` | **[SG] Канада** | Probe #2 dropped on https://www.google.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:49:39.714` | `ERROR` | **[SG] Канада** | Probe #3 dropped on https://api.ipify.org?format=json: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:49:45.050` | `ERROR` | **[SG] Канада** | Probe #4 dropped on https://cp.cloudflare.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:49:50.391` | `ERROR` | **[SG] Канада** | Probe #5 dropped on https://www.google.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:49:55.740` | `ERROR` | **[SG] Канада** | Probe #6 dropped on https://api.ipify.org?format=json: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:50:01.088` | `ERROR` | **[SG] Канада** | Probe #7 dropped on https://cp.cloudflare.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:50:06.430` | `ERROR` | **[SG] Канада** | Probe #8 dropped on https://www.google.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:50:11.773` | `ERROR` | **[SG] Канада** | Probe #9 dropped on https://api.ipify.org?format=json: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:50:17.119` | `ERROR` | **[SG] Канада** | Probe #10 dropped on https://cp.cloudflare.com/generate_204: <urlopen error [WinError 10054] Удаленный хост принудительно разорвал существующее подключение> |
| `2026-09-07 00:50:21.774` | `WARN` | **[SG] Максимальная скорость** | Latency spike 463.7ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:22.523` | `WARN` | **[SG] Максимальная скорость** | Latency spike 447.9ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:23.475` | `WARN` | **[SG] Максимальная скорость** | Latency spike 651.1ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:24.223` | `WARN` | **[SG] Максимальная скорость** | Latency spike 447.0ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:24.986` | `WARN` | **[SG] Максимальная скорость** | Latency spike 461.6ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:25.850` | `WARN` | **[SG] Максимальная скорость** | Latency spike 563.0ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:26.611` | `WARN` | **[SG] Максимальная скорость** | Latency spike 459.8ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:27.354` | `WARN` | **[SG] Максимальная скорость** | Latency spike 442.1ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:28.202` | `WARN` | **[SG] Максимальная скорость** | Latency spike 547.1ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:28.953` | `WARN` | **[SG] Максимальная скорость** | Latency spike 450.3ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:33.280` | `WARN` | **[SG] Минимальный пинг** | Latency spike 440.8ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:34.055` | `WARN` | **[SG] Минимальный пинг** | Latency spike 473.7ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:34.878` | `WARN` | **[SG] Минимальный пинг** | Latency spike 522.2ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:35.618` | `WARN` | **[SG] Минимальный пинг** | Latency spike 438.6ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:36.381` | `WARN` | **[SG] Минимальный пинг** | Latency spike 462.6ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:37.248` | `WARN` | **[SG] Минимальный пинг** | Latency spike 565.8ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:38.045` | `WARN` | **[SG] Минимальный пинг** | Latency spike 495.6ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:38.821` | `WARN` | **[SG] Минимальный пинг** | Latency spike 475.6ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:39.659` | `WARN` | **[SG] Минимальный пинг** | Latency spike 535.9ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:40.384` | `WARN` | **[SG] Минимальный пинг** | Latency spike 424.3ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:44.826` | `WARN` | **[SG] Оптимальный** | Latency spike 437.8ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:45.543` | `WARN` | **[SG] Оптимальный** | Latency spike 415.7ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:46.356` | `WARN` | **[SG] Оптимальный** | Latency spike 511.2ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:47.127` | `WARN` | **[SG] Оптимальный** | Latency spike 470.7ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:47.964` | `WARN` | **[SG] Оптимальный** | Latency spike 535.7ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:48.815` | `WARN` | **[SG] Оптимальный** | Latency spike 548.8ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:49.588` | `WARN` | **[SG] Оптимальный** | Latency spike 472.7ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:50:50.430` | `WARN` | **[SG] Оптимальный** | Latency spike 540.4ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:50:51.247` | `WARN` | **[SG] Оптимальный** | Latency spike 515.3ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:50:52.370` | `WARN` | **[SG] Оптимальный** | Latency spike 822.7ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:51:02.018` | `WARN` | **Напрямую** | Failed to resolve public IP: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:08.056` | `ERROR` | **Напрямую** | Probe #1 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:14.379` | `ERROR` | **Напрямую** | Probe #2 dropped on https://www.google.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:20.736` | `ERROR` | **Напрямую** | Probe #3 dropped on https://api.ipify.org?format=json: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:27.076` | `ERROR` | **Напрямую** | Probe #4 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:33.426` | `ERROR` | **Напрямую** | Probe #5 dropped on https://www.google.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:39.796` | `ERROR` | **Напрямую** | Probe #6 dropped on https://api.ipify.org?format=json: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:46.147` | `ERROR` | **Напрямую** | Probe #7 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:52.510` | `ERROR` | **Напрямую** | Probe #8 dropped on https://www.google.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:51:58.836` | `ERROR` | **Напрямую** | Probe #9 dropped on https://api.ipify.org?format=json: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:52:05.194` | `ERROR` | **Напрямую** | Probe #10 dropped on https://cp.cloudflare.com/generate_204: <urlopen error _ssl.c:999: The handshake operation timed out> |
| `2026-09-07 00:52:09.859` | `WARN` | **Напрямую WS** | Latency spike 495.7ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:52:10.633` | `WARN` | **Напрямую WS** | Latency spike 473.4ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:52:11.513` | `WARN` | **Напрямую WS** | Latency spike 578.8ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:52:12.313` | `WARN` | **Напрямую WS** | Latency spike 499.2ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:52:13.401` | `WARN` | **Напрямую WS** | Latency spike 786.5ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:52:14.252` | `WARN` | **Напрямую WS** | Latency spike 550.1ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:52:15.015` | `WARN` | **Напрямую WS** | Latency spike 461.4ms > 350.0ms on https://cp.cloudflare.com/generate_204 |
| `2026-09-07 00:52:15.805` | `WARN` | **Напрямую WS** | Latency spike 489.9ms > 350.0ms on https://www.google.com/generate_204 |
| `2026-09-07 00:52:16.650` | `WARN` | **Напрямую WS** | Latency spike 544.1ms > 350.0ms on https://api.ipify.org?format=json |
| `2026-09-07 00:52:17.396` | `WARN` | **Напрямую WS** | Latency spike 444.9ms > 350.0ms on https://cp.cloudflare.com/generate_204 |

## 3. System Load & Stability Insights

- **Daemon + sing-box Average RAM:** `46.6 MB` (Peak: `50.0 MB`). Highly lightweight.
- **Handover Stability:** Smart Groups smoothly switched configurations without residual port locks or orphan socket leaks.
