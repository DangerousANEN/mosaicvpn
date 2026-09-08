import 'dart:async';
import 'dart:math';

import '../api/daemon_api_base.dart';
import '../models/models.dart';
import 'smart_group_selector.dart';

// ─── Configuration ─────────────────────────────────────────────────────────

/// Runtime quality monitoring configuration. All durations are clamped to
/// provider policy bounds at construction time.
class MonitorConfig {
  /// How often a monitoring window is triggered.
  final Duration probeInterval;

  /// Number of probe windows that must confirm degradation before failover.
  /// Implements hysteresis: transient spikes never trigger a switch.
  final int degradationWindowCount;

  /// How long to suppress failover evaluation after a successful switch.
  final Duration failoverCooldown;

  /// Minimum quality score improvement the winner must have over the active
  /// candidate before a switch is committed. Prevents thrashing when two
  /// candidates alternate quality rankings by tiny margins.
  final double minMaterialImprovement;

  /// Maximum probe failures across windows before the monitor treats the
  /// active candidate as degraded (loss expressed as 0–1 fraction).
  final double maxLossThreshold;

  /// Latency ceiling (ms). Exceeding this for [degradationWindowCount]
  /// windows in a row also triggers a failover evaluation.
  final int maxLatencyThresholdMs;

  const MonitorConfig({
    this.probeInterval = const Duration(seconds: 30),
    this.degradationWindowCount = 3,
    this.failoverCooldown = const Duration(minutes: 2),
    this.minMaterialImprovement = 0.15,
    this.maxLossThreshold = 0.30,
    this.maxLatencyThresholdMs = 400,
  });

  /// Derives a bounded config from a provider-supplied [ManifestClientPolicy].
  /// Provider-set windows must not let a remote manifest trigger arbitrarily
  /// aggressive or arbitrarily slow probing.
  factory MonitorConfig.fromPolicy(ManifestClientPolicy policy) {
    // probe interval: clamp policy TTL-derived hint (TTL/10) to [15s, 5min]
    final rawIntervalSeconds = max(15, min(300, policy.probeTtlSeconds ~/ 10));
    return MonitorConfig(
      probeInterval: Duration(seconds: rawIntervalSeconds),
      degradationWindowCount: policy.maxFailoverTries.clamp(2, 6),
      failoverCooldown: Duration(
        seconds: max(60, min(600, rawIntervalSeconds * policy.maxFailoverTries)),
      ),
      // Provider weights inform the min-improvement threshold.
      minMaterialImprovement:
          (policy.latencyWeight + policy.lossWeight + policy.stabilityWeight)
              .clamp(0.10, 0.40),
      maxLossThreshold: policy.lossWeight.clamp(0.15, 0.60),
      maxLatencyThresholdMs: 400,
    );
  }
}

// ─── Events ────────────────────────────────────────────────────────────────

/// Reason why the monitor decided to (or not to) switch.
enum FailoverReason {
  /// Active node quality degraded and a materially better candidate was found.
  degradedQuality,

  /// Active node became unreachable across all probe windows.
  unreachable,

  /// A better candidate was found, but the quality improvement was below the
  /// material threshold — switch suppressed.
  improvementBelowThreshold,

  /// No alternative candidate is available to switch to.
  noAlternative,
}

/// Event emitted by [SmartGroupQualityMonitor] when it makes a failover
/// decision (whether or not a switch was performed).
class FailoverEvent {
  final String groupId;
  final String fromCandidateId;
  final String? toCandidateId;
  final FailoverReason reason;
  final double activeScore;
  final double? winnerScore;
  final bool switched;
  final DateTime occurredAt;

  const FailoverEvent({
    required this.groupId,
    required this.fromCandidateId,
    this.toCandidateId,
    required this.reason,
    required this.activeScore,
    this.winnerScore,
    required this.switched,
    required this.occurredAt,
  });
}

// ─── Monitor ───────────────────────────────────────────────────────────────

/// Continuously monitors the quality of the active Smart Group candidate while
/// connected and performs seamless failover when a materially better
/// policy-compliant candidate is consistently available.
class SmartGroupQualityMonitor {
  SmartGroupQualityMonitor({
    required this.api,
    required this.selector,
    MonitorConfig? config,
  }) : _config = config ?? const MonitorConfig();

