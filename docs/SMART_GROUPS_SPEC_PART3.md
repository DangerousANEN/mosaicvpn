# Спецификация: Разделы 4 и 5

## Раздел 4: sing-box параметры urltest для мобилок и обработка падения всех нод

### 4.1 Теория: как работает urltest в sing-box

```
┌─────────────────────────────────────────────────────────┐
│                    urltest outbound                      │
│                                                         │
│  interval ──► каждые N секунд тестирует все ноды        │
│  tolerance ──► переключается только если разница > N мс │
│  idle_timeout ──► останавливает тест если нет трафика   │
│                                                         │
│  [node_a: 120ms] [node_b: 95ms] [node_c: timeout]      │
│         └──────────────┘              │                 │
│              выбирает b           помечает dead         │
└─────────────────────────────────────────────────────────┘
```

### 4.2 JSON-фрагмент sing-box конфига (мобильная оптимизация)

```json
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "auto-select",
      "outbounds": [
        "node-us-1",
        "node-us-2", 
        "node-de-1",
        "node-sg-1",
        "node-jp-1",
        "fallback-direct"
      ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50,
      "idle_timeout": "30m",
      "interrupt_exist_connections": false
    },

    {
      "type": "urltest",
      "tag": "auto-select-mobile",
      "outbounds": [
        "node-us-1",
        "node-us-2",
        "node-de-1",
        "node-sg-1",
        "node-jp-1",
        "fallback-direct"
      ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "5m",
      "tolerance": 100,
      "idle_timeout": "10m",
      "interrupt_exist_connections": false
    },

    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [
        "auto-select",
        "auto-select-mobile",
        "node-us-1",
        "node-us-2",
        "node-de-1",
        "node-sg-1",
        "node-jp-1",
        "fallback-chain",
        "direct"
      ],
      "default": "auto-select"
    },

    {
      "type": "urltest",
      "tag": "fallback-chain",
      "outbounds": [
        "node-us-1",
        "node-us-2",
        "node-de-1",
        "node-sg-1",
        "node-jp-1"
      ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 10,
      "idle_timeout": "5m",
      "interrupt_exist_connections": true
    },

    {
      "type": "direct",
      "tag": "fallback-direct"
    },

    {
      "type": "block",
      "tag": "fallback-block"
    },

    {
      "type": "vless",
      "tag": "node-us-1",
      "server": "us1.example.com",
      "server_port": 443,
      "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "us1.example.com"
      }
    },

    {
      "type": "vless",
      "tag": "node-us-2",
      "server": "us2.example.com",
      "server_port": 443,
      "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "us2.example.com"
      }
    },

    {
      "type": "vless",
      "tag": "node-de-1",
      "server": "de1.example.com",
      "server_port": 443,
      "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "de1.example.com"
      }
    },

    {
      "type": "vless",
      "tag": "node-sg-1",
      "server": "sg1.example.com",
      "server_port": 443,
      "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "sg1.example.com"
      }
    },

    {
      "type": "vless",
      "tag": "node-jp-1",
      "server": "jp1.example.com",
      "server_port": 443,
      "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "tls": {
        "enabled": true,
        "server_name": "jp1.example.com"
      }
    }
  ],

  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "",
      "external_ui": "",
      "default_mode": "rule"
    },
    "cache_file": {
      "enabled": true,
      "path": "cache.db",
      "store_fakeip": false,
      "store_rdrc": true
    }
  }
}
```

### 4.3 Параметры urltest: мобильная vs десктоп

```
┌──────────────────┬─────────────────┬─────────────────────┐
│ Параметр         │ Desktop         │ Mobile              │
├──────────────────┼─────────────────┼─────────────────────┤
│ interval         │ 3m              │ 5m (батарея)        │
│ tolerance        │ 50ms            │ 100ms (стаб-ть)     │
│ idle_timeout     │ 30m             │ 10m (RAM/батарея)   │
│ interrupt_exist  │ false           │ false               │
│ url              │ gstatic 204     │ gstatic 204         │
└──────────────────┴─────────────────┴─────────────────────┘

Мобильные особенности:
• interval 5m → меньше wake-up радио-модуля
• tolerance 100ms → реже переключения (стабильность TCP)
• idle_timeout 10m → освобождает ресурсы быстрее
• interrupt_exist_connections: false → не рвёт активные соединения
```

### 4.4 Обработка падения ВСЕХ нод

```
Сценарий: все ноды недоступны
                                    
  urltest проверяет ноды            
       │                            
       ▼                            
  все timeout/error                 
       │                            
       ▼                            
  ┌─────────────────────────────┐   
  │  fallback-chain (interval   │   
  │  1m, tolerance 10) тоже     │   
  │  не находит живых нод       │   
  └──────────────┬──────────────┘   
                 │                  
                 ▼                  
  ┌─────────────────────────────┐   
  │  selector выбирает          │   
  │  fallback-direct            │   
  │  (прямое соединение)        │   
  └──────────────┬──────────────┘   
                 │                  
                 ▼                  
  Flutter получает событие через    
  Clash API /proxies endpoint       
  → показывает AllNodesDownWidget   
```

