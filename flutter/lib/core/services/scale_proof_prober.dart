import 'dart:async';
import 'dart:io';

enum ProbeMode {
  tcp,
  httpGet,
}

class ProbeTarget {
  final String id;
  final String host;
  final int port;
  final String? testUrl;
  final ProbeMode mode;

  const ProbeTarget({
    required this.id,
    required this.host,
    this.port = 443,
    this.testUrl,
    this.mode = ProbeMode.tcp,
  });
}

class ProbeResult {
  final String id;
  final int latencyMs;
  final bool success;
  final String error;
  final DateTime measuredAt;

  const ProbeResult({
    required this.id,
    required this.latencyMs,
    required this.success,
    this.error = '',
    required this.measuredAt,
  });

  bool get isFailed => !success || latencyMs <= 0;
}

/// ScaleProofProber handles on-demand, viewport-scoped live probing for
/// large server pools (from dozens to 12,000+ servers).
///
/// Key guarantees:
/// 1. Bounded concurrency (default 4 workers) so sockets/file descriptors
///    never exhaust and the Flutter event loop never stutters.
/// 2. Instant cancellation of pending items when the user scrolls away.
/// 3. Real live measurement — no stale deceptive cache.
/// 4. Pluggable modes: TCP handshake (1 RTT fast) or HTTP GET 204.
class ScaleProofProber {
  ScaleProofProber._();
  static final ScaleProofProber instance = ScaleProofProber._();

  final Map<String, ProbeResult> _liveResults = {};
  final Set<String> _inFlight = {};
  final _resultsController = StreamController<Map<String, ProbeResult>>.broadcast();

  Stream<Map<String, ProbeResult>> get resultsStream => _resultsController.stream;
  Map<String, ProbeResult> get snapshot => Map.unmodifiable(_liveResults);

  ProbeResult? getResult(String id) => _liveResults[id];
  bool isInFlight(String id) => _inFlight.contains(id);

  bool _isCancelled = false;

  void cancelAll() {
    _isCancelled = true;
    _inFlight.clear();
  }

  /// Single live probe with bounded timeout (2.5s)
  Future<ProbeResult> probeSingle(
    ProbeTarget target, {
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    _inFlight.add(target.id);
    final stopwatch = Stopwatch()..start();

    try {
      if (target.mode == ProbeMode.httpGet && target.testUrl != null && target.testUrl!.isNotEmpty) {
        // HTTP GET 204 probe
        final client = HttpClient()..connectionTimeout = timeout;
        try {
          final uri = Uri.parse(target.testUrl!);
          final request = await client.getUrl(uri).timeout(timeout);
          request.followRedirects = false;
          final response = await request.close().timeout(timeout);
          stopwatch.stop();
          final ok = response.statusCode >= 200 && response.statusCode < 400;
          final result = ProbeResult(
            id: target.id,
            latencyMs: ok ? stopwatch.elapsedMilliseconds : -1,
            success: ok,
            error: ok ? '' : 'HTTP ${response.statusCode}',
            measuredAt: DateTime.now(),
          );
          _liveResults[target.id] = result;
          _resultsController.add(Map.of(_liveResults));
          return result;
        } finally {
          client.close(force: true);
        }
      } else {
        // TCP Fast Handshake (1 RTT)
        final effectivePort = target.port > 0 ? target.port : 443;
        final socket = await Socket.connect(
          target.host,
          effectivePort,
          timeout: timeout,
        );
        stopwatch.stop();
        socket.destroy();

        final result = ProbeResult(
          id: target.id,
          latencyMs: stopwatch.elapsedMilliseconds.clamp(1, 60000),
          success: true,
          measuredAt: DateTime.now(),
        );
        _liveResults[target.id] = result;
        _resultsController.add(Map.of(_liveResults));
        return result;
      }
    } catch (e) {
      stopwatch.stop();
      final result = ProbeResult(
        id: target.id,
        latencyMs: -1,
        success: false,
        error: 'Не отвечает',
        measuredAt: DateTime.now(),
      );
      _liveResults[target.id] = result;
      _resultsController.add(Map.of(_liveResults));
      return result;
    } finally {
      _inFlight.remove(target.id);
    }
  }

  /// Batch probing with bounded concurrency pool (e.g. 4 workers)
  /// Safely measures an arbitrary list of servers without choking the OS.
  Future<void> probeBatch(
    List<ProbeTarget> targets, {
    int maxConcurrency = 4,
    void Function(ProbeResult result)? onResult,
    void Function(int completed, int total)? onProgress,
  }) async {
    _isCancelled = false;
    final queue = List<ProbeTarget>.from(targets);
    final total = queue.length;
    var completed = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty && !_isCancelled) {
        final target = queue.removeAt(0);
        final res = await probeSingle(target);
        completed++;
        onResult?.call(res);
        onProgress?.call(completed, total);
      }
    }

    final workerCount = maxConcurrency.clamp(1, 8);
    final workers = List.generate(
      workerCount,
      (_) => worker(),
    );

    await Future.wait(workers);
  }

  /// Quickly finds the fastest reachable server from a target list
  /// by testing in small prioritized batches until a good node (<150ms) is found.
  Future<ProbeResult?> findFastest(
    List<ProbeTarget> targets, {
    int maxBatches = 3,
    int batchSize = 10,
  }) async {
    if (targets.isEmpty) return null;
    ProbeResult? best;

    final batches = <List<ProbeTarget>>[];
    for (var i = 0; i < targets.length && batches.length < maxBatches; i += batchSize) {
      batches.add(targets.sublist(i, (i + batchSize).clamp(0, targets.length)));
    }

    for (final batch in batches) {
      await probeBatch(
        batch,
        maxConcurrency: 4,
        onResult: (res) {
          if (res.success && res.latencyMs > 0) {
            if (best == null || res.latencyMs < best!.latencyMs) {
              best = res;
            }
          }
        },
      );
      // If we found an exceptionally low latency node (<100ms), stop early
      if (best != null && best!.latencyMs < 100) {
        break;
      }
    }

    return best;
  }
}
