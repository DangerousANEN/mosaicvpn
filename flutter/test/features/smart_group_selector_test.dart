import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/services/smart_group_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
}
