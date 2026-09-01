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
  final double activeSore;
  final double? winnerScore;
  final bool switched;
  final DateTime occurredAt;

  const FailoverEvent({
    required this.groupId,
    required this.fromCandidateId,
    this.toCandidateId,
    required this.reason,
    required this.activeSore,
    this.winnerScore,
    required this.switched,
    required this.occurredAt,
  });
}

// ─── Monitor ───────────────────────────────────────────────────────────────

/// Continuously monitors the quality of the active Smart Group candidate while
/// connected and performs seamless failover when a materially better
/// policy-compliant candidate is consistently available.
///
/// **Lifecycle**
/// - Start with [start] immediately after a successful Smart Group connection.
/// - The monitor attaches itself to the running group through [api] to probe
///   candidates without revealing endpoint details.
/// - Stop with [stop] on explicit disconnect, route change, or when the
///   active route is no longer a Smart Group.
///
/// **Algorithm**
/// 1. Every [MonitorConfig.probeInterval] the monitor probes all shard
///    candidates (re-fetching the shard when stale).
/// 2. Degradation is confirmed only after [MonitorConfig.degradationWindowCount]
///    consecutive windows exceed the loss or latency thresholds (hysteresis).
/// 3. When degradation is confirmed, the monitor ranks alternatives. A switch
///    is committed only if the winner score exceeds the active candidate score
///    by at least [MonitorConfig.minMaterialImprovement].
/// 4. After any switch attempt (successful or not) the monitor enters a cooldown
///    period to prevent thrashing.
/// 5. The monitor stops on disconnect or when the route is no longer smart.
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

  String _groupId = '';
  String _activeCandidateId = '';
  ManifestGroup? _group;

  /// Count of consecutive windows where the active candidate was degraded.
  int _degradedWindows = 0;

  /// Last time a failover was attempted (successful or not).
  DateTime? _lastFailoverAt;

  /// Probe results from the current window, keyed by candidateId.
  final Map<String, SmartGroupProbeResult> _windowResults = {};

  // ─── Public surface ────────────────────────────────────────────────

  bool get isRunning => _running;

  /// Fired on each failover evaluation (pass or fail). Useful for UI toasts
  /// and logs. Events are delivered on the main isolate but callers must not
  /// await heavy work inside the handler.
  void Function(FailoverEvent)? onFailoverEvent;

  /// Invoked when the monitor determines a real switch should be committed.
  /// The implementation must call [api.connectGroupCandidate] and update any
  /// UI state. The monitor re-evaluates immediately after.
  Future<void> Function(String groupId, String candidateId)? onSwitchCandidate;

  /// Starts the monitor for the given [group] and [activeCandidateId].
  ///
  /// Re-entrant: calling [start] while already running stops the previous
  /// loop first so callers need not explicitly stop before a route change.
  ///
  /// Throws [StateError] if the group is disabled or is not a smart route.
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
    _groupId = group.id;
    _activeCandidateId = activeCandidateId;
    _group = group;
    _degradedWindows = 0;
    _windowResults.clear();
    _running = true;
    _scheduleNext();
  }

  /// Stops the monitor. Safe to call multiple times or when not running.
  void stop() => _stop();

  /// Releases all resources. The monitor must not be used after [dispose].
  void dispose() {
    _disposed = true;
    _stop();
  }

  // ─── Internal ──────────────────────────────────────────────────────

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  void _scheduleNext() {
    if (!_running || _disposed) return;
    _timer = Timer(_config.probeInterval, _runWindow);
  }

  Future<void> _runWindow() async {
    if (!_running || _disposed) return;

    final group = _group;
    if (group == null) {
      _stop();
      return;
    }

    // Verify the connection is still a Smart Group route before probing.
    // If the status cannot be queried (e.g. API error) we do nothing and
    // reschedule, rather than falsely triggering failover.
    try {
      final status = await api.getStatus();
      if (!status.isConnected || status.activeGroupId != _groupId) {
        // No longer connected to this Smart Group — stop silently.
        _stop();
        return;
      }
    } catch (_) {
      // Transient status check failure: reschedule and try again.
      _scheduleNext();
      return;
    }

    // Re-fetch the candidate shard so we always evaluate a current list.
    SmartGroupCandidateShard shard;
    try {
      final installId = await selector.installationID();
      shard = await api.getCandidateShard(_groupId, installId);
    } catch (_) {
      // Cannot reach daemon — reschedule.
      _scheduleNext();
      return;
    }

    if (shard.candidateIds.isEmpty) {
      _stop();
      return;
    }

    // Probe all candidates in the shard concurrently (bounded by policy).
    final concurrency = group.clientPolicy.maxParallelProbes.clamp(1, 8);
    final results = await _probeCandidates(shard.candidateIds, concurrency);
    _windowResults
      ..clear()
      ..addAll(results);

    final activeResult = _windowResults[_activeCandidateId];
    final activeScore = _scoreResult(activeResult, group.clientPolicy);

    if (_isActiveDegraded(activeResult)) {
      _degradedWindows++;
    } else {
      _degradedWindows = 0;
    }

    if (_degradedWindows >= _config.degradationWindowCount) {
      await _evaluateFailover(group, activeScore);
    }

    _scheduleNext();
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
      ManifestGroup group, double activeScore) async {
    // Respect cooldown to prevent thrashing.
    final now = DateTime.now();
    if (_lastFailoverAt != null) {
      final sinceLastFailover = now.difference(_lastFailoverAt!);
      if (sinceLastFailover < _config.failoverCooldown) {
        return;
      }
    }

    // Find the best alternative candidate.
    final alternatives = _windowResults.entries
        .where((entry) =>
            entry.key != _activeCandidateId && entry.value.successful)
        .toList()
      ..sort((left, right) => _scoreResult(right.value, group.clientPolicy)
          .compareTo(_scoreResult(left.value, group.clientPolicy)));

    if (alternatives.isEmpty) {
      _emitEvent(FailoverEvent(
        groupId: _groupId,
        fromCandidateId: _activeCandidateId,
        reason: FailoverReason.noAlternative,
        activeSore: activeScore,
        switched: false,
        occurredAt: now,
      ));
      return;
    }

    final winner = alternatives.first;
    final winnerScore =
        _scoreResult(winner.value, group.clientPolicy);

    final improvement = winnerScore - activeScore;
    if (improvement < _config.minMaterialImprovement) {
      _emitEvent(FailoverEvent(
        groupId: _groupId,
        fromCandidateId: _activeCandidateId,
        toCandidateId: winner.key,
        reason: FailoverReason.improvementBelowThreshold,
        activeSore: activeScore,
        winnerScore: winnerScore,
        switched: false,
        occurredAt: now,
      ));
      _degradedWindows = 0;
      return;
    }

    // Determine specific failure reason for the event record.
    final activeResult = _windowResults[_activeCandidateId];
    final reason = (activeResult == null || !activeResult.successful)
        ? FailoverReason.unreachable
        : FailoverReason.degradedQuality;

    // Commit the switch.
    _lastFailoverAt = now;
    final oldCandidateId = _activeCandidateId;
    _activeCandidateId = winner.key;
    _degradedWindows = 0;

    try {
      final switcher = onSwitchCandidate;
      if (switcher != null) {
        await switcher(_groupId, winner.key);
      }
    } catch (_) {
      // Switch failed — roll back so we keep probing the original.
      _activeCandidateId = oldCandidateId;
    }

    _emitEvent(FailoverEvent(
      groupId: _groupId,
      fromCandidateId: oldCandidateId,
      toCandidateId: winner.key,
      reason: reason,
      activeSore: activeScore,
      winnerScore: winnerScore,
      switched: _activeCandidateId == winner.key,
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

    // Dart event loop is cooperative (single-threaded): the ++ on nextIndex is
    // not preempted between awaits, so no explicit mutex is needed here.
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
