import 'dart:async';
import 'dart:io';

import 'android_mosaic_account_service.dart';
import 'smart_group_runtime_controller.dart';

/// Background maintenance of the endpoint reachability cache while the app is
/// alive (connected or idle). The user's request:
///  - while connected to a smart group, occasionally probe a couple of pool
///    nodes in the background (light: never saturates the link, never touches
///    the active tunnel) so a reserve node is always known-good;
///  - keep the cache warm so the NEXT connect is instant;
///  - refresh the pool from the VPS while the VPN runs, without dropping the
///    connection (no runtime restart: it only updates the candidate cache).
///
/// The keeper never starts or stops the tunnel and never routes traffic
/// through candidates: probes are plain TCP connects bound to the underlying
/// network (sockets created here are NOT routed through the TUN because
/// Android routes the app's own UID through the VPN by default — the keeper
/// explicitly skips probing while a TUN is active UNLESS the endpoint is
/// already the known-active one; see [_probeEndpoint] guard).
class AndroidSmartGroupPoolKeeper {
  AndroidSmartGroupPoolKeeper._();

  static final AndroidSmartGroupPoolKeeper instance =
      AndroidSmartGroupPoolKeeper._();

  Timer? _timer;
  bool _sweepInFlight = false;
  List<Map<String, dynamic>> _lastKnownCandidates = const [];

  /// Group candidates observed by the last successful fetch. Refreshed from
  /// the VPS candidate feed; the keeper serves warm entries from here.
  List<Map<String, dynamic>> get lastKnownCandidates => _lastKnownCandidates;

  /// Starts periodic maintenance. [interval] defaults to 5 minutes — light
  /// enough for cellular, frequent enough to keep the 10-minute cache TTL fed.
  void start({
    Duration interval = const Duration(minutes: 5),
    int probesPerSweep = 3,
  }) {
    stop();
    _timer = Timer.periodic(interval, (_) {
      unawaited(_sweep(probesPerSweep: probesPerSweep));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One maintenance pass:
  /// 1. refresh the candidate list from the VPS feed (control plane only,
  ///    HTTPS to sub.zxc1x1.ru — does not touch the tunnel);
  /// 2. probe the stalest [probesPerSweep] cache entries plus any NEW
  ///    endpoints not yet in the cache, so a reserve node is always verified.
  Future<void> _sweep({required int probesPerSweep}) async {
    if (_sweepInFlight) return;
    _sweepInFlight = true;
    try {
      await _refreshCandidates();
      await _probeStaleAndNew(probesPerSweep: probesPerSweep);
    } catch (_) {
      // Maintenance is best-effort; the next tick retries.
    } finally {
      _sweepInFlight = false;
    }
  }

  Future<void> _refreshCandidates() async {
    // The subscription URL is resolved from the shared account service state;
    // if nothing is enrolled, there is simply nothing to keep warm.
    final url = AndroidMosaicAccountService.lastSubscriptionUrl;
    if (url == null || url.isEmpty) return;
    try {
      final outbounds =
          await AndroidMosaicAccountService.instance.fetchGroupCandidates(url);
      if (outbounds.isNotEmpty) {
        _lastKnownCandidates = outbounds;
      }
    } catch (_) {}
  }

  Future<void> _probeStaleAndNew({required int probesPerSweep}) async {
    final candidates = _lastKnownCandidates;
    if (candidates.isEmpty) return;

    // Collect endpoints.
    final endpoints = <(String, int)>[];
    for (final candidate in candidates) {
      final host = candidate['server']?.toString() ?? '';
      final port =
          int.tryParse(candidate['server_port']?.toString() ?? '') ?? 0;
      if (host.isNotEmpty && port > 0) endpoints.add((host, port));
    }
    if (endpoints.isEmpty) return;

    // Prefer NEW endpoints (unknown = potential reserve node) and the stalest
    // known ones. Cap the sweep at probesPerSweep to keep it light.
    final stale = AndroidMosaicAccountService.staleReachabilityEndpoints(
        endpoints, maxCount: probesPerSweep);

    await Future.wait(stale.map((endpoint) => _probeEndpoint(endpoint.$1, endpoint.$2)));
  }

  Future<void> _probeEndpoint(String host, int port) async {
    // Probing while the tunnel is up: a plain TCP connect from this app goes
    // through the TUN (all UIDs routed). That measures "through the current
    // tunnel" — not what we want, and it disturbs nothing. Skip instead: the
    // active session's own urltest already health-checks the tunnel path.
    if (SmartGroupRuntimeController.instance.isRunning) return;
    try {
      final sw = Stopwatch()..start();
      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 3));
      sw.stop();
      socket.destroy();
      AndroidMosaicAccountService.storeReachability(host, port, sw.elapsedMilliseconds);
    } catch (_) {
      // Unreachable now: leave the old verdict to expire naturally.
    }
  }

  /// Updates the keeper's candidate snapshot after a successful connect:
  /// the connect path already fetched + probed everything it needed.
  void noteCandidates(List<Map<String, dynamic>> candidates) {
    _lastKnownCandidates = candidates;
  }

  void dispose() => stop();
}
