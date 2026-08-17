import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/daemon_api_base.dart';
import '../models/models.dart';

/// Result of local smart-group selection. Candidate IDs are opaque UI values:
/// endpoint and credential details never leave the local daemon store.
class SmartGroupSelection {
  const SmartGroupSelection({
    required this.groupId,
    required this.candidateId,
    required this.probe,
    required this.fromCache,
  });

  final String groupId;
  final String candidateId;
  final SmartGroupProbeResult probe;
  final bool fromCache;
}

/// Local-only quality cache and bounded selection engine for server-defined
/// Smart Groups. The server supplies policy and a candidate shard; the device
/// evaluates candidates from the user's current network and performs failover.
class SmartGroupSelector {
  static const _installationKey = 'mosaic.smart_group.installation_id.v1';
  static const _qualityKey = 'mosaic.smart_group.quality.v1';

  Future<String> _installationID() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installationKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final random = Random.secure();
    final created = List<int>.generate(18, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    await prefs.setString(_installationKey, created);
    return created;
  }

  Future<Map<String, SmartGroupProbeResult>> _readCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_qualityKey);
    if (raw == null || raw.isEmpty) return <String, SmartGroupProbeResult>{};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(
          key,
          SmartGroupProbeResult.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      // A malformed old cache should never block a connection attempt.
      return <String, SmartGroupProbeResult>{};
    }
  }

  Future<void> _writeCache(Map<String, SmartGroupProbeResult> values) async {
    // Keep local storage bounded even on long-lived installs. Older records are
    // least useful because policy TTL controls fresh selection anyway.
    final ordered = values.entries.toList()
      ..sort((left, right) =>
          right.value.checkedAt.compareTo(left.value.checkedAt));
    final trimmed = <String, dynamic>{
      for (final entry in ordered.take(256)) entry.key: entry.value.toJson(),
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityKey, jsonEncode(trimmed));
  }

  String _cacheKey(String groupID, String candidateID) =>
      '$groupID::$candidateID';

  bool _fresh(SmartGroupProbeResult result, ManifestClientPolicy policy) {
    final age = DateTime.now().difference(result.checkedAt);
    return !age.isNegative && age.inSeconds <= policy.probeTtlSeconds;
  }

  double _score(SmartGroupProbeResult result, ManifestClientPolicy policy) {
    if (!result.successful || result.successes == 0) {
      return double.negativeInfinity;
    }
    final reliability = 1 - (result.lossPercent.clamp(0, 100) / 100);
    final latency = result.medianLatencyMs <= 0
        ? 0.0
        : 1 / (1 + result.medianLatencyMs / 150);
    final stability = 1 / (1 + result.jitterMs / 100);
    // Transport probe does not currently measure throughput. Preserve a stable
    // fallback for a speed-policy group until the local sing-box probe adds it.
    final speed = latency;
    return reliability * policy.lossWeight +
        latency * policy.latencyWeight +
        stability * policy.stabilityWeight +
        speed * policy.speedWeight;
  }

  Future<List<SmartGroupProbeResult>> _probeMissing(
    DaemonApiBase api,
    String groupID,
    List<String> candidateIDs,
    int concurrency,
  ) async {
    if (candidateIDs.isEmpty) return const <SmartGroupProbeResult>[];
    final results = <SmartGroupProbeResult>[];
    var next = 0;
    final workers = List<Future<void>>.generate(concurrency, (_) async {
      while (true) {
        final index = next++;
        if (index >= candidateIDs.length) return;
        final candidateID = candidateIDs[index];
        try {
          final result = await api.probeGroupCandidate(groupID, candidateID);
          results.add(result);
        } catch (_) {
          results.add(SmartGroupProbeResult(
            groupId: groupID,
            candidateId: candidateID,
            successful: false,
            samples: 1,
            successes: 0,
            lossPercent: 100,
            medianLatencyMs: 0,
            p95LatencyMs: 0,
            jitterMs: 0,
            checkedAt: DateTime.now(),
            probeKind: 'transport_error',
          ));
        }
      }
    });
    await Future.wait(workers);
    return results;
  }

  /// Fetches the server-issued shard and ranks candidates in the device's own
  /// network. It returns ordered selections; callers connect the first and
  /// retry later entries when a real tunnel connection fails.
  Future<List<SmartGroupSelection>> rank(
    DaemonApiBase api,
    ManifestGroup group,
  ) async {
    if (group.disabled) {
      throw StateError(group.disabledReason.isEmpty
          ? 'Smart Group is disabled by the provider.'
          : group.disabledReason);
    }
    final installationID = await _installationID();
    final shard = await api.getCandidateShard(group.id, installationID);
    if (shard.candidateIds.isEmpty) {
      throw StateError('No eligible candidates are available for this route.');
    }

    final cache = await _readCache();
    final cached = <String, SmartGroupProbeResult>{};
    final missing = <String>[];
    for (final candidateID in shard.candidateIds) {
      final saved = cache[_cacheKey(group.id, candidateID)];
      if (saved != null && _fresh(saved, group.clientPolicy)) {
        cached[candidateID] = saved;
      } else {
        missing.add(candidateID);
      }
    }

    final fresh = await _probeMissing(
      api,
      group.id,
      missing,
      group.clientPolicy.maxParallelProbes,
    );
    for (final result in fresh) {
      cache[_cacheKey(group.id, result.candidateId)] = result;
      cached[result.candidateId] = result;
    }
    await _writeCache(cache);

    final ranked = <SmartGroupSelection>[];
    for (final candidateID in shard.candidateIds) {
      final result = cached[candidateID];
      if (result == null) continue;
      ranked.add(SmartGroupSelection(
        groupId: group.id,
        candidateId: candidateID,
        probe: result,
        fromCache: !missing.contains(candidateID),
      ));
    }
    ranked.sort((left, right) => _score(right.probe, group.clientPolicy)
        .compareTo(_score(left.probe, group.clientPolicy)));
    return ranked.where((selection) => selection.probe.successful).toList();
  }

  /// Connects candidates in local quality order. The local daemon verifies the
  /// selected candidate belongs to the group before each connection attempt.
  Future<SmartGroupSelection> connect(
    DaemonApiBase api,
    ManifestGroup group,
  ) async {
    final ranked = await rank(api, group);
    if (ranked.isEmpty) {
      throw StateError('No reachable candidates are available for this route.');
    }
    final attemptCount =
        min(group.clientPolicy.maxFailoverTries, ranked.length);
    Object? lastError;
    for (final selection in ranked.take(attemptCount)) {
      try {
        await api.connectGroupCandidate(group.id, selection.candidateId);
        return selection;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('All local failover candidates failed: $lastError');
  }
}