#### 4.4.1 Конфиг для обработки all-nodes-down

```json
{
  "route": {
    "rules": [
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          { "rule_set": "geosite-category-ads-all" }
        ],
        "outbound": "block"
      },
      {
        "rule_set": ["geosite-cn", "geoip-cn"],
        "outbound": "direct"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "override_android_vpn": true
  },

  "outbounds": [
    {
      "type": "urltest",
      "tag": "auto-select",
      "outbounds": ["node-us-1", "node-us-2", "node-de-1"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50,
      "idle_timeout": "30m",
      "interrupt_exist_connections": false
    },
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [
        "auto-select",
        "node-us-1",
        "node-us-2", 
        "node-de-1",
        "direct"
      ],
      "default": "auto-select"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
```

---

## Раздел 5: Замер пинга и отображение в UI

### 5.1 Архитектура замера пинга

```
┌─────────────────────────────────────────────────────────────┐
│                    PingService                               │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │ PreConnect   │    │ Connected    │    │ ClashAPI     │  │
│  │ Pinger       │    │ Pinger       │    │ Poller       │  │
│  │              │    │              │    │              │  │
│  │ dart:io      │    │ HTTP через   │    │ GET /proxies │  │
│  │ RawSocket    │    │ VPN tunnel   │    │ каждые 30s   │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                  │                   │            │
│         └──────────────────┴───────────────────┘           │
│                            │                               │
│                     PingRepository                         │
│                            │                               │
│                     PingNotifier                           │
│                    (Riverpod)                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Полный код Dart/Flutter

#### `lib/models/ping_result.dart`

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'ping_result.freezed.dart';
part 'ping_result.g.dart';

enum PingStatus { idle, measuring, success, timeout, error, allDown }

@freezed
class NodePingResult with _$NodePingResult {
  const factory NodePingResult({
    required String nodeTag,
    required String nodeLabel,
    required PingStatus status,
    int? latencyMs,
    String? errorMessage,
    @Default(false) bool isSelected,
    DateTime? measuredAt,
  }) = _NodePingResult;

  factory NodePingResult.fromJson(Map<String, dynamic> json) =>
      _$NodePingResultFromJson(json);
}

@freezed
class PingState with _$PingState {
  const factory PingState({
    @Default([]) List<NodePingResult> nodes,
    @Default(PingStatus.idle) PingStatus overallStatus,
    @Default(false) bool isAllDown,
    String? selectedNode,
    DateTime? lastUpdated,
  }) = _PingState;
}
```

#### `lib/services/pre_connect_pinger.dart`

```dart
import 'dart:async';
import 'dart:io';

/// Замер пинга ДО подключения VPN через ICMP/TCP-connect
/// Использует TCP SYN к порту сервера (работает без root)
class PreConnectPinger {
  static const Duration _connectTimeout = Duration(seconds: 3);
  static const int _probeCount = 3;

  /// Измеряет RTT через TCP handshake к [host]:[port]
  /// Возвращает медиану из [_probeCount] попыток
  Future<int?> measureTcpRtt({
    required String host,
    required int port,
  }) async {
    final results = <int>[];

    for (int i = 0; i < _probeCount; i++) {
      final rtt = await _singleTcpProbe(host: host, port: port);
      if (rtt != null) {
        results.add(rtt);
      }
      // Небольшая пауза между пробами
      if (i < _probeCount - 1) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    if (results.isEmpty) return null;

    // Возвращаем медиану
    results.sort();
    return results[results.length ~/ 2];
  }

  Future<int?> _singleTcpProbe({
    required String host,
    required int port,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;

    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: _connectTimeout,
      );
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// Параллельный замер для списка нод
  Future<Map<String, int?>> measureAll(
    List<({String tag, String host, int port})> nodes,
  ) async {
    final futures = nodes.map((node) async {
      final rtt = await measureTcpRtt(host: node.host, port: node.port);
      return MapEntry(node.tag, rtt);
    });

    final results = await Future.wait(futures);
    return Map.fromEntries(results);
  }
}
```

#### `lib/services/connected_pinger.dart`

```dart
import 'dart:async';
import 'package:http/http.dart' as http;

/// Замер пинга ВО ВРЕМЯ подключения через HTTP через VPN-туннель
/// Использует gstatic.com/generate_204 (как sing-box urltest)
class ConnectedPinger {
  static const String _testUrl = 'https://www.gstatic.com/generate_204';
  static const Duration _requestTimeout = Duration(seconds: 5);
  static const int _probeCount = 3;

  final http.Client _client;

  ConnectedPinger({http.Client? client}) : _client = client ?? http.Client();

  /// Измеряет реаль