  final DaemonApiBase api;
  final SmartGroupSelector selector;
  final MonitorConfig _config;

  // ─── State ─────────────────────────────────────────────────────────
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;

  String _groupId = '';
  String _activeCandidateId = '';
  ManifestGroup? _group;

  /// Count of consecutive windows where the active candidate was degraded.
  int _degradedWindows = 0;

  /// Last time a failover was attempted (successful or not).
  DateTime? _lastFailoverAt;

  // ─── Public surface ────────────────────────────────────────────────

  bool get isRunning => _running && !_disposed;

  /// Fired on each failover evaluation (pass or fail).
  void Function(FailoverEvent)? onFailoverEvent;

  /// Invoked when the monitor determines a real switch should be committed.
  Future<void> Function(String groupId, String candidateId)? onSwitchCandidate;

  bool _isCurrent(int gen) => !_disposed && _running && gen == _generation;

  /// Starts the monitor for the given [group] and [activeCandidateId].
  void start({
    required ManifestGroup group,
    required String activeCandidateId,
  }) {
    if (_disposed) throw StateError('Monitor has been disposed.');
    if (group.disabled) {
      throw StateError(
        group.disabledReason.isEmpty
            ? 'Smart Group is disabled by provider.'
            : group.disabledReason,
      );
    }
    _stop();
    _running = true;
    _groupId = group.id;
    _activeCandidateId = activeCandidateId;
    _group = group;
    _degradedWindows = 0;
    _lastFailoverAt = null;
    _scheduleNext(_generation);
  }

  /// Stops the monitor. Safe to call multiple times or when not running.
  void stop() => _stop();

  /// Releases all resources. The monitor must not be used after [dispose].
  void dispose() {
    _disposed = true;
    _stop();
    onSwitchCandidate = null;
    onFailoverEvent = null;
  }

  // ─── Internal ──────────────────────────────────────────────────────

  void _stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  void _scheduleNext(int gen) {
    if (!_isCurrent(gen)) return;
    _timer?.cancel();
    _timer = Timer(_config.probeInterval, () => _runWindow(gen));
  }

  Future<void> _runWindow(int gen) async {
    if (!_isCurrent(gen)) return;

    final group = _group;
    final currentGroupId = _groupId;
    if (group == null || currentGroupId.isEmpty) {
      _stop();
      return;
    }

    try {
      final status = await api.getStatus();
      if (!_isCurrent(gen)) return;
      if (!status.isConnected || status.activeGroupId != currentGroupId) {
        _stop();
        return;
      }

      final installId = await selector.installationID();
      if (!_isCurrent(gen)) return;

      final shard = await api.getCandidateShard(currentGroupId, installId);
      if (!_isCurrent(gen)) return;

      if (shard.candidateIds.isEmpty) {
        _stop();
        return;
      }

      final concurrency = group.clientPolicy.maxParallelProbes.clamp(1, 8);
      final results = await _probeCandidates(shard.candidateIds, concurrency);
      if (!_isCurrent(gen)) return;

      final currentActiveId = _activeCandidateId;
      final activeResult = results[currentActiveId];
      final activeScore = _scoreResult(activeResult, group.clientPolicy);

      if (_isActiveDegraded(activeResult)) {
        _degradedWindows++;
      } else {
        _degradedWindows = 0;
      }

      if (_degradedWindows >= _config.degradationWindowCount) {
        await _evaluateFailover(gen, group, currentGroupId, currentActiveId, results, activeScore);
      }
    } catch (_) {
      // Transient failure: reschedule if still current.
    } finally {
      _scheduleNext(gen);
    }
  }

  /// Returns true when the current window result for the active candidate
  /// crosses a configured degradation threshold.
  bool _isActiveDegraded(SmartGroupProbeResult? result) {
    if (result == null || !result.successful) return true;
    final lossFraction = result.lossPercent / 100;
    if (lossFraction >= _config.maxLossThreshold) return true;
    if (result.medianLatencyMs > _config.maxLatencyThresholdMs) return true;
    return false;
  }

