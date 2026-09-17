import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/android_hosted_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/services/smart_group_latency_test.dart';
import 'package:mosaic_vpn/core/services/smart_group_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Smart Group Health & Unverified Candidates', () {
    test('SmartGroupProbeResult.unverified defaults to zero samples and unverified status', () {
      final probe = SmartGroupProbeResult.unverified(
        groupId: 'test-group',
        candidateId: 'test-cand',
      );

      expect(probe.isUnverified, isTrue);
      expect(probe.samples, 0);
      expect(probe.successes, 0);
      expect(probe.lossPercent, 0);
      expect(probe.medianLatencyMs, 0);
      expect(probe.probeKind, 'unverified_android_candidate');
      expect(probe.qualityScore(), double.negativeInfinity);
    });

    test('Zero-sample probes are identified as isUnverified regardless of probeKind', () {
      final probe = SmartGroupProbeResult(
        groupId: 'test-group',
        candidateId: 'test-cand',
        successful: false,
        samples: 0,
        successes: 0,
        lossPercent: 0,
        medianLatencyMs: 0,
        p95LatencyMs: 0,
        jitterMs: 0,
        checkedAt: DateTime.now().toUtc(),
        probeKind: 'unsupported_probe',
      );

      expect(probe.isUnverified, isTrue);
      expect(SmartGroupSelector.formatMeasurement(probe), 'Не проверен');
    });

    test('SmartGroupSelector.formatMeasurement formats unverified as "Не проверен", failed as "Недоступен"', () {
      final unverified = SmartGroupProbeResult.unverified(
        groupId: 'g1',
        candidateId: 'c1',
      );
      expect(SmartGroupSelector.formatMeasurement(unverified), 'Не проверен');

      final failedProbe = SmartGroupProbeResult(
        groupId: 'g1',
        candidateId: 'c2',
        successful: false,
        samples: 3,
        successes: 0,
        lossPercent: 100,
        medianLatencyMs: 0,
        p95LatencyMs: 0,
        jitterMs: 0,
        checkedAt: DateTime.now().toUtc(),
        probeKind: 'transport_error',
      );
      expect(SmartGroupSelector.formatMeasurement(failedProbe), 'Недоступен');

      final healthyProbe = SmartGroupProbeResult(
        groupId: 'g1',
        candidateId: 'c3',
        successful: true,
        samples: 3,
        successes: 3,
        lossPercent: 0,
        medianLatencyMs: 45,
        p95LatencyMs: 50,
        jitterMs: 4,
        checkedAt: DateTime.now().toUtc(),
        probeKind: 'tcp-connect',
      );
      expect(SmartGroupSelector.formatMeasurement(healthyProbe), '45 ms · ±4 ms');
    });

    test('TestResult.failed excludes unverified states', () {
      final unverifiedResult = TestResult(
        serverID: 'group-1',
        serverName: 'Smart Route',
        latencyMS: -1,
        error: 'unverified',
        testedAt: DateTime.now(),
      );

      expect(unverifiedResult.isUnverified, isTrue);
      expect(unverifiedResult.failed, isFalse);

      final deadResult = TestResult(
        serverID: 'group-2',
        serverName: 'Broken Route',
        latencyMS: -1,
        error: 'timeout',
        testedAt: DateTime.now(),
      );

      expect(deadResult.isUnverified, isFalse);
      expect(deadResult.failed, isTrue);
    });

    test('AndroidHostedDaemonApi candidate probe fails closed as unverified without network traffic', () async {
      final result = await AndroidHostedDaemonApi.instance.probeGroupCandidate(
        'smart-group-1',
        'cand-1',
      );

      expect(result.successful, isFalse);
      expect(result.samples, 0);
      expect(result.isUnverified, isTrue);
      expect(result.probeKind, 'unverified_android_candidate');
      expect(SmartGroupSelector.formatMeasurement(result), 'Не проверен');
    });

    test('SmartGroupLatencyProgress marks aggregate as unverified when all probes are zero-sample/unverified', () {
      final progress = SmartGroupLatencyProgress(
        groupId: 'g1',
        completed: 3,
        total: 3,
        successful: 0,
        lossPercent: null,
        cancelled: false,
        unverified: true,
      );

      expect(progress.unverified, isTrue);
      expect(progress.lossPercent, isNull);
    });
  });
}
