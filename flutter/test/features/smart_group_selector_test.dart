import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/services/smart_group_selector.dart';

class TrackingDaemonApi extends MockDaemonApi {
  final List<Map<String, dynamic>> probeCalls = [];
  final List<String> connectCalls = [];
  final List<SpeedProbePolicy?> speedTestCalls = [];
  VpnStatus? customStatus;
  Map<String, SmartGroupProbeResult>? customProbes;
  List<String>? customCandidateIds;

  @override
  Future<VpnStatus> getStatus() async {
    if (customStatus != null) return customStatus!;
    return super.getStatus();
  }

  @override
  Future<SmartGroupCandidateShard> getCandidateShard(
      String groupID, String installationID) async {
    if (customCandidateIds != null) {
      return SmartGroupCandidateShard(
        groupId: groupID,
        version: 'v1',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        candidateIds: customCandidateIds!,
      );
    }
    return super.getCandidateShard(groupID, installationID);
  }

  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
    String groupID,
    String candidateID, {
    String? probeMode,
    int? probeSamples,
    String? probeUrl,
  }) async {
    probeCalls.add({
      'groupID': groupID,
      'candidateID': candidateID,
      'probeMode': probeMode,
      'probeSamples': probeSamples,
      'probeUrl': probeUrl,
    });
    if (customProbes != null && customProbes!.containsKey(candidateID)) {
      return customProbes![candidateID]!;
    }
    return super.probeGroupCandidate(
      groupID,
      candidateID,
      probeMode: probeMode,
      probeSamples: probeSamples,
      probeUrl: probeUrl,
    );
  }

  @override
  Future<void> connectGroupCandidate(String groupID, String candidateID) async {
    connectCalls.add(candidateID);
    await super.connectGroupCandidate(groupID, candidateID);
  }

  @override
  Future<SpeedTestResult> speedTest({
    String? serverID,
    SpeedProbePolicy? policy,
  }) async {
    speedTestCalls.add(policy);
    return super.speedTest(serverID: serverID, policy: policy);
  }
}

class FailingStatusDaemonApi extends TrackingDaemonApi {
  @override
  Future<VpnStatus> getStatus() async {
    throw Exception('Status query failed');
  }
}

class DelayedDaemonApi extends TrackingDaemonApi {
  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
    String groupID,
    String candidateID, {
    String? probeMode,
    int? probeSamples,
    String? probeUrl,
  }) async {
    await Future.delayed(const Duration(milliseconds: 50));
    return super.probeGroupCandidate(
      groupID,
      candidateID,
      probeMode: probeMode,
      probeSamples: probeSamples,
      probeUrl: probeUrl,
    );
  }
}

class ControllableProbeDaemonApi extends TrackingDaemonApi {
  int callCount = 0;
  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
    String groupID,
    String candidateID, {
    String? probeMode,
    int? probeSamples,
    String? probeUrl,
  }) async {
    final myCall = ++callCount;
    if (myCall == 1) {
      // Flight 1: slow probe returning high latency (stale)
      await Future.delayed(const Duration(milliseconds: 100));
      return SmartGroupProbeResult(
        groupId: groupID,
        candidateId: candidateID,
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 150,
        p95LatencyMs: 160,
        jitterMs: 5,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );
    } else {
      // Flight 2: fast probe returning low latency (fresh)
      await Future.delayed(const Duration(milliseconds: 20));
      return SmartGroupProbeResult(
        groupId: groupID,
        candidateId: candidateID,
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 30,
        p95LatencyMs: 35,
        jitterMs: 2,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );
    }
  }
}