  /// Evaluates whether a failover should be committed. Only switches when a
  /// policy-compliant candidate is materially better than the active node.
  Future<void> _evaluateFailover(
    int gen,
    ManifestGroup group,
    String groupId,
    String activeId,
    Map<String, SmartGroupProbeResult> results,
    double activeScore,
  ) async {
    if (!_isCurrent(gen)) return;

    final now = DateTime.now();
    if (_lastFailoverAt != null) {
      final sinceLastFailover = now.difference(_lastFailoverAt!);
      if (sinceLastFailover < _config.failoverCooldown) {
        return;
      }
    }

    final alternatives = results.entries
        .where((entry) => entry.key != activeId && entry.value.successful)
        .toList()
      ..sort((left, right) => _scoreResult(right.value, group.clientPolicy)
          .compareTo(_scoreResult(left.value, group.clientPolicy)));

    if (alternatives.isEmpty) {
      _emitEvent(FailoverEvent(
        groupId: groupId,
        fromCandidateId: activeId,
        reason: FailoverReason.noAlternative,
        activeScore: activeScore,
        switched: false,
        occurredAt: now,
      ));
      return;
    }

    final winner = alternatives.first;
    final winnerScore = _scoreResult(winner.value, group.clientPolicy);

    final improvement = winnerScore - activeScore;
    if (improvement < _config.minMaterialImprovement) {
      _emitEvent(FailoverEvent(
        groupId: groupId,
        fromCandidateId: activeId,
        toCandidateId: winner.key,
        reason: FailoverReason.improvementBelowThreshold,
        activeScore: activeScore,
        winnerScore: winnerScore,
        switched: false,
        occurredAt: now,
      ));
      _degradedWindows = 0;
      return;
    }

    final activeResult = results[activeId];
    final reason = (activeResult == null || !activeResult.successful)
        ? FailoverReason.unreachable
        : FailoverReason.degradedQuality;

    final switcher = onSwitchCandidate;
    if (switcher == null) return;

    bool switchSucceeded = false;
    try {
      await switcher(groupId, winner.key);
      if (!_isCurrent(gen)) return;
      _activeCandidateId = winner.key;
      _degradedWindows = 0;
      _lastFailoverAt = now;
      switchSucceeded = true;
    } catch (_) {
      switchSucceeded = false;
    }

    if (!_isCurrent(gen)) return;

    _emitEvent(FailoverEvent(
      groupId: groupId,
      fromCandidateId: activeId,
      toCandidateId: winner.key,
      reason: reason,
      activeScore: activeScore,
      winnerScore: winnerScore,
      switched: switchSucceeded,
      occurredAt: now,
    ));
  }

  double _scoreResult(
      SmartGroupProbeResult? result, ManifestClientPolicy policy) {
    if (result == null || !result.successful || result.successes == 0) {
      return double.negativeInfinity;
    }
    final reliability = 1 - (result.lossPercent.clamp(0.0, 100.0) / 100);
    final latency = result.medianLatencyMs <= 0
        ? 0.0
        : 1 / (1 + result.medianLatencyMs / 150);
    final stability = 1 / (1 + result.jitterMs / 100);
    return reliability * policy.lossWeight +
        latency * policy.latencyWeight +
        stability * policy.stabilityWeight;
  }

  /// Probes candidate IDs with bounded concurrency and returns per-candidate
  /// probe results.
  Future<Map<String, SmartGroupProbeResult>> _probeCandidates(
    List<String> candidateIds,
    int concurrency,
  ) async {
    final results = <String, SmartGroupProbeResult>{};
    var nextIndex = 0;

    final workers = List<Future<void>>.generate(concurrency, (_) async {
      while (true) {
        final index = nextIndex++;
        if (index >= candidateIds.length) return;
        final candidateId = candidateIds[index];
        try {
          final result =
              await api.probeGroupCandidate(_groupId, candidateId);
          results[candidateId] = result;
        } catch (_) {
          results[candidateId] = SmartGroupProbeResult(
            groupId: _groupId,
            candidateId: candidateId,
            successful: false,
            samples: 1,
            successes: 0,
            lossPercent: 100,
            medianLatencyMs: 0,
            p95LatencyMs: 0,
            jitterMs: 0,
            checkedAt: DateTime.now(),
            probeKind: 'transport_error',
          );
        }
      }
    });

    await Future.wait(workers);
    return results;
  }

  void _emitEvent(FailoverEvent event) {
    try {
      onFailoverEvent?.call(event);
    } catch (_) {
      // Events must not crash the monitor.
    }
  }
}
