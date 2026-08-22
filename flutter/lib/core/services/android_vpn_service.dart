import 'dart:async';

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
  AndroidVpnService._() {
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  static final AndroidVpnService instance = AndroidVpnService._();
  static const MethodChannel _channel =
      MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');

  final _enrollmentCallbacks = StreamController<Uri>.broadcast();
  final _authCallbacks = StreamController<Uri>.broadcast();

  /// Emits a browser enrollment callback as soon as Android delivers it to an
  /// already-running activity. The URI remains available to the single-use
  /// consume method, which performs the security-critical code exchange.
  Stream<Uri> get enrollmentCallbacks => _enrollmentCallbacks.stream;

  /// Equivalent immediate signal for website-first account sign-in callbacks.
  Stream<Uri> get authCallbacks => _authCallbacks.stream;

  bool get isSupported => !kIsWeb && AppPlatform.isAndroid;

  Future<Object?> _handleNativeCallback(MethodCall call) async {
    final raw = call.arguments?.toString();
    final callback = raw == null ? null : Uri.tryParse(raw);
    if (callback == null) return false;
    switch (call.method) {
      case 'enrollmentCallbackReceived':
        _enrollmentCallbacks.add(callback);
        return true;
      case 'authCallbackReceived':
        _authCallbacks.add(callback);
        return true;
      default:
        return false;
    }
  }

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

  /// Validates the config, starts the service and waits for its first terminal
  /// runtime state. Native Android service startup is asynchronous, so callers
  /// must not treat the initial `connecting` reply as a ready tunnel.
  Future<AndroidVpnRuntimeState> startAndAwaitReady(
    String singBoxConfig, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await validateConfig(singBoxConfig);
    var state = await start(singBoxConfig);
    final deadline = DateTime.now().add(timeout);
    while (state.isBusy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      state = await status();
    }
    if (state.isBusy) {
      return const AndroidVpnRuntimeState(
        state: 'error',
        error: 'Android VPN runtime не подтвердил запуск за отведённое время.',
      );
    }
    return state;
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

  /// Returns native runtime log lines newer than [afterSeq] together with the
  /// current high-water mark. The libbox event stream is not wired on the
  /// Android hosted facade, so this incremental snapshot is what the in-app
  /// logs screen renders on Android.
  Future<({List<(int, String)> lines, int lastSeq})> readNativeLogs(
      {int afterSeq = 0}) async {
    _ensureSupported();
    final raw = await _channel
        .invokeListMethod<Map<Object?, Object?>>('readNativeLogs', {
      'afterSeq': afterSeq,
    });
    final lines = <(int, String)>[];
    var last = afterSeq;
    for (final entry in raw ?? const <Map<Object?, Object?>>[]) {
      final seq = (entry['seq'] as num?)?.toInt() ?? 0;
      final line = entry['line']?.toString() ?? '';
      lines.add((seq, line));
      if (seq > last) last = seq;
    }
    return (lines: lines, lastSeq: last);
  }

  Future<void> validateConfig(String singBoxConfig) async {
    _ensureSupported();
    await _channel
        .invokeMethod<bool>('validateConfig', {'config': singBoxConfig});
  }

  /// Returns and clears the browser callback URI for website-first login. The
  /// URI carries only a short-lived code and state, never account credentials.
  Future<Uri?> consumeAuthCallback() => _consumeCallback('consumeAuthCallback');

  /// Returns and clears the dedicated browser enrollment callback. A separate
  /// native slot ensures an Add-to-app return can never overwrite a pending
  /// website sign-in callback.
  Future<Uri?> consumeEnrollmentCallback() =>
      _consumeCallback('consumeEnrollmentCallback');

  Future<Uri?> _consumeCallback(String method) async {
    _ensureSupported();
    try {
      final raw = await _channel.invokeMethod<String>(method);
      return raw == null ? null : Uri.tryParse(raw);
    } on MissingPluginException {
      // Widget tests and non-native hosts do not install the Android bridge.
      // Treat that environment as having no browser callback; real Android
      // builds register this method in MainActivity.
      return null;
    }
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw UnsupportedError(
          'Android VpnService is unavailable on this platform.');
    }
  }
}
