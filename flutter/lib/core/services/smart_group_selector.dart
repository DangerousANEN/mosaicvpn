import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/daemon_api_base.dart';
import '../models/models.dart';
import 'diagnostic_redaction.dart';

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

  final Map<String, Future<List<SmartGroupSelection>>> _inflightRanks = {};
  bool _cancelled = false;
  int _cacheEpoch = 0;
  int _cancelEpoch = 0;

  /// Cancels in-flight latency sweeps and connection attempts.
  void cancel() {
    _cancelled = true;
    _cancelEpoch++;
    _cacheEpoch++;
    _inflightRanks.clear();
  }

  /// Resets cancellation state.
  void resetCancel() {
    _cancelled = false;
  }

  /// Returns true if selection is currently cancelled.
  bool get isCancelled => _cancelled;

  /// Returns the stable anonymous installation identity used only to request a
  /// bounded opaque candidate shard from the local daemon.
  Future<String> installationID() => _installationID();

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

  /// Resolves the current network identity fingerprint from the daemon status
  /// or returns [explicitScope] if specified. Defaults to 'default'.
  Future<String> resolveNetworkScope(
    DaemonApiBase api, [
    String? explicitScope,
  ]) async {
    if (explicitScope != null && explicitScope.trim().isNotEmpty) {
      return explicitScope.trim();
    }
    try {
      final status = await api.getStatus();
      if (status.networkFingerprint.isNotEmpty) {
        return status.networkFingerprint;
      }
    } catch (_) {}
    return 'default';
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

  /// Clears quality cache for a specific network scope, or all if omitted.
  Future<void> invalidateNetwork([String? networkScope]) async {
    _cacheEpoch++;
    final prefs = await SharedPreferences.getInstance();
    if (networkScope == null || networkScope.isEmpty) {
      await prefs.remove(_qualityKey);
      return;
    }
    final cache = await _readCache();
    cache.removeWhere((key, _) => key.startsWith('$networkScope::'));
    await _writeCache(cache);
  }

  /// Clears quality cache for a specific group, optionally scoped to a network.
  Future<void> invalidateGroup(String groupID, {String? networkScope}) async {
    _cacheEpoch++;
    final cache = await _readCache();
    if (networkScope != null && networkScope.isNotEmpty) {
      cache.removeWhere((key, _) => key.startsWith('$networkScope::$groupID::'));
    } else {
      cache.removeWhere((key, _) => key.contains('::$groupID::'));
    }
    await _writeCache(cache);
  }

  /// Complete cache purge.
  Future<void> clearCache() async {
    _cacheEpoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_qualityKey);
  }

  String _cacheKey(String networkScope, String groupID, String candidateID) =>
      '$networkScope::$groupID::$candidateID';

  /// Truthful eligibility gate: unknown or failed probes can NEVER win.
  static bool isEligibleWinner(SmartGroupProbeResult probe) {
    return probe.successful &&
        probe.samples > 0 &&
        probe.successes > 0 &&
        probe.successes <= probe.samples &&
        probe.lossPercent.isFinite &&
        !probe.lossPercent.isNaN &&
        probe.lossPercent >= 0 &&
        probe.lossPercent < 100 &&
        probe.medianLatencyMs > 0 &&
        probe.jitterMs >= 0 &&
        probe.downloadMbps.isFinite &&
        !probe.downloadMbps.isNaN &&
        probe.downloadMbps >= 0 &&
        probe.uploadMbps.isFinite &&
        !probe.uploadMbps.isNaN &&
        probe.uploadMbps >= 0;
  }

  bool _fresh(SmartGroupProbeResult result, ManifestClientPolicy policy) {
    if (!isEligibleWinner(result)) return false;
    if (policy.probeTtlSeconds <= 0) return false;
    final age = DateTime.now().difference(result.checkedAt);
    return !age.isNegative && age.inSeconds <= policy.probeTtlSeconds;
  }

  /// Calculates candidate quality score honoring policy weights, mode priorities,
  /// sample success rates, jitter, and hysteresis for active incumbents.
  double score(
    SmartGroupProbeResult result,
    ManifestClientPolicy policy, {
    bool isIncumbent = false,
  }) {
    return _score(result, policy, isIncumbent: isIncumbent);
  }

  double _score(
    SmartGroupProbeResult result,
    ManifestClientPolicy policy, {
    bool isIncumbent = false,
  }) {
    if (!isEligibleWinner(result)) {
      return double.negativeInfinity;
    }

    // Reliability: consider packet loss and sample ratio
    final sampleRatio = (result.successes / result.samples).clamp(0.0, 1.0);
    final lossRate = (result.lossPercent.clamp(0.0, 100.0) / 100.0);
    // Severe penalty for packet loss in stability-conscious scoring
    final reliability = (1.0 - lossRate) * sampleRatio;

    // Latency component (bounded [0, 1])
    final latency = result.medianLatencyMs <= 0
        ? 0.0
        : 1.0 / (1.0 + result.medianLatencyMs / 150.0);

    // Stability component: jitter-aware and failure-aware
    // Higher jitter and loss decrease stability score sharply
    final stability = 1.0 /
        (1.0 +
            (result.jitterMs / 50.0) +
            (result.lossPercent > 0 ? 0.5 : 0.0));

    // Speed component: uses real measured throughput, NEVER fabricated speed
    final rawTarget = policy.speedProbe.targetMbps;
    final targetMbps = (rawTarget.isFinite && !rawTarget.isNaN && rawTarget > 0)
        ? rawTarget
        : 50.0;
    final measuredMbps = max(result.downloadMbps, result.uploadMbps * 0.5);
    final speed = measuredMbps > 0
        ? (measuredMbps / targetMbps).clamp(0.0, 1.0)
        : 0.0;

    // Policy weights
    double lw = policy.lossWeight;
    double latw = policy.latencyWeight;
    double stabw = policy.stabilityWeight;
    double spw = policy.speedWeight;

    // Adjust for policy mode
    if (policy.mode == 'stability') {
      stabw = max(stabw, 0.40);
      lw = max(lw, 0.35);
      latw = min(latw, 0.25);
    } else if (policy.mode == 'latency') {
      latw = max(latw, 0.50);
      lw = max(lw, 0.30);
    } else if (policy.mode == 'speed') {
      spw = max(spw, 0.40);
    }

    final totalWeight = lw + latw + stabw + spw;
    final normalizedScore = (totalWeight.isFinite && !totalWeight.isNaN && totalWeight > 0)
        ? (reliability * lw +
                latency * latw +
                stability * stabw +
                speed * spw) /
            totalWeight
        : 0.0;

    // Hysteresis: incumbent candidate gets a margin bonus to prevent
    // flapping when candidates have nearly identical latencies.
    final hysteresisBonus = isIncumbent ? 0.08 : 0.0;
    final finalScore = normalizedScore + hysteresisBonus;
    return (finalScore.isFinite && !finalScore.isNaN)
        ? finalScore
        : double.negativeInfinity;
  }

  Future<List<SmartGroupProbeResult>> _probeMissing(
    DaemonApiBase api,
    String groupID,
    List<String> candidateIDs,
    ManifestClientPolicy policy, {
    bool Function()? isCancelled,
  }) async {
    if (candidateIDs.isEmpty) return const <SmartGroupProbeResult>[];
    final results = <SmartGroupProbeResult>[];
    var next = 0;
    final concurrency = policy.maxParallelProbes.clamp(1, 4);
    final workers = List<Future<void>>.generate(concurrency, (_) async {
      while (true) {
        if (_cancelled || (isCancelled?.call() ?? false)) return;
        final index = next++;
        if (index >= candidateIDs.length) return;
        final candidateID = candidateIDs[index];
        try {
          // Honor policy parameters in probe call
          final result = await api.probeGroupCandidate(
            groupID,
            candidateID,
            probeMode: policy.probeMode,
            probeSamples: policy.probeSamples,
            probeUrl: policy.probeUrl,
          );
          results.add(result);
        } catch (_) {
          results.add(SmartGroupProbeResult(
            groupId: groupID,
            candidateId: candidateID,
            successful: false,
            samples: policy.probeSamples,
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

  /// Measures speed on top candidates.
  /// CRITICAL: MUST NOT disturb an already active tunnel during background tests.
  /// Background rank must NEVER connect candidates to measure speed.
  Future<List<SmartGroupSelection>> _measureSpeed(
    DaemonApiBase api,
    ManifestGroup group,
    List<SmartGroupSelection> ranked, {
    String? activeCandidateId,
    bool Function()? isCancelled,
  }) async {
    final policy = group.clientPolicy;
    final speedPolicy = policy.speedProbe;
    if (!speedPolicy.enabled || policy.speedWeight <= 0 || ranked.isEmpty) {
      return ranked;
    }

    if (_cancelled || (isCancelled?.call() ?? false)) {
      return ranked;
    }

    // Check if a tunnel is currently active. Fail closed on error or unknown state.
    VpnStatus currentStatus;
    try {
      currentStatus = await api.getStatus();
    } catch (_) {
      // Fail closed: cannot determine tunnel state, never attempt speed testing or candidate switching.
      return ranked;
    }

    // Only an actively connected tunnel can be tested. If disconnected, connecting,
    // or verifying, background rank must NEVER connect candidates.
    if (!currentStatus.isConnected) {
      return ranked;
    }

    final currentServerId = currentStatus.server?.id;
    if (currentServerId == null || currentServerId.isEmpty) {
      // No proven active server connected.
      return ranked;
    }

    final limit = min(speedPolicy.maxCandidates, ranked.length);
    final measured = <SmartGroupSelection>[];

    for (final selection in ranked.take(limit)) {
      if (_cancelled || (isCancelled?.call() ?? false)) {
        measured.add(selection);
        continue;
      }

      // Background rank must NEVER connect candidates to measure speed.
      // Only the proven exact active candidate is permitted; no substring id matching!
      final isCandidateActive = selection.candidateId == currentServerId &&
          (activeCandidateId == null ||
              activeCandidateId == selection.candidateId);

      if (!isCandidateActive) {
        measured.add(selection);
        continue;
      }

      // Ineligible or failed candidates must not be speed-tested
      if (!isEligibleWinner(selection.probe)) {
        measured.add(selection);
        continue;
      }

      if (_cancelled || (isCancelled?.call() ?? false)) {
        measured.add(selection);
        continue;
      }

      try {
        final result = await api.speedTest(policy: speedPolicy);
        if (_cancelled || (isCancelled?.call() ?? false)) {
          measured.add(selection);
          continue;
        }
        if (result.error.isEmpty && result.downloadBps > 0) {
          final probe = selection.probe.copyWith(
            downloadMbps: result.downloadBps / 125000,
            uploadMbps: result.uploadBps / 125000,
            checkedAt: DateTime.now(),
            probeKind: 'transport+https_speed',
          );
          measured.add(SmartGroupSelection(
            groupId: selection.groupId,
            candidateId: selection.candidateId,
            probe: probe,
            fromCache: false,
          ));
        } else {
          measured.add(selection);
        }
      } catch (_) {
        measured.add(selection);
      }
    }

    final untouched = ranked.skip(limit);
    final combined = <SmartGroupSelection>[...measured, ...untouched];
    combined.sort((left, right) {
      final isLeftIncumbent = left.candidateId == activeCandidateId;
      final isRightIncumbent = right.candidateId == activeCandidateId;
      return _score(right.probe, policy, isIncumbent: isRightIncumbent)
          .compareTo(_score(left.probe, policy, isIncumbent: isLeftIncumbent));
    });
    return combined;
  }

  /// Fetches the server-issued shard and ranks candidates in the device's own
  /// network with singleflight bounded concurrency, network-scoped caching,
  /// policy-honoring sweeps, and exclusion of failed/unverified nodes.
  Future<List<SmartGroupSelection>> rank(
    DaemonApiBase api,
    ManifestGroup group, {
    bool measureSpeed = false,
    String? networkScope,
    bool forceRefresh = false,
    String? activeCandidateId,
    bool Function()? isCancelled,
  }) async {
    final startCancelEpoch = _cancelEpoch;
    bool checkCancelled() =>
        _cancelled ||
        _cancelEpoch != startCancelEpoch ||
        (isCancelled?.call() ?? false);

    if (checkCancelled()) {
      return const <SmartGroupSelection>[];
    }

    if (group.disabled) {
      throw StateError(group.disabledReason.isEmpty
          ? 'Smart Group is disabled by the provider.'
          : group.disabledReason);
    }

    final resolvedScope = await resolveNetworkScope(api, networkScope);
    if (checkCancelled()) {
      return const <SmartGroupSelection>[];
    }

    final flightKey = '$resolvedScope::${group.id}::$measureSpeed';
    final refreshFlightKey = '$resolvedScope::${group.id}::$measureSpeed::refresh';

    if (!forceRefresh) {
      final inFlight = _inflightRanks[refreshFlightKey] ?? _inflightRanks[flightKey];
      if (inFlight != null) {
        return inFlight;
      }
    } else {
      final inFlight = _inflightRanks[refreshFlightKey];
      if (inFlight != null) {
        return inFlight;
      }
    }

    if (forceRefresh) {
      _cacheEpoch++;
    }

    late final Future<List<SmartGroupSelection>> future;
    future = _doRank(
      api,
      group,
      measureSpeed: measureSpeed,
      networkScope: resolvedScope,
      forceRefresh: forceRefresh,
      activeCandidateId: activeCandidateId,
      isCancelled: checkCancelled,
    );

    if (forceRefresh) {
      _inflightRanks[refreshFlightKey] = future;
      _inflightRanks[flightKey] = future;
    } else {
      _inflightRanks[flightKey] = future;
    }

    try {
      return await future;
    } finally {
      if (forceRefresh) {
        if (identical(_inflightRanks[refreshFlightKey], future)) {
          _inflightRanks.remove(refreshFlightKey);
        }
      }
      if (identical(_inflightRanks[flightKey], future)) {
        _inflightRanks.remove(flightKey);
      }
    }
  }

  Future<List<SmartGroupSelection>> _doRank(
    DaemonApiBase api,
    ManifestGroup group, {
    required bool measureSpeed,
    required String networkScope,
    required bool forceRefresh,
    String? activeCandidateId,
    bool Function()? isCancelled,
  }) async {
    if (_cancelled || (isCancelled?.call() ?? false)) {
      return const <SmartGroupSelection>[];
    }

    final epochAtStart = _cacheEpoch;
    final installationID = await _installationID();
    if (_cancelled || (isCancelled?.call() ?? false)) {
      return const <SmartGroupSelection>[];
    }

    final shard = await api.getCandidateShard(group.id, installationID);
    if (_cancelled || (isCancelled?.call() ?? false)) {
      return const <SmartGroupSelection>[];
    }
    if (shard.candidateIds.isEmpty) {
      throw StateError('No eligible candidates are available for this route.');
    }

    final cache = await _readCache();
    final cached = <String, SmartGroupProbeResult>{};
    final missing = <String>[];

    for (final candidateID in shard.candidateIds) {
      final key = _cacheKey(networkScope, group.id, candidateID);
      final saved = cache[key];
      if (!forceRefresh && saved != null && _fresh(saved, group.clientPolicy)) {
        cached[candidateID] = saved;
      } else {
        missing.add(candidateID);
      }
    }

    if (missing.isNotEmpty) {
      final fresh = await _probeMissing(
        api,
        group.id,
        missing,
        group.clientPolicy,
        isCancelled: isCancelled,
      );

      if (_cancelled || (isCancelled?.call() ?? false)) {
        return const <SmartGroupSelection>[];
      }

      for (final result in fresh) {
        cached[result.candidateId] = result;
      }

      // Prevent side effects and stale cache refill after invalidation or cancellation
      if (_cacheEpoch == epochAtStart &&
          !_cancelled &&
          !(isCancelled?.call() ?? false)) {
        final currentCache = await _readCache();
        for (final result in fresh) {
          final key = _cacheKey(networkScope, group.id, result.candidateId);
          currentCache[key] = result;
        }
        await _writeCache(currentCache);
      }
    }

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

    // Sort with hysteresis if active candidate is known
    ranked.sort((left, right) {
      final isLeftIncumbent = left.candidateId == activeCandidateId;
      final isRightIncumbent = right.candidateId == activeCandidateId;
      return _score(right.probe, group.clientPolicy, isIncumbent: isRightIncumbent)
          .compareTo(_score(left.probe, group.clientPolicy,
              isIncumbent: isLeftIncumbent));
    });

    final ordered = measureSpeed
        ? await _measureSpeed(api, group, ranked,
            activeCandidateId: activeCandidateId,
            isCancelled: isCancelled)
        : ranked;

    if (_cancelled || (isCancelled?.call() ?? false)) {
      return const <SmartGroupSelection>[];
    }

    // Strict gate: Exclude failed or unknown candidates from winning!
    return ordered
        .where((selection) => isEligibleWinner(selection.probe))
        .toList();
  }

  /// Connects candidates in local quality order. The local daemon verifies the
  /// selected candidate belongs to the group before each connection attempt.
  Future<SmartGroupSelection> connect(
    DaemonApiBase api,
    ManifestGroup group, {
    String? networkScope,
    bool Function()? isCancelled,
  }) async {
    if (_cancelled || (isCancelled?.call() ?? false)) {
      throw StateError('Connection cancelled.');
    }
    final ranked = await rank(
      api,
      group,
      measureSpeed: false,
      networkScope: networkScope,
      isCancelled: isCancelled,
    );

    if (ranked.isEmpty) {
      if (_cancelled || (isCancelled?.call() ?? false)) {
        throw StateError('Connection cancelled.');
      }
      throw StateError(
          'No reachable or verified candidates are available for this route.');
    }

    if (_cancelled || (isCancelled?.call() ?? false)) {
      throw StateError('Connection cancelled.');
    }

    final attemptCount =
        min(group.clientPolicy.maxFailoverTries, ranked.length);
    Object? lastError;

    for (final selection in ranked.take(attemptCount)) {
      if (_cancelled || (isCancelled?.call() ?? false)) {
        throw StateError('Connection cancelled.');
      }
      try {
        await api.connectGroupCandidate(group.id, selection.candidateId);
        // Settling delay: TUN interfaces and urltest pools need ~600ms before
        // the first probe can pass reliably. Without this, cold DNS and kernel
        // route setup cause false negatives on the first HTTP check.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return selection;
      } catch (error) {
        lastError = error;
      }
    }

    final safeDiag = sanitizeDiagnosticError(lastError);
    throw StateError('All local failover candidates failed: $safeDiag');
  }

  /// Formats last verified measurement label (e.g. "45 ms · ±4 ms · 12.5 Мбит/с").
  static String formatMeasurement(SmartGroupProbeResult probe) {
    if (probe.isUnverified || probe.samples == 0) {
      return 'Не проверен';
    }
    if (!isEligibleWinner(probe)) {
      return 'Недоступен';
    }
    final parts = <String>[];
    if (probe.medianLatencyMs > 0) {
      parts.add('${probe.medianLatencyMs} ms');
    }
    if (probe.jitterMs > 0) {
      parts.add('±${probe.jitterMs} ms');
    }
    if (probe.lossPercent > 0) {
      parts.add('${probe.lossPercent.toStringAsFixed(0)}% потерь');
    }
    if (probe.downloadMbps > 0) {
      parts.add('${probe.downloadMbps.toStringAsFixed(1)} Мбит/с');
    }
    return parts.isEmpty ? 'Проверено' : parts.join(' · ');
  }

  /// Formats measurement age (e.g. "только что", "5 мин назад").
  static String formatAge(DateTime checkedAt, [DateTime? now]) {
    final current = now ?? DateTime.now();
    final diff = current.difference(checkedAt);
    if (diff.isNegative || diff.inSeconds < 60) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
    if (diff.inHours < 24) return '${diff.inHours} ч назад';
    return '${diff.inDays} д назад';
  }

  /// Sanitizes error messages for user diagnostics, stripping IP addresses,
  /// tokens, passwords, private keys, and sensitive URLs.
  static String sanitizeDiagnosticError(Object? error) {
    if (error == null) return 'Неизвестная ошибка';
    return redactDiagnosticText(error.toString()).trim();
  }
}
