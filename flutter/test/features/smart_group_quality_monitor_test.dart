import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/daemon_api_base.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/services/smart_group_quality_monitor.dart';
import 'package:mosaic_vpn/core/services/smart_group_selector.dart';

class FakeDaemonApi implements DaemonApiBase {
  bool connected = true;
  String activeGroup = 'group-a';
  List<String> shardCandidateIds = ['cand-1', 'cand-2'];
  Map<String, SmartGroupProbeResult> probes = {};

  @override
  Future<VpnStatus> getStatus() async {
    return VpnStatus(
      agentConnected: true,
      state: connected ? 'connected' : 'disconnected',
      tunnelMode: 'tun',
      activeGroupId: activeGroup,
      server: null,
      lastError: '',
    );
  }

  @override
  Future<SmartGroupCandidateShard> getCandidateShard(
      String groupID, String installationID) async {
    return SmartGroupCandidateShard(
      groupId: groupID,
      version: 'v1',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      candidateIds: shardCandidateIds,
    );
  }

  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
    String groupID,
    String candidateID, {
    String? probeMode,
    int? probeSamples,
    String? probeUrl,
  }) async {
    if (probes.containsKey(candidateID)) {
      return probes[candidateID]!;
    }
    return SmartGroupProbeResult(
      groupId: groupID,
      candidateId: candidateID,
      successful: true,
      samples: 3,
      successes: 3,
      lossPercent: 0,
      medianLatencyMs: 50,
      p95LatencyMs: 60,
      jitterMs: 5,
      checkedAt: DateTime.now(),
      probeKind: 'transport_tcp',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSelector implements SmartGroupSelector {
  @override
  Future<String> installationID() async => 'test-install-id';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SmartGroupQualityMonitor', () {
    late FakeDaemonApi api;
    late FakeSelector selector;
    late ManifestGroup testGroup;

    setUp(() {
      api = FakeDaemonApi();
      selector = FakeSelector();
      testGroup = ManifestGroup(
        id: 'group-a',
        title: 'Group A',
        countryCode: 'de',
        poolId: 'pool-de',
        routeType: 'smart_group',
        clientPolicy: const ManifestClientPolicy(
          maxFailoverTries: 2,
          probeTtlSeconds: 300,
          latencyWeight: 0.5,
          lossWeight: 0.3,
          stabilityWeight: 0.2,
        ),
      );
    });

    test('lifecycle: start, stop and dispose cleanly manage running state', () {
      final monitor = SmartGroupQualityMonitor(
        api: api,
        selector: selector,
        config: const MonitorConfig(probeInterval: Duration(milliseconds: 50)),
      );

      expect(monitor.isRunning, isFalse);
      monitor.start(group: testGroup, activeCandidateId: 'cand-1');
      expect(monitor.isRunning, isTrue);

      monitor.stop();
      expect(monitor.isRunning, isFalse);

      monitor.dispose();
      expect(monitor.isRunning, isFalse);
      expect(() => monitor.start(group: testGroup, activeCandidateId: 'cand-1'),
          throwsStateError);
    });

    test('re-entrant start invalidates previous generation timer', () async {
      final monitor = SmartGroupQualityMonitor(
        api: api,
        selector: selector,
        config: const MonitorConfig(probeInterval: Duration(milliseconds: 30)),
      );

      monitor.start(group: testGroup, activeCandidateId: 'cand-1');
      // Rapid re-start
      monitor.start(group: testGroup, activeCandidateId: 'cand-2');
      expect(monitor.isRunning, isTrue);

      monitor.stop();
      expect(monitor.isRunning, isFalse);
    });

    test('handles failover rollback when onSwitchCandidate throws', () async {
      final monitor = SmartGroupQualityMonitor(
        api: api,
        selector: selector,
        config: const MonitorConfig(
          probeInterval: Duration(milliseconds: 20),
          degradationWindowCount: 1,
          failoverCooldown: Duration.zero,
          minMaterialImprovement: 0.1,
        ),
      );

      // cand-1 degraded (high latency)
      api.probes['cand-1'] = SmartGroupProbeResult(
        groupId: 'group-a',
        candidateId: 'cand-1',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 500, // exceeds maxLatencyThresholdMs (400)
        p95LatencyMs: 600,
        jitterMs: 10,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );

      // cand-2 is healthy
      api.probes['cand-2'] = SmartGroupProbeResult(
        groupId: 'group-a',
        candidateId: 'cand-2',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 40,
        p95LatencyMs: 50,
        jitterMs: 2,
        checkedAt: DateTime.now(),
        probeKind: 'transport_tcp',
      );

      FailoverEvent? lastEvent;
      monitor.onFailoverEvent = (event) => lastEvent = event;

      // Switcher fails
      monitor.onSwitchCandidate = (gid, cid) async {
        throw Exception('network error during candidate switch');
      };

      monitor.start(group: testGroup, activeCandidateId: 'cand-1');

      // Wait for evaluation window
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(lastEvent, isNotNull);
      expect(lastEvent!.switched, isFalse);
      expect(lastEvent!.fromCandidateId, 'cand-1');
      expect(lastEvent!.activeScore, isNotNull);

      monitor.stop();
    });
  });
}
