import 'dart:async';

import 'daemon_api_base.dart';

/// Thrown when a platform does not have a ready VPN runtime.
///
/// A production client must never silently replace a missing daemon or native
/// VPN service with demo data. Callers can show this message and offer retry;
/// they must not fabricate an account, route, server, or connected state.
class VpnRuntimeUnavailableException implements Exception {
  final String message;

  const VpnRuntimeUnavailableException(this.message);

  @override
  String toString() => message;
}

/// A deliberately non-functional implementation used only while the actual
/// runtime is unavailable. Every request fails predictably instead of exposing
/// mock content. Unsupported calls throw immediately so generic callers do
/// not receive an unsound `Future<dynamic>` in place of `Future<T>`; events is
/// explicitly a failing stream.
class UnavailableDaemonApi implements DaemonApiBase {
  final String reason;

  const UnavailableDaemonApi({
    this.reason =
        'VPN runtime is unavailable. Start MosaicVPN again and retry.',
  });

  VpnRuntimeUnavailableException get _error =>
      VpnRuntimeUnavailableException(reason);

  @override
  Never noSuchMethod(Invocation invocation) => throw _error;

  @override
  Stream<(String, Map<String, dynamic>)> events() => Stream.error(_error);
}
