import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/daemon_api_base.dart';
import '../models/models.dart';
import '../platform/app_platform.dart';
import 'smart_group_selector.dart';

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
      } else {
        _sendJson(request, 404, {'error': 'not found', 'endpoints': [
          'GET /status', 'GET /servers', 'GET /health',
          'POST /connect/{id}', 'POST /disconnect', 'POST /find-stable',
        ]});
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
      'server': status.server != null ? {
        'id': status.server!.id,
        'name': status.server!.name,
        'address': status.server!.address,
        'tag': status.server!.tag,
      } : null,
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
      'servers': servers.map((s) => {
        'id': s.id,
        'name': s.name,
        'address': s.address,
        'tag': s.tag,
        'protocol': s.protocol,
        'latency_ms': s.latencyMs,
      }).toList(),
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
      'results': results.map((r) => {
        'id': r.id,
        'success': r.success,
        'latency_ms': r.latencyMs,
        'error': r.error,
      }).toList(),
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
        .where((r) => r.success && r.latencyMs > 0)
        .toList()
      ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));

    if (successful.isEmpty) {
      _sendJson(request, 404, {'error': 'no reachable servers found'});
      return;
    }

    final best = successful.first;
    // Connect to the most stable server
    try {
      await api.connect(best.id);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final status = await api.getStatus();
      _sendJson(request, 200, {
        'ok': true,
        'connected': status.isConnected,
        'selected_server': {
          'id': best.id,
          'latency_ms': best.latencyMs,
        },
        'candidates_tested': results.length,
        'candidates_reachable': successful.length,
      });
    } catch (e) {
      _sendJson(request, 502, {
        'ok': false,
        'error': e.toString(),
        'selected_server_id': best.id,
      });
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  void _sendJson(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.write(jsonEncode(body));
    request.response.close();
  }
}
