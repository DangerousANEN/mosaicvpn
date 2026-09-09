# MosaicVPN Smart Groups: Эталонная Архитектура

## Оглавление
1. [Автопоиск и сбор серверов](#1-автопоиск-и-сбор-серверов)
2. [Проверка качества и пропинговка](#2-проверка-качества-и-пропинговка)
3. [Выдача кандидатов и балансировка](#3-выдача-кандидатов-и-балансировка)
4. [Автовыбор и Failover на клиенте](#4-автовыбор-и-failover-на-клиенте)
5. [Отображение пинга в UI](#5-отображение-пинга-в-ui)

---

## 1. Автопоиск и сбор серверов

### 1.1 Источники и расписание

```
┌─────────────────────────────────────────────────────────────────┐
│                    PIPELINE СБОРА НОДОВ                         │
│                                                                 │
│  GitHub Repos ──┐                                               │
│  TG Channels ───┼──► Collector ──► Raw Parse ──► Dedup ──► DB  │
│  RSS/API ───────┘                                               │
│                                                                 │
│  Расписание:                                                    │
│  • Tier-1 (GitHub/TG активные): каждые 2 часа                  │
│  • Tier-2 (агрегаторы): каждые 6 часов                         │
│  • Tier-3 (резервные/медленные): раз в сутки                   │
└─────────────────────────────────────────────────────────────────┘
```

**Приоритетные источники:**

| Tier | Источник | Тип | Интервал |
|------|----------|-----|----------|
| 1 | `Au1rxx/free-vpn-subscriptions` | GitHub | 2ч |
| 1 | `mahdibland/V2RayAggregator` | GitHub | 2ч |
| 1 | `barry-far/V2Ray-Configs` | GitHub | 2ч |
| 1 | `yebekhe/TelegramV2rayCollector` | GitHub | 2ч |
| 2 | `soroushmirzaei/telegram-configs-collector` | GitHub | 6ч |
| 2 | `Pawdroid/Free-servers` | GitHub | 6ч |
| 2 | `mfuu/v2ray` | GitHub | 6ч |
| 3 | Публичные TG-каналы (через TDLib) | Telegram | 24ч |

### 1.2 Фильтрация протоколов (sing-box 1.13.14)

```python
# /opt/mosaic-bot/protocol_filter.py

ALLOWED_PROTOCOLS = {
    "vless": {
        "transports": ["ws", "grpc", "tcp", "httpupgrade"],
        "security": ["tls", "reality", "none"],
        # КРИТИЧНО: xhttp НЕ поддерживается в sing-box 1.13.x
        "blocked_transports": ["xhttp", "splithttp"],
    },
    "vmess": {
        "transports": ["ws", "grpc", "tcp", "http"],
        "security": ["tls", "none"],
        "blocked_transports": ["xhttp"],
    },
    "trojan": {
        "transports": ["ws", "grpc", "tcp"],
        "security": ["tls"],  # Trojan без TLS — отброс
    },
    "shadowsocks": {
        # Только поддерживаемые cipher в sing-box 1.13
        "allowed_ciphers": [
            "aes-128-gcm", "aes-256-gcm",
            "chacha20-ietf-poly1305",
            "2022-blake3-aes-128-gcm",
            "2022-blake3-aes-256-gcm",
            "2022-blake3-chacha20-poly1305",
        ],
        "blocked_ciphers": ["rc4", "rc4-md5", "aes-128-cfb", "none"],
    },
    "hysteria2": {
        # Требует UDP — проверяем отдельно
        "requires_udp": True,
    },
}

# Полностью отброшенные протоколы
BLOCKED_PROTOCOLS = [
    "tuic",      # Нестабильная поддержка в 1.13
    "naive",     # Устарел
    "brook",     # Не поддерживается
    "ssh",       # Не VPN-протокол
]

def is_node_allowed(node: dict) -> tuple[bool, str]:
    """
    Возвращает (allowed: bool, reason: str)
    """
    proto = node.get("protocol", "").lower()
    
    if proto in BLOCKED_PROTOCOLS:
        return False, f"blocked_protocol:{proto}"
    
    if proto not in ALLOWED_PROTOCOLS:
        return False, f"unknown_protocol:{proto}"
    
    rules = ALLOWED_PROTOCOLS[proto]
    transport = node.get("transport", "tcp").lower()
    
    if "blocked_transports" in rules and transport in rules["blocked_transports"]:
        return False, f"blocked_transport:{transport}"
    
    if "transports" in rules and transport not in rules["transports"]:
        return False, f"unsupported_transport:{transport}"
    
    # Shadowsocks: проверка cipher
    if proto == "shadowsocks":
        cipher = node.get("cipher", "").lower()
        if cipher in rules.get("blocked_ciphers", []):
            return False, f"blocked_cipher:{cipher}"
        if cipher not in rules.get("allowed_ciphers", []):
            return False, f"unknown_cipher:{cipher}"
    
    return True, "ok"
```

### 1.3 Первичная валидация и дедупликация

```python
# /opt/mosaic-bot/node_validator.py

import ipaddress
import hashlib
from typing import Optional

# Зарезервированные и приватные диапазоны — отброс
PRIVATE_RANGES = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
]

# Наш собственный VPS — НИКОГДА не попадает в пулы
OWN_VPS_IPS = {"5.175.188.152"}

# Подозрительные порты (honeypot-индикаторы)
SUSPICIOUS_PORTS = {22, 23, 25, 110, 143, 3389}

# Порты, типичные для легитимных прокси
ALLOWED_PORT_RANGES = [
    (80, 80), (443, 443), (8080, 8080), (8443, 8443),
    (2053, 2053), (2083, 2083), (2087, 2087), (2096, 2096),
    (1024, 65535),  # широкий диапазон, но с дополнительными проверками
]

def compute_node_fingerprint(node: dict) -> str:
    """
    Дедупликация по (ip, port, protocol, uuid/password).
    Не по raw URI — один сервер может иметь разные remarks.
    """
    key_parts = [
        node.get("server", ""),
        str(node.get("port", "")),
        node.get("protocol", ""),
        node.get("uuid", node.get("password", "")),
        node.get("transport", "tcp"),
    ]
    key = "|".join(key_parts).encode()
    return hashlib.sha256(key).hexdigest()[:16]

def validate_node_basic(node: dict) -> tuple[bool, str]:
    """Первичная валидация без сетевых запросов."""
    
    server = node.get("server", "")
    port = node.get("port", 0)
    
    # 1. Проверка собственного VPS
    if server in OWN_VPS_IPS:
        return False, "own_vps"
    
    # 2. Проверка приватных диапазонов
    try:
        ip = ipaddress.ip_address(server)
        for private_range in PRIVATE_RANGES:
            if ip in private_range:
                return False, f"private_ip:{private_range}"
    except ValueError:
        # Это домен — ок, но проверим базово
        if len(server) < 4 or "." not in server:
            return False, "invalid_hostname"
    
    # 3. Подозрительные порты
    if port in SUSPICIOUS_PORTS:
        return False, f"suspicious_port:{port}"
    
    # 4. Валидность порта
    if not (1 <= port <= 65535):
        return False, f"invalid_port:{port}"
    
    # 5. Обязательные поля по протоколу
    proto = node.get("protocol", "")
    if proto in ("vless", "vmess") and not node.get("uuid"):
        return False, "missing_uuid"
    if proto == "trojan" and not node.get("password"):
        return False, "missing_password"
    if proto == "shadowsocks" and not node.get("password"):
        return False, "missing_ss_password"
    
    return True, "ok"
```

### 1.4 Схема БД (расширение)

```sql
-- Расширение таблицы mosaic_nodes
ALTER TABLE mosaic_nodes ADD COLUMN IF NOT EXISTS
    fingerprint VARCHAR(16) UNIQUE,          -- дедупликация
    source_tier INTEGER DEFAULT 2,           -- 1/2/3
    source_url TEXT,                         -- откуда взят
    protocol VARCHAR(20),
    transport VARCHAR(20),
    country_code CHAR(2),                    -- ISO 3166-1 alpha-2
    asn INTEGER,                             -- Autonomous System Number
    asn_org VARCHAR(100),
    
    -- Метрики качества (обновляются пробером)
    rtt_p50_ms FLOAT,                        -- медианный RTT
    rtt_p95_ms FLOAT,                        -- 95-й перцентиль RTT
    jitter_ms FLOAT,                         -- среднеквадратичный джиттер
    loss_pct FLOAT,                          -- % потерь пакетов
    throughput_mbps FLOAT,                   -- реальная скорость
    
    -- Статус и история
    proxy_ok BOOLEAN DEFAULT FALSE,
    consecutive_failures INTEGER DEFAULT 0,
    last_probe_at TIMESTAMP,
    last_ok_at TIMESTAMP,
    first_seen_at TIMESTAMP DEFAULT NOW(),
    
    -- Составной score для ранжирования
    score_latency FLOAT,
    score_speed FLOAT,
    score_stable FLOAT;

-- Индексы для быстрой выборки кандидатов
CREATE INDEX IF NOT EXISTS idx_nodes_country_ok 
    ON mosaic_nodes(country_code, proxy_ok) 
    WHERE proxy_ok = TRUE;

CREATE INDEX IF NOT EXISTS idx_nodes_score_latency 
    ON mosaic_nodes(score_latency DESC) 
    WHERE proxy_ok = TRUE;

CREATE INDEX IF NOT EXISTS idx_nodes_score_speed 
    ON mosaic_nodes(score_speed DESC) 
    WHERE proxy_ok = TRUE;

CREATE INDEX IF NOT EXISTS idx_nodes_score_stable 
    ON mosaic_nodes(score_stable DESC) 
    WHERE proxy_ok = TRUE;

-- Таблица истории проб (для расчёта аптайма)
CREATE TABLE IF NOT EXISTS mosaic_probe_history (
    id BIGSERIAL PRIMARY KEY,
    node_id INTEGER REFERENCES mosaic_nodes(id),
    probed_at TIMESTAMP DEFAULT NOW(),
    success BOOLEAN,
    rtt_ms FLOAT,
    error_code VARCHAR(50)
);

CREATE INDEX idx_probe_history_node_time 
    ON mosaic_probe_history(node_id, probed_at DESC);

-- Партиционирование по времени (хранить 7 дней)
-- В production: pg_partman или TimescaleDB
```

---

## 2. Проверка качества и пропинговка

### 2.1 Архитектура двухуровневого пробера

```
┌──────────────────────────────────────────────────────────────────┐
│                    ДВУХУРОВНЕВЫЙ ПРОБЕР                          │
│                                                                  │
│  ┌─────────────┐    PASS     ┌──────────────────────────────┐   │
│  │  L4 Prober  │ ──────────► │         L7 Prober            │   │
│  │             │             │                              │   │
│  │ TCP connect │             │  sing-box instance (temp)    │   │
│  │ timeout=3s  │             │  → HTTP GET gstatic 204      │   │
│  │             │             │  → Speed test (1MB chunk)    │   │
│  │ FAIL → skip │             │  → 5 повторов для p50/p95    │   │
│  └─────────────┘             └──────────────────────────────┘   │
│                                                                  │
│  Параллелизм: asyncio + semaphore(50) для L4                    │
│               semaphore(10) для L7 (ресурсоёмко)               │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 L4 Пробер (быстрый отсев)

```python
# /opt/mosaic-bot/prober_l4.py

import asyncio
import time
from dataclasses import dataclass
from typing import Optional

@dataclass
class L4Result:
    node_id: int
    success: bool
    connect_ms: Optional[float]
    error: Optional[str]

async def probe_l4(
    node_id: int,
    host: str,
    port: int,
    timeout: float = 3.0
) -> L4Result:
    """
    TCP SYN → SYN-ACK handshake.
    Не передаёт данные — только проверяет доступность порта.
    """
    start = time.monotonic()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=timeout
        )
        elapsed_ms = (time.monotonic() - start) * 1000
        writer.close()
        await writer.wait_closed()
        return L4Result(node_id, True, elapsed_ms, None)
    except asyncio.TimeoutError:
        return L4Result(node_id, False, None, "timeout")
    except ConnectionRefusedError:
        return L4Result(node_id, False, None, "refused")
    except OSError as e:
        return L4Result(node_id, False, None, f"os_error

# MosaicVPN Smart Groups — Архитектурная спецификация (продолжение)

## 2.3 L7 Пробер

### Концепция: реальный туннель, а не ICMP

```
┌─────────────────────────────────────────────────────────────────┐
│  L7 Prober — измерение через настоящий VPN-туннель              │
│                                                                  │
│  ┌──────────┐   VLESS/VMESS    ┌──────────┐   HTTP GET         │
│  │  Prober  │ ──────────────── │  VPS     │ ──────────────────  │
│  │  sing-box│                  │  sing-box│   204.example.com  │
│  └──────────┘                  └──────────┘                     │
│       │                                                          │
│       ▼                                                          │
│  RTT p50/p95, jitter, loss, throughput                          │
└─────────────────────────────────────────────────────────────────┘
```

**Почему не ICMP/TCP ping:**
- ICMP блокируется на большинстве хостингов
- TCP SYN RTT не отражает реальную задержку туннеля (TLS handshake overhead)
- L7 через реальный туннель = то, что видит пользователь

### Структура L7 Prober

```go
// internal/prober/l7prober.go

package prober

import (
    "context"
    "fmt"
    "math"
    "net/http"
    "sort"
    "sync"
    "time"

    "github.com/mosaicvpn/server/internal/singbox"
    "github.com/mosaicvpn/server/internal/portpool"
)

const (
    ProbeURL          = "http://cp.cloudflare.com/generate_204"
    ProbeURLFallback  = "http://connectivitycheck.gstatic.com/generate_204"
    ProbeTimeout      = 5 * time.Second
    ProbeRounds       = 10  // количество замеров для статистики
    ProbeInterval     = 200 * time.Millisecond
    ThroughputChunkKB = 512 // KB для теста скорости
)

// ProbeResult — результат одного полного цикла измерений
type ProbeResult struct {
    NodeID      string
    Timestamp   time.Time

    // Latency (ms)
    LatencyP50  float64
    LatencyP95  float64
    LatencyMin  float64
    LatencyMax  float64

    // Jitter (RFC 3550)
    Jitter      float64

    // Packet Loss (0.0 – 1.0)
    PacketLoss  float64

    // Throughput (Mbps)
    ThroughputDL float64
    ThroughputUL float64

    // Мета
    ProbePort   int
    Error       error
    RawSamples  []float64
}

// L7Prober управляет жизненным циклом sing-box инстанса для пробинга
type L7Prober struct {
    portPool    *portpool.PortPool
    sbManager   *singbox.Manager
    httpClient  *http.Client
    mu          sync.Mutex
}

func NewL7Prober(pp *portpool.PortPool, sbm *singbox.Manager) *L7Prober {
    return &L7Prober{
        portPool:  pp,
        sbManager: sbm,
    }
}

// Probe — главный метод: поднимает туннель, делает замеры, убивает туннель
func (p *L7Prober) Probe(ctx context.Context, node *Node) (*ProbeResult, error) {
    result := &ProbeResult{
        NodeID:    node.ID,
        Timestamp: time.Now(),
    }

    // 1. Получить свободный порт из пула
    port, err := p.portPool.Acquire()
    if err != nil {
        return nil, fmt.Errorf("portpool exhausted: %w", err)
    }
    result.ProbePort = port
    defer p.portPool.Release(port)

    // 2. Запустить sing-box с конфигом для этой ноды
    sbCtx, sbCancel := context.WithTimeout(ctx, 30*time.Second)
    defer sbCancel()

    instance, err := p.sbManager.StartProbeInstance(sbCtx, node, port)
    if err != nil {
        result.Error = fmt.Errorf("singbox start failed: %w", err)
        return result, result.Error
    }
    defer func() {
        // КРИТИЧНО: всегда убиваем инстанс
        if stopErr := p.sbManager.StopInstance(instance.ID); stopErr != nil {
            // log but don't fail
            log.Errorf("failed to stop probe instance %s: %v", instance.ID, stopErr)
        }
    }()

    // 3. Ждём готовности SOCKS5 прокси
    if err := waitForProxy(sbCtx, port); err != nil {
        result.Error = fmt.Errorf("proxy not ready: %w", err)
        return result, result.Error
    }

    // 4. Создаём HTTP клиент через SOCKS5 туннель
    client := buildTunneledHTTPClient(port, ProbeTimeout)

    // 5. Замеры RTT (ProbeRounds итераций)
    samples, loss := p.measureLatency(ctx, client, ProbeRounds)
    result.RawSamples = samples
    result.PacketLoss = loss

    if len(samples) > 0 {
        result.LatencyP50 = percentile(samples, 50)
        result.LatencyP95 = percentile(samples, 95)
        result.LatencyMin = samples[0]
        result.LatencyMax = samples[len(samples)-1]
        result.Jitter = computeJitterRFC3550(samples)
    }

    // 6. Тест пропускной способности (только если latency OK)
    if result.LatencyP50 < 500 && result.PacketLoss < 0.3 {
        result.ThroughputDL = p.measureThroughput(ctx, client, "download")
        result.ThroughputUL = p.measureThroughput(ctx, client, "upload")
    }

    return result, nil
}

// measureLatency делает N HTTP GET к /generate_204 и собирает RTT
func (p *L7Prober) measureLatency(
    ctx context.Context,
    client *http.Client,
    rounds int,
) (samples []float64, lossRate float64) {

    successful := 0
    raw := make([]float64, 0, rounds)

    for i := 0; i < rounds; i++ {
        select {
        case <-ctx.Done():
            break
        default:
        }

        start := time.Now()
        resp, err := client.Get(ProbeURL)
        elapsed := time.Since(start).Seconds() * 1000 // ms

        if err == nil && resp.StatusCode == http.StatusNoContent {
            resp.Body.Close()
            raw = append(raw, elapsed)
            successful++
        } else {
            if resp != nil {
                resp.Body.Close()
            }
            // Пробуем fallback URL
            start2 := time.Now()
            resp2, err2 := client.Get(ProbeURLFallback)
            elapsed2 := time.Since(start2).Seconds() * 1000

            if err2 == nil && resp2.StatusCode == http.StatusNoContent {
                resp2.Body.Close()
                raw = append(raw, elapsed2)
                successful++
            } else {
                if resp2 != nil {
                    resp2.Body.Close()
                }
            }
        }

        if i < rounds-1 {
            time.Sleep(ProbeInterval)
        }
    }

    sort.Float64s(raw)
    lossRate = float64(rounds-successful) / float64(rounds)
    return raw, lossRate
}

// computeJitterRFC3550 — алгоритм из RFC 3550 §A.8
// J(i) = J(i-1) + (|D(i-1,i)| - J(i-1)) / 16
// где D(i-1,i) = |transit(i) - transit(i-1)|
func computeJitterRFC3550(samples []float64) float64 {
    if len(samples) < 2 {
        return 0
    }
    var jitter float64
    for i := 1; i < len(samples); i++ {
        d := math.Abs(samples[i] - samples[i-1])
        jitter += (d - jitter) / 16.0
    }
    return jitter
}

// percentile вычисляет p-й перцентиль (samples должен быть отсортирован)
func percentile(sorted []float64, p float64) float64 {
    if len(sorted) == 0 {
        return 0
    }
    idx := (p / 100.0) * float64(len(sorted)-1)
    lower := int(math.Floor(idx))
    upper := int(math.Ceil(idx))
    if lower == upper {
        return sorted[lower]
    }
    // Линейная интерполяция
    frac := idx - float64(lower)
    return sorted[lower]*(1-frac) + sorted[upper]*frac
}
```

### Конфигурация sing-box для пробинга

```go
// internal/singbox/probe_config.go

package singbox

import "fmt"

// BuildProbeConfig генерирует минимальный sing-box конфиг для пробинга
// Только SOCKS5 inbound + один outbound к целевой ноде
func BuildProbeConfig(node *Node, localPort int) []byte {
    template := `{
  "log": {
    "level": "error",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-probe-in",
      "listen": "127.0.0.1",
      "listen_port": %d,
      "sniff": false
    }
  ],
  "outbounds": [
    %s,
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["socks-probe-in"],
        "outbound": "%s"
      }
    ],
    "final": "direct"
  }
}`
    outboundJSON := buildOutbound(node)
    return []byte(fmt.Sprintf(template, localPort, outboundJSON, node.Tag))
}

func buildOutbound(node *Node) string {
    switch node.Protocol {
    case "vless":
        return buildVLESSOutbound(node)
    case "vmess":
        return buildVMessOutbound(node)
    case "trojan":
        return buildTrojanOutbound(node)
    case "shadowsocks":
        return buildShadowsocksOutbound(node)
    default:
        panic("unknown protocol: " + node.Protocol)
    }
}

func buildVLESSOutbound(node *Node) string {
    return fmt.Sprintf(`{
      "type": "vless",
      "tag": "%s",
      "server": "%s",
      "server_port": %d,
      "uuid": "%s",
      "flow": "%s",
      "tls": {
        "enabled": true,
        "server_name": "%s",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      },
      "transport": %s
    }`,
        node.Tag, node.Host, node.Port,
        node.UUID, node.Flow, node.SNI,
        buildTransport(node),
    )
}
```

### HTTP клиент через SOCKS5

```go
// internal/prober/http_client.go

package prober

import (
    "context"
    "fmt"
    "net"
    "net/http"
    "time"

    "golang.org/x/net/proxy"
)

func buildTunneledHTTPClient(socksPort int, timeout time.Duration) *http.Client {
    dialer, err := proxy.SOCKS5(
        "tcp",
        fmt.Sprintf("127.0.0.1:%d", socksPort),
        nil,
        proxy.Direct,
    )
    if err != nil {
        panic(err) // конфигурационная ошибка
    }

    transport := &http.Transport{
        DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
            return dialer.(proxy.ContextDialer).DialContext(ctx, network, addr)
        },
        // Отключаем keep-alive — каждый запрос = новое соединение = честный RTT
        DisableKeepAlives:   true,
        MaxIdleConns:        0,
        IdleConnTimeout:     0,
        TLSHandshakeTimeout: timeout,
    }

    return &http.Client{
        Transport: transport,
        Timeout:   timeout,
        // Не следуем редиректам — 204 не должен редиректить
        CheckRedirect: func(req *http.Request, via []*http.Request) error {
            return http.ErrUseLastResponse
        },
    }
}

// waitForProxy ждёт пока SOCKS5 порт станет доступен
func waitForProxy(ctx context.Context, port int) error {
    deadline := time.Now().Add(5 * time.Second)
    for time.Now().Before(deadline) {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
        }

        conn, err := net.DialTimeout("tcp",
            fmt.Sprintf("127.0.0.1:%d", port), 200*time.Millisecond)
        if err == nil {
            conn.Close()
            return nil
        }
        time.Sleep(100 * time.Millisecond)
    }
    return fmt.Errorf("proxy on port %d not ready after 5s", port)
}
```

### Тест пропускной способности

```go
// internal/prober/throughput.go

package prober

import (
    "context"
    "fmt"
    "io"
    "net/http"
    "time"
)

const (
    // Cloudflare speed test endpoints (публичные, без авторизации)
    dlURL = "https://speed.cloudflare.com/__down?bytes=%d"
    ulURL = "https://speed.cloudflare.com/__up"

    dlBytes       = 10 * 1024 * 1024 // 10 MB
    ulBytes       = 5 * 1024 * 1024  // 5 MB
    throughputTTL = 15 * time.Second
)

func (p *L7Prober) measureThroughput(
    ctx context.Context,
    client *http.Client,
    direction string,
) float64 {

    tCtx, cancel := context.WithTimeout(ctx, throughputTTL)
    defer cancel()

    switch direction {
    case "download":
        return measureDownload(tCtx, client)
    case "upload":
        return measureUpload