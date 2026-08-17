class SmartGroupCandidateShard {
  final String groupId;
  final String version;
  final DateTime expiresAt;
  final List<String> candidateIds;

  const SmartGroupCandidateShard({
    required this.groupId,
    required this.version,
    required this.expiresAt,
    required this.candidateIds,
  });

  factory SmartGroupCandidateShard.fromJson(Map<String, dynamic> json) {
    return SmartGroupCandidateShard(
      groupId: json['group_id']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      candidateIds: (json['candidate_ids'] as List? ?? const [])
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
    );
  }
}

class SmartGroupProbeResult {
  final String groupId;
  final String candidateId;
  final bool successful;
  final int samples;
  final int successes;
  final double lossPercent;
  final int medianLatencyMs;
  final int p95LatencyMs;
  final int jitterMs;
  final DateTime checkedAt;
  final String probeKind;

  const SmartGroupProbeResult({
    required this.groupId,
    required this.candidateId,
    required this.successful,
    required this.samples,
    required this.successes,
    required this.lossPercent,
    required this.medianLatencyMs,
    required this.p95LatencyMs,
    required this.jitterMs,
    required this.checkedAt,
    required this.probeKind,
  });

  factory SmartGroupProbeResult.fromJson(Map<String, dynamic> json) {
    return SmartGroupProbeResult(
      groupId: json['group_id']?.toString() ?? '',
      candidateId: json['candidate_id']?.toString() ?? '',
      successful: json['successful'] == true,
      samples: (json['samples'] as num?)?.toInt() ?? 0,
      successes: (json['successes'] as num?)?.toInt() ?? 0,
      lossPercent: (json['loss_percent'] as num?)?.toDouble() ?? 100,
      medianLatencyMs: (json['median_latency_ms'] as num?)?.toInt() ?? 0,
      p95LatencyMs: (json['p95_latency_ms'] as num?)?.toInt() ?? 0,
      jitterMs: (json['jitter_ms'] as num?)?.toInt() ?? 0,
      checkedAt: DateTime.tryParse(json['checked_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      probeKind: json['probe_kind']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'group_id': groupId,
        'candidate_id': candidateId,
        'successful': successful,
        'samples': samples,
        'successes': successes,
        'loss_percent': lossPercent,
        'median_latency_ms': medianLatencyMs,
        'p95_latency_ms': p95LatencyMs,
        'jitter_ms': jitterMs,
        'checked_at': checkedAt.toIso8601String(),
        'probe_kind': probeKind,
      };

  /// Higher is better. Failed probes are always ranked behind successful ones.
  double get qualityScore {
    if (!successful) return -lossPercent;
    final reliability = 1 - (lossPercent.clamp(0, 100) / 100);
    final latency = medianLatencyMs <= 0 ? 0 : 1 / (1 + medianLatencyMs / 150);
    final stability = 1 / (1 + jitterMs / 100);
    return reliability * 0.55 + latency * 0.30 + stability * 0.15;
  }
}
