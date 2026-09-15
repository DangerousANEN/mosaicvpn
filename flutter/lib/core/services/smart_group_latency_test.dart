import '../api/daemon_api_base.dart';
import '../models/models.dart';
import 'smart_group_selector.dart';

/// Snapshot for a user-visible Smart Group latency run. Candidate identifiers
/// remain private to the local daemon; the UI receives only aggregate progress
/// and quality metrics for the group row.
class SmartGroupLatencyProgress {
  const SmartGroupLatencyProgress({
    required this.groupId,
    required this.completed,
    required this.total,
    required this.successful,
    this.latencyMs,
    this.jitterMs,
    this.lossPercent,
    this.cancelled = false,
    this.unverified = false,
  });

  final String groupId;
  final int completed;
  final int total;
  final int successful;
  final int? latencyMs;
  final int? jitterMs;
  final double? lossPercent;
  final bool cancelled;
  final bool unverified;

  String get label => '$completed/$total';
}

/// Runs one bounded local latency test for a provider Smart Group. Calls are
/// deliberately sequential: a test can be cancelled between every opaque
/// candidate probe and cannot create a burst against the user's network.
class SmartGroupLatencyTest {
  SmartGroupLatencyTest({required this.api, required this.selector});

  final DaemonApiBase api;
  final SmartGroupSelector selector;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<SmartGroupLatencyProgress> run(
    ManifestGroup group, {
    required void Function(SmartGroupLatencyProgress progress) onProgress,
  }) async {
    if (group.disabled) {
      throw StateError(group.disabledReason.isEmpty
          ? 'Этот маршрут пока недоступен.'
          : group.disabledReason);
    }
    final installationId = await selector.installationID();
    final shard = await api.getCandidateShard(group.id, installationId);
    final candidateIds = shard.candidateIds;
    if (candidateIds.isEmpty) {
      throw StateError('Для этой Smart Group нет доступных кандидатов.');
    }

    final successful = <SmartGroupProbeResult>[];
    var unverifiedCount = 0;
    var completed = 0;
    SmartGroupLatencyProgress publish({bool cancelled = false}) {
      final aggregate = _aggregate(
        group.id,
        completed,
        candidateIds.length,
        successful,
        unverifiedCount: unverifiedCount,
        cancelled: cancelled,
      );
      onProgress(aggregate);
      return aggregate;
    }

    publish();
    var nextIndex = 0;
    final concurrency = group.clientPolicy.maxParallelProbes.clamp(1, 4);
    final workerCount = candidateIds.length < concurrency ? candidateIds.length : concurrency;

    Future<void> worker() async {
      while (true) {
        if (_cancelled) break;
        final int index;
        if (nextIndex >= candidateIds.length) break;
        index = nextIndex++;
        final candidateId = candidateIds[index];

        try {
          final result = await api.probeGroupCandidate(
            group.id,
            candidateId,
            probeMode: group.clientPolicy.probeMode,
            probeSamples: group.clientPolicy.probeSamples,
            probeUrl: group.clientPolicy.probeUrl,
          );
          if (result.successful && result.medianLatencyMs > 0) {
            successful.add(result);
          } else if (result.isUnverified || result.samples == 0) {
            unverifiedCount++;
          }
        } catch (_) {
          // A failed opaque candidate contributes to the aggregate loss.
        }
        completed += 1;
        publish(cancelled: _cancelled);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return publish(cancelled: _cancelled);
  }

  SmartGroupLatencyProgress _aggregate(
    String groupId,
    int completed,
    int total,
    List<SmartGroupProbeResult> successful, {
    int unverifiedCount = 0,
    required bool cancelled,
  }) {
    if (successful.isEmpty) {
      final isUnverified = unverifiedCount > 0 && unverifiedCount == completed;
      return SmartGroupLatencyProgress(
        groupId: groupId,
        completed: completed,
        total: total,
        successful: 0,
        lossPercent: completed == 0 || isUnverified ? null : 100,
        cancelled: cancelled,
        unverified: isUnverified,
      );
    }
    final latency = successful
            .map((result) => result.medianLatencyMs)
            .reduce((left, right) => left + right) /
        successful.length;
    final jitter = successful
            .map((result) => result.jitterMs)
            .reduce((left, right) => left + right) /
        successful.length;
    final measuredLoss = successful
            .map((result) => result.lossPercent)
            .reduce((left, right) => left + right) /
        successful.length;
    final unresponsive = completed - successful.length;
    final loss = completed == 0
        ? measuredLoss
        : ((measuredLoss * successful.length) + (100 * unresponsive)) /
            completed;
    return SmartGroupLatencyProgress(
      groupId: groupId,
      completed: completed,
      total: total,
      successful: successful.length,
      latencyMs: latency.round(),
      jitterMs: jitter.round(),
      lossPercent: loss,
      cancelled: cancelled,
    );
  }
}
