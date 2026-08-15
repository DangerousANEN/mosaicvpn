import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

/// State exposed by the Android native VpnService runtime.
class AndroidVpnRuntimeState {
  const AndroidVpnRuntimeState({required this.state, this.error});

  final String state;
  final String? error;

  bool get isConnected => state == 'connected';
  bool get isBusy => state == 'connecting';

  factory AndroidVpnRuntimeState.fromMap(Map<Object?, Object?> raw) {
    return AndroidVpnRuntimeState(
      state: raw['state']?.toString() ?? 'disconnected',
      error: raw['error']?.toString(),
    );
  }
}

/// Flutter façade over the Android `MosaicVpnService` MethodChannel.
///
/// The service is intentionally unavailable on non-Android targets. It never
/// synthesizes a connection: `start` hands a validated sing-box JSON document
/// to the native runtime, which owns Android's VpnService TUN file descriptor.
class AndroidVpnService {
  AndroidVpnService._();

  static final AndroidVpnService instance = AndroidVpnService._();
  static const MethodChannel _channel =
      MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');

  bool get isSupported => !kIsWeb && AppPlatform.isAndroid;

  Future<bool> requestPermission() async {
    _ensureSupported();
    return (await _channel.invokeMethod<bool>('prepare')) ?? false;
  }

  Future<AndroidVpnRuntimeState> start(String singBoxConfig) async {
    _ensureSupported();
    final raw = await _channel.invokeMapMethod<Object?, Object?>('start', {
      'config': singBoxConfig,
    });
    return AndroidVpnRuntimeState.fromMap(raw ?? const {});
  }

  Future<AndroidVpnRuntimeState> stop() async {
    _ensureSupported();
    final raw = await _channel.invokeMapMethod<Object?, Object?>('stop');
    return AndroidVpnRuntimeState.fromMap(raw ?? const {});
  }

  Future<AndroidVpnRuntimeState> status() async {
    _ensureSupported();
    final raw = await _channel.invokeMapMethod<Object?, Object?>('status');
    return AndroidVpnRuntimeState.fromMap(raw ?? const {});
  }

  Future<void> validateConfig(String singBoxConfig) async {
    _ensureSupported();
    await _channel
        .invokeMethod<bool>('validateConfig', {'config': singBoxConfig});
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw UnsupportedError(
          'Android VpnService is unavailable on this platform.');
    }
  }
}