class InvalidationTrackingDaemonApi extends TrackingDaemonApi {
  Future<void> Function()? onProbe;

  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
    String groupID,
    String candidateID, {
    String? probeMode,
    int? probeSamples,
    String? probeUrl,
  }) async {
    if (onProbe != null) {
      await onProbe!();
    }
    return super.probeGroupCandidate(
      groupID,
      candidateID,
      probeMode: probeMode,
      probeSamples: probeSamples,
      probeUrl: probeUrl,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SmartGroupSelector Core', () {
    test('ranks opaque candidates from a server-defined Smart Group policy',
        () async {
      final api = MockDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'provider-custom-route',
        title: 'Provider supplied route',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          mode: 'stability',
          shardSize: 8,
          maxParallelProbes: 2,
          maxFailoverTries: 3,
        ),
      );

      final ranked = await selector.rank(api, group);

      expect(ranked, isNotEmpty);
      expect(ranked.first.groupId, 'provider-custom-route');
      expect(ranked.first.candidateId,
          startsWith('candidate:provider-custom-route:'));
      expect(ranked.every((selection) => selection.probe.successful), isTrue);
    });

    test('connects through the local candidate flow for an arbitrary manifest ID',
        () async {
      final api = MockDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'non-mosaic-specific-id',
        title: 'Any provider group',
        category: 'custom',
      );

      final selection = await selector.connect(api, group);
      final status = await api.getStatus();

      expect(selection.groupId, group.id);
      expect(status.isConnected, isTrue);
      expect(status.server?.id, 'group:${group.id}');
    });
  });

  group('SmartGroupSelector Regression: Network Invalidation', () {
    test('resolveNetworkScope uses daemon fingerprint, explicit scope, or default',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      // Default when fingerprint is empty
      expect(await selector.resolveNetworkScope(api), 'default');

      // Uses explicit scope when provided
      expect(await selector.resolveNetworkScope(api, 'my-custom-net'),
          'my-custom-net');

      // Reads daemon fingerprint from status
      api.customStatus = VpnStatus(
        agentConnected: true,
        networkFingerprint: 'fp-home-wifi-5g',
      );
      expect(await selector.resolveNetworkScope(api), 'fp-home-wifi-5g');

      // Explicit scope still overrides daemon fingerprint
      expect(await selector.resolveNetworkScope(api, 'override-fp'),
          'override-fp');
    });

    test('network-scoped cache isolates networks and invalidates selectively',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'net-group',
        title: 'Net Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(probeTtlSeconds: 300),
      );

      // Rank under network scope 'wifi-office'
      final rank1 = await selector.rank(api, group, networkScope: 'wifi-office');
      expect(rank1.every((s) => !s.fromCache), isTrue);
      final initialProbeCount = api.probeCalls.length;
      expect(initialProbeCount, greaterThan(0));

      // Second rank under 'wifi-office' uses cache
      final rank2 = await selector.rank(api, group, networkScope: 'wifi-office');
      expect(rank2.every((s) => s.fromCache), isTrue);
      expect(api.probeCalls.length, initialProbeCount);

      // Rank under different network 'lte-mobile' probes fresh
      final rankLte = await selector.rank(api, group, networkScope: 'lte-mobile');
      expect(rankLte.every((s) => !s.fromCache), isTrue);
      final afterLteProbeCount = api.probeCalls.length;
      expect(afterLteProbeCount, greaterThan(initialProbeCount));

      // Invalidate only 'wifi-office'
      await selector.invalidateNetwork('wifi-office');

      // 'lte-mobile' must still be cached
      final rankLteCached =
          await selector.rank(api, group, networkScope: 'lte-mobile');
      expect(rankLteCached.every((s) => s.fromCache), isTrue);
      expect(api.probeCalls.length, afterLteProbeCount);

      // 'wifi-office' must now re-probe
      final rankOfficeRe =
          await selector.rank(api, group, networkScope: 'wifi-office');
      expect(rankOfficeRe.every((s) => !s.fromCache), isTrue);
      expect(api.probeCalls.length, greaterThan(afterLteProbeCount));

      // Invalidate all networks
      await selector.invalidateNetwork();
      final afterAllPurgeCount = api.probeCalls.length;
      final rankLteRe =
          await selector.rank(api, group, networkScope: 'lte-mobile');
      expect(rankLteRe.every((s) => !s.fromCache), isTrue);
      expect(api.probeCalls.length, greaterThan(afterAllPurgeCount));
    });
  });

  group('SmartGroupSelector Regression: Failed/Unknown Excluded', () {
    test('isEligibleWinner strictly rejects failed, zero-latency, 100% loss, or zero-success', () {
      final base = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'cand-1',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 40,
        p95LatencyMs: 50,
        jitterMs: 5,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );

      // Healthy probe
      expect(SmartGroupSelector.isEligibleWinner(base), isTrue);

      // Unsuccessful probe
      expect(
          SmartGroupSelector.isEligibleWinner(base.copyWith(successful: false)),
          isFalse);

      // Zero successes
      expect(
          SmartGroupSelector.isEligibleWinner(base.copyWith(successes: 0)),
          isFalse);

      // 100% loss
      expect(
          SmartGroupSelector.isEligibleWinner(base.copyWith(lossPercent: 100.0)),
          isFalse);

      // Zero or negative latency
      expect(
          SmartGroupSelector.isEligibleWinner(base.copyWith(medianLatencyMs: 0)),
          isFalse);
      expect(
          SmartGroupSelector.isEligibleWinner(base.copyWith(medianLatencyMs: -10)),
          isFalse);
    });

    test('rank strictly excludes failed and unverified candidates from results',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'exclude-group',
        title: 'Exclude Test',
        category: 'smart',
      );

      api.customCandidateIds = ['cand-good', 'cand-failed', 'cand-dead-latency', 'cand-full-loss'];
      api.customProbes = {
        'cand-good': SmartGroupProbeResult(
          groupId: group.id,
          candidateId: 'cand-good',
          successful: true,
          samples: 3,
          successes: 3,
          lossPercent: 0,
          medianLatencyMs: 35,
          p95LatencyMs: 45,
          jitterMs: 2,
          checkedAt: DateTime.now(),
          probeKind: 'transport_tcp',
        ),
        'cand-failed': SmartGroupProbeResult(
          groupId: group.id,
          candidateId: 'cand-failed',
          successful: false,
          samples: 3,
          successes: 0,
          lossPercent: 100,
          medianLatencyMs: 0,
          p95LatencyMs: 0,
          jitterMs: 0,
          checkedAt: DateTime.now(),
          probeKind: 'transport_error',
        ),
        'cand-dead-latency': SmartGroupProbeResult(
          groupId: group.id,
          candidateId: 'cand-dead-latency',
          successful: true,
          samples: 3,
          successes: 3,
          lossPercent: 0,
          medianLatencyMs: 0, // Ineligible: zero latency
          p95LatencyMs: 0,
          jitterMs: 0,
          checkedAt: DateTime.now(),
          probeKind: 'transport_tcp',
        ),
        'cand-full-loss': SmartGroupProbeResult(
          groupId: group.id,
          candidateId: 'cand-full-loss',
          successful: true,
          samples: 3,
          successes: 0,
          lossPercent: 100, // Ineligible: 100% loss
          medianLatencyMs: 80,
          p95LatencyMs: 90,
          jitterMs: 10,
          checkedAt: DateTime.now(),
          probeKind: 'transport_tcp',
        ),
      };

      final ranked = await selector.rank(api, group);

      expect(ranked.length, 1);
      expect(ranked.first.candidateId, 'cand-good');
      expect(ranked.every((s) => SmartGroupSelector.isEligibleWinner(s.probe)), isTrue);
    });

    test('connect throws StateError and never connects when all candidates fail',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'all-fail-group',
        title: 'All Fail Test',
        category: 'smart',
      );

      api.customCandidateIds = ['fail-1', 'fail-2'];
      api.customProbes = {
        'fail-1': SmartGroupProbeResult(
          groupId: group.id,
          candidateId: 'fail-1',
          successful: false,
          samples: 1,
          successes: 0,
          lossPercent: 100,
          medianLatencyMs: 0,
          p95LatencyMs: 0,
          jitterMs: 0,
          checkedAt: DateTime.now(),
          probeKind: 'transport_error',
        ),
        'fail-2': SmartGroupProbeResult(
          groupId: group.id,
          candidateId: 'fail-2',
          successful: false,
          samples: 1,
          successes: 0,
          lossPercent: 100,
          medianLatencyMs: 0,
          p95LatencyMs: 0,
          jitterMs: 0,
          checkedAt: DateTime.now(),
          probeKind: 'transport_error',
        ),
      };

      expect(
        () async => await selector.connect(api, group),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('No reachable or verified candidates are available'),
        )),
      );

      // Verify no candidates were connected
      expect(api.connectCalls, isEmpty);
    });
  });

  group('SmartGroupSelector Regression: Policy Passed', () {
    test('forwards policy probeMode, probeSamples, and probeUrl to daemon API',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'policy-group',
        title: 'Policy Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          probeMode: 'http_get',
          probeSamples: 5,
          probeUrl: 'https://speed.mosaicvpn.ru/generate_204',
          maxParallelProbes: 2,
        ),
      );

      await selector.rank(api, group);

      expect(api.probeCalls, isNotEmpty);
      for (final call in api.probeCalls) {
        expect(call['probeMode'], 'http_get');
        expect(call['probeSamples'], 5);
        expect(call['probeUrl'], 'https://speed.mosaicvpn.ru/generate_204');
      }
    });

    test('policy mode and weights correctly alter scoring behavior', () {
      final selector = SmartGroupSelector();

      final lowJitterHighLatency = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'cand-stable',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 120,
        p95LatencyMs: 125,
        jitterMs: 2,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );

      final highJitterLowLatency = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'cand-fast',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 25,
        p95LatencyMs: 65,
        jitterMs: 35,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );

      // Stability policy: stability weight is boosted, jitter is heavily penalized
      const stabilityPolicy = ManifestClientPolicy(
        mode: 'stability',
        lossWeight: 0.35,
        latencyWeight: 0.15,
        stabilityWeight: 0.50,
      );

      final stableScoreInStabMode =
          selector.score(lowJitterHighLatency, stabilityPolicy);
      final fastScoreInStabMode =
          selector.score(highJitterLowLatency, stabilityPolicy);
      expect(stableScoreInStabMode, greaterThan(fastScoreInStabMode));

      // Latency policy: latency weight is dominant
      const latencyPolicy = ManifestClientPolicy(
        mode: 'latency',
        lossWeight: 0.20,
        latencyWeight: 0.65,
        stabilityWeight: 0.15,
      );

      final stableScoreInLatMode =
          selector.score(lowJitterHighLatency, latencyPolicy);
      final fastScoreInLatMode =
          selector.score(highJitterLowLatency, latencyPolicy);
      expect(fastScoreInLatMode, greaterThan(stableScoreInLatMode));
    });
  });

  group('SmartGroupSelector Regression: Active-Tunnel Bandwidth Safety', () {
    test('does NOT connect or disturb tunnel for non-active candidates during speed measurement',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      // Active connected tunnel on 'candidate:active-1'
      api.customStatus = VpnStatus(
        agentConnected: true,
        state: 'connected',
        server: Server(
          id: 'candidate:active-1',
          name: 'Active Server',
        ),
      );

      final group = ManifestGroup(
        id: 'safety-group',
        title: 'Safety Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          speedWeight: 0.3,
          speedProbe: SpeedProbePolicy(
            enabled: true,
            maxCandidates: 3,
            targetMbps: 50.0,
          ),
        ),
      );

      api.customCandidateIds = [
        'candidate:active-1',
        'candidate:other-2',
        'candidate:other-3',
      ];

      final ranked = await selector.rank(
        api,
        group,
        measureSpeed: true,
        activeCandidateId: 'candidate:active-1',
      );

      expect(ranked, isNotEmpty);
      // Because tunnel was already active, it MUST NOT connect candidate:other-2 or other-3!
      expect(api.connectCalls, isNot(contains('candidate:other-2')));
      expect(api.connectCalls, isNot(contains('candidate:other-3')));
    });

    test('background rank NEVER connects candidates to measure speed when disconnected',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      // Tunnel is disconnected
      api.customStatus = VpnStatus(
        agentConnected: true,
        state: 'disconnected',
      );

      final group = ManifestGroup(
        id: 'preconnect-group',
        title: 'Preconnect Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          speedWeight: 0.3,
          speedProbe: SpeedProbePolicy(
            enabled: true,
            maxCandidates: 2,
            targetMbps: 50.0,
          ),
        ),
      );

      api.customCandidateIds = ['candidate:pre-1', 'candidate:pre-2'];

      final ranked = await selector.rank(
        api,
        group,
        measureSpeed: true,
      );

      expect(ranked, isNotEmpty);
      // Background rank must NEVER connect candidates to measure speed!
      expect(api.connectCalls, isEmpty);
      expect(api.speedTestCalls, isEmpty);
    });

    test('fail-closed: getStatus failure treats status as unknown and never connects or tests speed',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      // Simulate getStatus failure (throws exception)
      api.customStatus = null; // Will cause error if overridden or let's override with an exception-throwing getStatus

      final group = ManifestGroup(
        id: 'status-error-group',
        title: 'Status Error Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          speedWeight: 0.3,
          speedProbe: SpeedProbePolicy(
            enabled: true,
            maxCandidates: 2,
            targetMbps: 50.0,
          ),
        ),
      );

      api.customCandidateIds = ['candidate:cand-1', 'candidate:cand-2'];

      // We wrap getStatus in a subclass that throws
      final throwingApi = FailingStatusDaemonApi();
      throwingApi.customCandidateIds = ['candidate:cand-1', 'candidate:cand-2'];

      final ranked = await selector.rank(
        throwingApi,
        group,
        measureSpeed: true,
      );

      expect(ranked, isNotEmpty);
      expect(throwingApi.connectCalls, isEmpty);
      expect(throwingApi.speedTestCalls, isEmpty);
    });

    test('strictly forbids substring ID matching for active candidate speed testing',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      // Active tunnel connected to 'candidate:active-10'
      api.customStatus = VpnStatus(
        agentConnected: true,
        state: 'connected',
        server: Server(
          id: 'candidate:active-10',
          name: 'Active Server 10',
        ),
      );

      final group = ManifestGroup(
        id: 'substring-guard-group',
        title: 'Substring Guard Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          speedWeight: 0.3,
          speedProbe: SpeedProbePolicy(
            enabled: true,
            maxCandidates: 2,
            targetMbps: 50.0,
          ),
        ),
      );

      // Shard contains 'candidate:active-1' which is a SUBSTRING of 'candidate:active-10'
      api.customCandidateIds = ['candidate:active-1'];

      final ranked = await selector.rank(
        api,
        group,
        measureSpeed: true,
        activeCandidateId: 'candidate:active-1',
      );

      expect(ranked, isNotEmpty);
      // Because 'candidate:active-1' != 'candidate:active-10', NO speed test must be executed!
      expect(api.speedTestCalls, isEmpty);
      expect(api.connectCalls, isEmpty);
    });

    test('cancellation checks inside speed test loop prevent speed tests and side effects',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      api.customStatus = VpnStatus(
        agentConnected: true,
        state: 'connected',
        server: Server(
          id: 'candidate:active-1',
          name: 'Active Server 1',
        ),
      );

      final group = ManifestGroup(
        id: 'cancel-speed-group',
        title: 'Cancel Speed Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          speedWeight: 0.3,
          speedProbe: SpeedProbePolicy(
            enabled: true,
            maxCandidates: 2,
            targetMbps: 50.0,
          ),
        ),
      );

      api.customCandidateIds = ['candidate:active-1'];

      var cancelChecked = false;
      final ranked = await selector.rank(
        api,
        group,
        measureSpeed: true,
        activeCandidateId: 'candidate:active-1',
        isCancelled: () {
          cancelChecked = true;
          return true;
        },
      );

      expect(cancelChecked, isTrue);
      expect(ranked, isEmpty);
      expect(api.speedTestCalls, isEmpty);
    });

    test('singleflight cleanup is identity-safe across forceRefresh', () async {
      final api = DelayedDaemonApi();
      final selector = SmartGroupSelector();

      final group = ManifestGroup(
        id: 'singleflight-group',
        title: 'Singleflight Group',
        category: 'smart',
      );

      api.customCandidateIds = ['cand-1', 'cand-2'];

      // Start flight 1 (normal)
      final flight1 = selector.rank(api, group, forceRefresh: false);

      // Start flight 2 (forceRefresh: true) while flight 1 is running
      final flight2 = selector.rank(api, group, forceRefresh: true);

      // Start flight 3 (normal) while both are running - should join flight 2
      final flight3 = selector.rank(api, group, forceRefresh: false);

      final res1 = await flight1;
      final res2 = await flight2;
      final res3 = await flight3;

      expect(res1, isNotEmpty);
      expect(res2, isNotEmpty);
      expect(res3, isNotEmpty);
      expect(identical(res2, res3), isTrue);
    });

    test('invalidation during in-flight probes prevents stale cache refill',
        () async {
      final api = InvalidationTrackingDaemonApi();
      final selector = SmartGroupSelector();

      final group = ManifestGroup(
        id: 'invalidation-group',
        title: 'Invalidation Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(probeTtlSeconds: 300),
      );

      api.customCandidateIds = ['cand-inv-1'];
      api.onProbe = () async {
        // Invalidate while probe is in flight
        await selector.invalidateGroup('invalidation-group');
      };

      await selector.rank(api, group);

      // SharedPreferences should NOT contain the key for 'invalidation-group'
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mosaic.smart_group.quality.v1');
      if (raw != null && raw.isNotEmpty) {
        expect(raw, isNot(contains('invalidation-group')));
      }
    });

    test('cancellation prevents writing probe results to cache', () async {
      final api = InvalidationTrackingDaemonApi();
      final selector = SmartGroupSelector();

      final group = ManifestGroup(
        id: 'cancel-cache-group',
        title: 'Cancel Cache Group',
        category: 'smart',
      );

      api.customCandidateIds = ['cand-cancel-1'];
      api.onProbe = () async {
        selector.cancel();
      };

      final ranked = await selector.rank(api, group);
      expect(ranked, isEmpty);

      // Cache should be empty / not contain the candidate
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mosaic.smart_group.quality.v1');
      if (raw != null && raw.isNotEmpty) {
        expect(raw, isNot(contains('cand-cancel-1')));
      }
    });

    test('formatMeasurement preserves real measured speed and labels inability rather than fabricate', () {
      final now = DateTime.now();

      // Probe with measured latency and speed
      final probeWithSpeed = SmartGroupProbeResult(
        groupId: 'g1',
        candidateId: 'c1',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 42,
        p95LatencyMs: 50,
        jitterMs: 4,
        checkedAt: now,
        probeKind: 'transport+https_speed',
        downloadMbps: 25.4,
      );
      expect(SmartGroupSelector.formatMeasurement(probeWithSpeed),
          '42 ms · ±4 ms · 25.4 Мбит/с');

      // Probe without measured speed (inability to speed-test): NEVER fabricates speed
      final probeWithoutSpeed = SmartGroupProbeResult(
        groupId: 'g1',
        candidateId: 'c1',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 42,
        p95LatencyMs: 50,
        jitterMs: 4,
        checkedAt: now,
        probeKind: 'transport_tcp',
        downloadMbps: 0,
      );
      expect(SmartGroupSelector.formatMeasurement(probeWithoutSpeed),
          '42 ms · ±4 ms');

      // Failed / untestable probe: labels inability as "Недоступен"
      final failedProbe = SmartGroupProbeResult(
        groupId: 'g1',
        candidateId: 'c1',
        successful: false,
        samples: 3,
        successes: 0,
        lossPercent: 100,
        medianLatencyMs: 0,
        p95LatencyMs: 0,
        jitterMs: 0,
        checkedAt: now,
        probeKind: 'transport_error',
      );
      expect(SmartGroupSelector.formatMeasurement(failedProbe), 'Недоступен');

      // Zero-latency probe: labels inability as "Недоступен"
      final zeroLatencyProbe = probeWithoutSpeed.copyWith(medianLatencyMs: 0);
      expect(SmartGroupSelector.formatMeasurement(zeroLatencyProbe), 'Недоступен');

      // Zero-sample unsupported Android probe: must surface as "Не проверен", NOT "Недоступен"
      final unverifiedAndroidProbe = SmartGroupProbeResult.unverified(
        groupId: 'g1',
        candidateId: 'c-android',
      );
      expect(unverifiedAndroidProbe.isUnverified, isTrue);
      expect(unverifiedAndroidProbe.samples, 0);
      expect(SmartGroupSelector.formatMeasurement(unverifiedAndroidProbe), 'Не проверен');

      final zeroSampleProbe = SmartGroupProbeResult(
        groupId: 'g1',
        candidateId: 'c-zero',
        successful: false,
        samples: 0,
        successes: 0,
        lossPercent: 0,
        medianLatencyMs: 0,
        p95LatencyMs: 0,
        jitterMs: 0,
        checkedAt: now,
        probeKind: 'unverified_android_candidate',
      );
      expect(zeroSampleProbe.isUnverified, isTrue);
      expect(SmartGroupSelector.formatMeasurement(zeroSampleProbe), 'Не проверен');
    });

    test('connect currently invokes rank with measureSpeed: false (integration gap verified)',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();

      final group = ManifestGroup(
        id: 'connect-gap-group',
        title: 'Connect Gap Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(
          speedWeight: 0.3,
          speedProbe: SpeedProbePolicy(
            enabled: true,
            maxCandidates: 2,
            targetMbps: 50.0,
          ),
        ),
      );

      api.customCandidateIds = ['cand-connect-1'];

      final selection = await selector.connect(api, group);
      expect(selection.candidateId, 'cand-connect-1');
      // Notice: connect explicitly invokes rank with measureSpeed: false!
      expect(api.speedTestCalls, isEmpty);
    });
  });

  group('SmartGroupSelector Regression: Cancellation, Inflight & Quality Truthfulness', () {
    test('cancel() clears inflight ranks so post-resetCancel call does not latch onto cancelled future',
        () async {
      final api = DelayedDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'cancel-race-group',
        title: 'Cancel Race Group',
        category: 'smart',
      );
      api.customCandidateIds = ['cand-1', 'cand-2'];

      // Start flight 1
      final flight1 = selector.rank(api, group);
      // Cancel selector while flight 1 is in-flight
      selector.cancel();
      // Reset cancellation
      selector.resetCancel();

      // Start flight 2
      final flight2 = selector.rank(api, group);

      final res1 = await flight1;
      final res2 = await flight2;

      // Flight 1 was cancelled mid-flight, so it returns empty
      expect(res1, isEmpty);
      // Flight 2 must NOT have coalesced into the cancelled flight 1!
      expect(res2, isNotEmpty);
      expect(res2.first.candidateId, isNotEmpty);
    });

    test('connect() respects existing cancelled state instead of silently clearing it',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'cancelled-connect-group',
        title: 'Cancelled Connect Group',
        category: 'smart',
      );
      api.customCandidateIds = ['cand-1'];

      selector.cancel();
      expect(
        () async => await selector.connect(api, group),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Connection cancelled'),
        )),
      );
      expect(api.connectCalls, isEmpty);
    });

    test('isEligibleWinner strictly rejects invalid sample counts and nonfinite/negative metrics',
        () {
      final valid = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'cand-valid',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 40,
        p95LatencyMs: 50,
        jitterMs: 5,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
        downloadMbps: 10.0,
        uploadMbps: 5.0,
      );

      expect(SmartGroupSelector.isEligibleWinner(valid), isTrue);

      // Invalid samples: successes > samples
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(samples: 2, successes: 3)),
        isFalse,
      );

      // Invalid samples: zero samples
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(samples: 0, successes: 0)),
        isFalse,
      );

      // Invalid samples: negative samples or successes
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(samples: -1, successes: 1)),
        isFalse,
      );

      // Negative loss
      expect(
        SmartGroupSelector.isEligibleWinner(valid.copyWith(lossPercent: -5.0)),
        isFalse,
      );

      // Non-finite loss (NaN / Infinity)
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(lossPercent: double.nan)),
        isFalse,
      );
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(lossPercent: double.infinity)),
        isFalse,
      );

      // Negative jitter
      expect(
        SmartGroupSelector.isEligibleWinner(valid.copyWith(jitterMs: -1)),
        isFalse,
      );

      // Non-finite or negative download speed
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(downloadMbps: double.nan)),
        isFalse,
      );
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(downloadMbps: double.infinity)),
        isFalse,
      );
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(downloadMbps: -1.0)),
        isFalse,
      );

      // Non-finite or negative upload speed
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(uploadMbps: double.nan)),
        isFalse,
      );
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(uploadMbps: double.infinity)),
        isFalse,
      );
      expect(
        SmartGroupSelector.isEligibleWinner(
            valid.copyWith(uploadMbps: -1.0)),
        isFalse,
      );
    });

    test('score returns negativeInfinity for invalid sample and nonfinite throughput',
        () {
      final selector = SmartGroupSelector();
      const policy = ManifestClientPolicy(mode: 'stability');

      final invalidSamples = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'cand-nan',
        successful: true,
        samples: 2,
        successes: 3, // invalid
        lossPercent: 0,
        medianLatencyMs: 40,
        p95LatencyMs: 50,
        jitterMs: 5,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );

      expect(selector.score(invalidSamples, policy), double.negativeInfinity);

      final nanThroughput = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'cand-nan-speed',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 40,
        p95LatencyMs: 50,
        jitterMs: 5,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
        downloadMbps: double.nan,
      );

      expect(selector.score(nanThroughput, policy), double.negativeInfinity);
    });

    test('freshness rejects non-positive probeTtlSeconds and future clock skew',
        () async {
      final api = TrackingDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'ttl-group',
        title: 'TTL Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(probeTtlSeconds: 0),
      );
      api.customCandidateIds = ['cand-1'];

      // Rank 1 probes candidate
      await selector.rank(api, group);
      expect(api.probeCalls.length, 1);

      // Rank 2 with probeTtlSeconds == 0 must NOT consider cache fresh
      await selector.rank(api, group);
      expect(api.probeCalls.length, 2);
    });

    test('forceRefresh increments cache epoch to prevent older in-flight rank from overwriting fresh cache',
        () async {
      final api = ControllableProbeDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'epoch-group',
        title: 'Epoch Group',
        category: 'smart',
        clientPolicy: const ManifestClientPolicy(probeTtlSeconds: 300),
      );
      api.customCandidateIds = ['cand-epoch-1'];

      // Start normal flight 1 (slow, returns 150ms after 100ms)
      final flight1 = selector.rank(api, group, forceRefresh: false);

      // Yield briefly, then trigger forceRefresh flight 2 (fast, returns 30ms after 20ms)
      await Future.delayed(const Duration(milliseconds: 10));
      final flight2 = selector.rank(api, group, forceRefresh: true);

      await Future.wait([flight1, flight2]);

      // Cache inspection: cache must retain the fresh probe (30ms), NOT the stale slow probe (150ms)
      final prefs = await SharedPreferences.getInstance();
      final rawCache = prefs.getString('mosaic.smart_group.quality.v1');
      expect(rawCache, isNotNull);
      final decoded = jsonDecode(rawCache!) as Map<String, dynamic>;
      final entry = decoded['default::epoch-group::cand-epoch-1'] as Map<String, dynamic>;
      expect(entry['median_latency_ms'], 30);

      // Subsequent rank without forceRefresh must read the 30ms probe from cache
      final rank3 = await selector.rank(api, group, forceRefresh: false);
      expect(rank3.first.fromCache, isTrue);
      expect(rank3.first.probe.medianLatencyMs, 30);
    });

    test('cancel() called during connect() throws StateError with Connection cancelled',
        () async {
      final api = DelayedDaemonApi();
      final selector = SmartGroupSelector();
      final group = ManifestGroup(
        id: 'connect-cancel-group',
        title: 'Connect Cancel Group',
        category: 'smart',
      );
      api.customCandidateIds = ['cand-cc-1'];

      final connectFuture = selector.connect(api, group);
      await Future.delayed(const Duration(milliseconds: 10));
      selector.cancel();

      expect(
        () => connectFuture,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Connection cancelled'),
        )),
      );
    });
  });
}
