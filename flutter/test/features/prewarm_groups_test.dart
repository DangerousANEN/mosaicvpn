import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/daemon_api_base.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/services/smart_group_runtime_controller.dart';
import 'package:mosaic_vpn/core/services/smart_group_selector.dart';

/// Prewarm contract:
///  1. Throttled to one pass per 15 minutes (second immediate call is a no-op)
///  2. `force: true` bypasses the throttle
///  3. Raw / disabled groups are never probed
void main() {
  test('prewarm is throttled and force bypasses it', () async {
    final controller = SmartGroupRuntimeController.instance;
    controller.debugResetPrewarmThrottle();
    final rankedGroupIds = <String>[];

    ManifestGroup group(String id, {String category = 'smart', bool disabled = false}) =>
        ManifestGroup(id: id, title: id, category: category, disabled: disabled);

    final groups = <ManifestGroup>[
      group('g1'),
      group('g2'),
      // Must be skipped:
      group('raw1', category: 'raw'),
      group('off', disabled: true),
    ];

    Future<void> prewarm({bool force = false}) => controller.prewarmGroups(
          api: _StubApi(),
          selector: _RecordingSelector(onRank: rankedGroupIds.add),
          groups: groups,
          force: force,
        );

    // First pass: ranks each non-raw, non-disabled group exactly once.
    await prewarm();
    expect(rankedGroupIds, ['g1', 'g2']);

    // Second immediate call: throttled — no additional probe rounds.
    await prewarm();
    expect(rankedGroupIds, ['g1', 'g2'],
        reason: 'repeat within 15 min must not re-rank');

    // Force bypasses the throttle.
    await prewarm(force: true);
    expect(rankedGroupIds, ['g1', 'g2', 'g1', 'g2']);
  });
}

class _StubApi implements DaemonApiBase {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSelector extends SmartGroupSelector {
  final void Function(String groupId) onRank;
  _RecordingSelector({required this.onRank});

  @override
  Future<List<SmartGroupSelection>> rank(
    DaemonApiBase api,
    ManifestGroup group, {
    bool measureSpeed = false,
    String? networkScope,
    bool forceRefresh = false,
    String? activeCandidateId,
    bool Function()? isCancelled,
  }) async {
    onRank(group.id);
    return const <SmartGroupSelection>[];
  }
}
