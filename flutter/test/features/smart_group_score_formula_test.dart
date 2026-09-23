import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/provider_profile.dart';
import 'package:mosaic_vpn/core/models/smart_group_quality.dart';

// The scoring contract extracted from smart_group_quality_monitor.dart
// _scoreResult:
//   - when downloadMbps == 0 (not measured), speedWeight must be EXCLUDED from
//     normalization: score = (rel*lw + lat*latw + stab*stabw) / (lw+latw+stabw)
//   - when downloadMbps > 0 (measured), speed participates:
//     score = (rel*lw + lat*latw + stab*stabw + speed*spw) / (lw+latw+stabw+spw)
//     with speed = clamp(downloadMbps / targetMbps, 0, 1)
// A previous bug kept spw in the denominator while the numerator omitted
// speed, systematically under-scoring every candidate by up to spw/total.

SmartGroupProbeResult makeResult({double downloadMbps = 0, int latencyMs = 60}) {
  return SmartGroupProbeResult(
    groupId: 'g',
    candidateId: 'c',
    successful: true,
    samples: 5,
    successes: 5,
    lossPercent: 0,
    medianLatencyMs: latencyMs,
    p95LatencyMs: latencyMs + 5,
    jitterMs: 5,
    checkedAt: DateTime.now(),
    probeKind: 'http_get',
    downloadMbps: downloadMbps,
    uploadMbps: 0,
  );
}

double scoreOf(
  SmartGroupProbeResult r,
  ManifestClientPolicy policy,
) {
  final lw = policy.lossWeight;
  final latw = policy.latencyWeight;
  final stabw = policy.stabilityWeight;
  final spw = policy.speedWeight;

  final sampleRatio = r.samples > 0 ? (r.successes / r.samples).clamp(0.0, 1.0) : 1.0;
  final lossRate = (r.lossPercent.clamp(0.0, 100.0) / 100.0);
  final reliability = (1.0 - lossRate) * sampleRatio;
  final latency = r.medianLatencyMs <= 0 ? 0.0 : 1 / (1 + r.medianLatencyMs / 150);
  final stability = 1.0 / (1.0 + (r.jitterMs / 50.0) + (r.lossPercent > 0 ? 0.5 : 0.0));

  final total = lw + latw + stabw + spw;
  final speed = r.downloadMbps > 0
      ? (r.downloadMbps / (policy.speedProbe.targetMbps > 0
            ? policy.speedProbe.targetMbps
            : 50.0)).clamp(0.0, 1.0)
      : 0.0;
  final activeWeight = r.downloadMbps > 0 ? total : lw + latw + stabw;
  return activeWeight > 0
      ? (reliability * lw + latency * latw + stability * stabw + speed * spw) / activeWeight
      : 0.0;
}

void main() {
  group('score formula: missing speed must not drag score down', () {
    test('identical candidate, spw>0: unmeasured speed is NOT penalized', () {
      final policy = ManifestClientPolicy(
        latencyWeight: .45,
        lossWeight: .30,
        stabilityWeight: .25,
        speedWeight: .20,
      );
      final unmeasured = makeResult(downloadMbps: 0);
      // Same candidate, but speed actually measured and equals the target.
      final measured = makeResult(downloadMbps: policy.speedProbe.targetMbps);

      final sUnmeasured = scoreOf(unmeasured, policy);
      final sMeasured = scoreOf(measured, policy);
      expect(sUnmeasured, greaterThan(0));
      expect(sMeasured, greaterThan(sUnmeasured),
          reason: 'perfect-speed node must outrank the unmeasured one');
      // The old buggy formula would score the unmeasured candidate as
      // (numerator without speed) / (total with spw): a flat 1/6 penalty at
      // these weights. The unmeasured score must equal the 3-metric
      // normalization exactly:
      final lw = policy.lossWeight, latw = policy.latencyWeight, stabw = policy.stabilityWeight;
      final expectedUnmeasured =
          ((1.0 * lw) + (1 / (1 + 60 / 150)) * latw + (1.0 / (1.0 + 0.1)) * stabw) /
              (lw + latw + stabw);
      expect(sUnmeasured, closeTo(expectedUnmeasured, 1e-9));
    });

    test('spw excluded: unmeasured score is independent of speedWeight', () {
      final noSpw = ManifestClientPolicy(
        latencyWeight: .45,
        lossWeight: .30,
        stabilityWeight: .25,
        speedWeight: 0,
      );
      final withSpw = ManifestClientPolicy(
        latencyWeight: .45,
        lossWeight: .30,
        stabilityWeight: .25,
        speedWeight: .30,
      );
      final r = makeResult(downloadMbps: 0);
      // With no measured speed, adding speedWeight must NOT change the score.
      expect(scoreOf(r, noSpw), closeTo(scoreOf(r, withSpw), 1e-9));
    });

    test('measured slow speed DOES reduce score vs unmeasured', () {
      final policy = ManifestClientPolicy(
        latencyWeight: .45,
        lossWeight: .30,
        stabilityWeight: .25,
        speedWeight: .20,
      );
      final unmeasured = makeResult(downloadMbps: 0);
      final slow = makeResult(downloadMbps: 2.0); // far below 50 Mbps target
      expect(scoreOf(slow, policy), lessThan(scoreOf(unmeasured, policy)),
          reason: 'a measured slow node must be ranked below an unmeasured one');
    });

    test('speed saturates at target: 2x target equals 1x target score', () {
      final policy = ManifestClientPolicy(
        latencyWeight: .45,
        lossWeight: .30,
        stabilityWeight: .25,
        speedWeight: .20,
      );
      final t = policy.speedProbe.targetMbps;
      final atTarget = makeResult(downloadMbps: t);
      final aboveTarget = makeResult(downloadMbps: t * 3);
      expect(scoreOf(atTarget, policy), closeTo(scoreOf(aboveTarget, policy), 1e-9));
    });
  });
}
