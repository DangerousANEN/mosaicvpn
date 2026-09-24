import 'dart:async';

import 'package:flutter/services.dart';

/// Telegram resilience booster: the embedded tg-ws-proxy engine (MIT) runs a
/// local SOCKS5 server that carries Telegram DC traffic over WebSocket+TLS to
/// Telegram domains behind Cloudflare. Started on demand from settings or
/// automatically alongside the tunnel.
class TgWsBooster {
  TgWsBooster._();

  static const MethodChannel _channel =
      MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');

  static bool _running = false;
  static int _port = 0;

  /// Whether the engine is currently listening on loopback.
  static bool get running => _running;

  /// The loopback SOCKS5 port (valid when [running] is true).
  static int get port => _port;

  static Future<Map<String, dynamic>> start() async {
    try {
      final res = Map<String, dynamic>.from(
        await _channel.invokeMethod('tgwsStart'),
      );
      _running = (res['running'] as bool? ?? false);
      _port = (res['port'] as num?)?.toInt() ?? 0;
      return res;
    } on PlatformException {
      // Platform without the embedded engine (desktop / tests): no-op.
      return {'running': false, 'port': 0};
    } on MissingPluginException {
      return {'running': false, 'port': 0};
    }
  }

  static Future<void> stop() async {
    _running = false;
    _port = 0;
    try {
      await _channel.invokeMethod('tgwsStop');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  static Future<Map<String, dynamic>> status() async {
    try {
      final res = Map<String, dynamic>.from(
        await _channel.invokeMethod('tgwsStatus'),
      );
      _running = (res['running'] as bool? ?? false);
      _port = (res['port'] as num?)?.toInt() ?? 0;
      return res;
    } on PlatformException {
      return {'running': false, 'port': 0};
    } on MissingPluginException {
      return {'running': false, 'port': 0};
    }
  }
}
