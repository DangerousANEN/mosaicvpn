import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/daemon_api_base.dart';
import 'smart_group_selector.dart';
import '../models/preferences.dart';

/// Lightweight localhost-only REST API for scripted VPN control.
///
/// Endpoints:
///   GET  /status          — current VPN status (connected, server, latency)
///   GET  /servers         — list available servers
///   GET  /health          — per-server health check results
///   POST /connect/{id}    — connect to a specific server or group
///   POST /disconnect      — disconnect the active tunnel
///   POST /find-stable     — auto-select the most stable reachable server
///
/// All responses are JSON. The server binds to 127.0.0.1 only (never exposed
/// to the network) and is intended for local automation scripts, monitoring
/// dashboards, and CI health checks.
class LocalRestApi {
  LocalRestApi._();
  static final LocalRestApi instance = LocalRestApi._();

  static const int defaultPort = 19080;
  static const String _bindAddress = '127.0.0.1';

  HttpServer? _server;
  DaemonApiBase? _api;
  SmartGroupSelector? _selector;

  /// Exposed for scripted diagnostics via the local REST surface.
  SmartGroupSelector? get selector => _selector;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? defaultPort;

  /// Starts the REST API server. Safe to call multiple times (no-op if running).
  Future<void> start({
    required DaemonApiBase api,
    SmartGroupSelector? selector,
    int port = defaultPort,
  }) async {
    if (_server != null) return;
    _api = api;
    _selector = selector;

    try {
      _server = await HttpServer.bind(_bindAddress, port, shared: true);
      _server!.listen(_handleRequest, onError: (_) {});
    } catch (e) {
      // Port may be in use — try next port
      try {
        _server = await HttpServer.bind(_bindAddress, port + 1, shared: true);
        _server!.listen(_handleRequest, onError: (_) {});
      } catch (_) {
        // Silently fail — REST API is optional, never blocks the main app
        _server = null;
      }
    }
  }

  /// Stops the REST API server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method.toUpperCase();

    // CORS for local scripts
    request.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type')
      ..set('Content-Type', 'application/json; charset=utf-8');

    if (method == 'OPTIONS') {
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }

    try {
      if (method == 'GET' && path == '/status') {
        await _handleStatus(request);
      } else if (method == 'GET' && path == '/servers') {
        await _handleServers(request);
      } else if (method == 'GET' && path == '/health') {
        await _handleHealth(request);
      } else if (method == 'POST' && path.startsWith('/connect/')) {
        await _handleConnect(request, path.substring('/connect/'.length));
      } else if (method == 'POST' && path == '/disconnect') {
        await _handleDisconnect(request);
      } else if (method == 'POST' && path == '/find-stable') {
        await _handleFindStable(request);
      } else if (method == 'GET' && path == '/v1/prefs') {
        await _handleGetPrefs(request);
      } else if (method == 'PUT' && path == '/v1/prefs') {
        await _handlePutPrefs(request);
      } else if (method == 'GET' && path == '/v1/presets') {
        await _handlePresets(request);
      } else if (method == 'GET' && path == '/openapi.json') {
        await _handleOpenApi(request);
      } else {
        _sendJson(request, 404, {
          'error': 'not found',
          'endpoints': [
            'GET /status',
            'GET /servers',
            'GET /health',
            'POST /connect/{id}',
            'POST /disconnect',
            'POST /find-stable',
            'GET /v1/prefs',
            'PUT /v1/prefs',
            'GET /v1/presets',
            'GET /openapi.json',
          ]
        });
      }
    } catch (e) {
      _sendJson(request, 500, {'error': e.toString()});
    }
  }

  // ─── Handlers ──────────────────────────────────────────────────────

  Future<void> _handleStatus(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }

    final status = await api.getStatus();
    _sendJson(request, 200, {
      'connected': status.isConnected,
      'connecting': status.isConnecting,
      'state': status.state,
      'server': status.server != null
          ? {
              'id': status.server!.id,
              'name': status.server!.name,
              'address': status.server!.address,
              'tag': status.server!.tag,
            }
          : null,
      'active_group_id': status.activeGroupId,
      'last_error': status.lastError,
      'tunnel_mode': status.tunnelMode,
    });
  }

  Future<void> _handleServers(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }

    final servers = await api.listServers();
    _sendJson(request, 200, {
      'count': servers.length,
      'servers': servers
          .map((s) => {
                'id': s.id,
                'name': s.name,
                'address': s.address,
                'tag': s.tag,
                'protocol': s.protocol,
                'latency_ms': s.lastTestMS,
              })
          .toList(),
    });
  }

  Future<void> _handleHealth(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }

    // Test all servers and return results
    final results = await api.testAllServers();
    _sendJson(request, 200, {
      'count': results.length,
      'results': results
          .map((r) => {
                'id': r.serverID,
                'success': !r.failed,
                'latency_ms': r.latencyMS,
                'error': r.error,
              })
          .toList(),
    });
  }

  Future<void> _handleConnect(HttpRequest request, String id) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }

    if (id.isEmpty) {
      _sendJson(request, 400, {'error': 'server or group id required'});
      return;
    }

    // Try group connect first, fall back to direct server connect
    try {
      await api.connectGroup(id);
      // Settling delay for TUN setup
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final status = await api.getStatus();
      _sendJson(request, 200, {
        'ok': true,
        'connected': status.isConnected,
        'method': 'group',
        'id': id,
      });
    } catch (_) {
      try {
        await api.connect(id);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final status = await api.getStatus();
        _sendJson(request, 200, {
          'ok': true,
          'connected': status.isConnected,
          'method': 'direct',
          'id': id,
        });
      } catch (e) {
        _sendJson(request, 502, {'ok': false, 'error': e.toString()});
      }
    }
  }

  Future<void> _handleDisconnect(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }

    await api.disconnect();
    _sendJson(request, 200, {'ok': true, 'connected': false});
  }

  Future<void> _handleFindStable(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }

    // Test all servers and pick the one with lowest latency + no errors
    final results = await api.testAllServers();
    final successful = results
        .where((r) => !r.failed && r.latencyMS > 0)
        .toList()
      ..sort((a, b) => a.latencyMS.compareTo(b.latencyMS));

    if (successful.isEmpty) {
      _sendJson(request, 404, {'error': 'no reachable servers found'});
      return;
    }

    final best = successful.first;
    // Connect to the most stable server
    try {
      await api.connect(best.serverID);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final status = await api.getStatus();
      _sendJson(request, 200, {
        'ok': true,
        'connected': status.isConnected,
        'selected_server': {
          'id': best.serverID,
          'latency_ms': best.latencyMS,
        },
        'candidates_tested': results.length,
        'candidates_reachable': successful.length,
      });
    } catch (e) {
      _sendJson(request, 502, {
        'ok': false,
        'error': e.toString(),
        'selected_server_id': best.serverID,
      });
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  // ─── v1: preferences & routing ─────────────────────────────────────

  /// GET /v1/prefs — routing mode + per-app split lists + key flags.
  /// Lets automation and MCP control split tunneling exactly like the UI.
  Future<void> _handleGetPrefs(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }
    final prefs = await api.getPrefs();
    _sendJson(request, 200, _prefsPayload(prefs));
  }

  Map<String, dynamic> _prefsPayload(Preferences prefs) => {
        'routing_mode': prefs.routingMode,
        'bypass_packages': prefs.bypassProcesses,
        'proxy_packages': prefs.proxyPackages,
        'adblock': prefs.adBlock,
        'kill_switch': prefs.killSwitch,
        'auto_connect': prefs.autoConnect,
        'mtu': prefs.mtu,
      };

  /// PUT /v1/prefs — partial update: only provided keys are applied.
  ///
  /// Body (all fields optional):
  /// {
  ///   "routing_mode": "rule",
  ///   "bypass_packages": ["ru.sberbankmobile"],
  ///   "proxy_packages": [],
  ///   "adblock": true, "auto_failover": true, "kill_switch": false
  /// }
  /// Lists replace the whole list (predictable for automation).
  Future<void> _handlePutPrefs(HttpRequest request) async {
    final api = _api;
    if (api == null) {
      _sendJson(request, 503, {'error': 'daemon not available'});
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      _sendJson(request, 400, {'error': 'invalid JSON body'});
      return;
    }
    final current = await api.getPrefs();
    final json = current.toJson();

    const stringKeys = {'routing_mode': 'routing_mode'};
    const boolKeys = {
      'adblock': 'ad_block',
      'auto_connect': 'auto_connect',
      'kill_switch': 'kill_switch',
    };
    const listKeys = {
      'bypass_packages': 'bypass_processes',
      'proxy_packages': 'proxy_packages',
    };
    var touched = 0;
    for (final e in stringKeys.entries) {
      final v = body[e.key];
      if (v is String) {
        json[e.value] = v;
        touched++;
      }
    }
    for (final e in boolKeys.entries) {
      final v = body[e.key];
      if (v is bool) {
        json[e.value] = v;
        touched++;
      }
    }
    for (final e in listKeys.entries) {
      final v = body[e.key];
      if (v is List) {
        json[e.value] = v.whereType<String>().toList();
        touched++;
      }
    }
    if (touched == 0) {
      _sendJson(request, 400, {
        'error': 'no supported fields',
        'supported': [
          ...stringKeys.keys,
          ...boolKeys.keys,
          ...listKeys.keys,
        ],
      });
      return;
    }
    final updated = await api.setPrefs(json);
    _sendJson(request, 200, {
      'updated': touched,
      'prefs': _prefsPayload(updated),
    });
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    try {
      final raw = await utf8.decoder.bind(request).join();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// GET /v1/presets — named routing presets (global/rule/direct bundles).
  Future<void> _handlePresets(HttpRequest request) async {
    final prefs = await _api?.getPrefs();
    _sendJson(request, 200, {
      'current_routing_mode': prefs?.routingMode,
      'builtin': [
        {
          'id': 'global',
          'name': 'Все через VPN',
          'description': 'Весь трафик устройства идет через VPN',
        },
        {
          'id': 'rule',
          'name': 'По правилам',
          'description':
              'Приложения и сайты делятся между VPN и прямым доступом',
        },
        {
          'id': 'direct',
          'name': 'Без VPN',
          'description': 'Трафик идет напрямую (туннель не используется)',
        },
      ],
    });
  }

  /// GET /openapi.json — machine-readable contract for this local API.
  Future<void> _handleOpenApi(HttpRequest request) async {
    _sendJson(request, 200, {
      'openapi': '3.1.0',
      'info': {
        'title': 'MosaicVPN Local API',
        'version': '1.0.0',
        'description': 'Localhost-only control API of the MosaicVPN client. '
            'Binds 127.0.0.1:19080 (or 19081 when busy). Identical surface '
            'on Windows, Linux and Android.',
      },
      'servers': [
        {'url': 'http://127.0.0.1:19080'},
      ],
      'paths': {
        '/status': {
          'get': {
            'summary': 'Current tunnel status',
            'operationId': 'getStatus',
          },
        },
        '/servers': {
          'get': {
            'summary': 'List servers with latency',
            'operationId': 'listServers',
          },
        },
        '/health': {
          'get': {
            'summary': 'Probe every server',
            'operationId': 'healthCheck',
          },
        },
        '/connect/{id}': {
          'post': {
            'summary': 'Connect to server or group by id',
            'operationId': 'connect',
            'parameters': [
              {
                'name': 'id',
                'in': 'path',
                'required': true,
                'schema': {'type': 'string'},
              },
            ],
          },
        },
        '/disconnect': {
          'post': {'summary': 'Drop the tunnel', 'operationId': 'disconnect'},
        },
        '/find-stable': {
          'post': {
            'summary': 'Auto-connect to the most stable server',
            'operationId': 'findStable',
          },
        },
        '/v1/prefs': {
          'get': {
            'summary': 'Read routing preferences (incl. split tunneling)',
            'operationId': 'getPrefs',
          },
          'put': {
            'summary': 'Update routing preferences (partial)',
            'operationId': 'putPrefs',
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {'\$ref': '#/components/schemas/Prefs'},
                },
              },
            },
          },
        },
        '/v1/presets': {
          'get': {
            'summary': 'Built-in routing presets',
            'operationId': 'listPresets',
          },
        },
      },
      'components': {
        'schemas': {
          'Prefs': {
            'type': 'object',
            'properties': {
              'routing_mode': {
                'type': 'string',
                'enum': ['global', 'rule', 'direct'],
              },
              'bypass_packages': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Apps excluded from VPN (banks etc.)',
              },
              'proxy_packages': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Only these apps go through VPN',
              },
              'adblock': {'type': 'boolean'},
              'auto_connect': {'type': 'boolean'},
              'kill_switch': {'type': 'boolean'},
            },
          },
        },
      },
    });
  }

  void _sendJson(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.write(jsonEncode(body));
    request.response.close();
  }
}
