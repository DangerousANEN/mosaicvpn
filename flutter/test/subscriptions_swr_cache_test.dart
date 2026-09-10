import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/subscription.dart';
import 'package:mosaic_vpn/core/services/ui_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the stale-while-revalidate subscription snapshot.
///
/// Before this cache, `subscriptionsProvider` was a bare
/// `FutureProvider.autoDispose` with no cross-session storage: every cold start
/// rendered an empty cabinet until the daemon answered, which users read as
/// "my subscription vanished".
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('cache round-trips a subscription list through JSON', () async {
    final service = UiPreferencesService();
    final original = [
      Subscription(
        id: 'sub-1',
        name: 'Mosaic Direct',
        url: 'https://sub.zxc1x1.ru/reftcT_frzSCwhav',
        serverCount: 7,
        source: 'provider',
        providerId: 'mosaic',
      ),
      Subscription(id: 'sub-2', name: 'Backup', url: 'https://example.org/s'),
    ];

    await service.writeSubscriptionsCache(
      original.map((entry) => entry.toJson()).toList(),
    );

    final restored = (await service.readSubscriptionsCache())
        .map(Subscription.fromJson)
        .toList();

    expect(restored.length, 2);
    expect(restored[0].id, 'sub-1');
    expect(restored[0].name, 'Mosaic Direct');
    expect(restored[0].url, 'https://sub.zxc1x1.ru/reftcT_frzSCwhav');
    expect(restored[0].serverCount, 7);
    expect(restored[0].isProviderSource, isTrue);
    expect(restored[1].id, 'sub-2');
  });

  test('empty cache returns an empty list rather than throwing', () async {
    final service = UiPreferencesService();
    expect(await service.readSubscriptionsCache(), isEmpty);
  });

  test('corrupt cache self-heals instead of blocking startup', () async {
    SharedPreferences.setMockInitialValues({
      'ui.subscriptions_cache_v1': '{not-valid-json',
    });
    final service = UiPreferencesService();

    expect(await service.readSubscriptionsCache(), isEmpty);
    // The poisoned entry must be dropped so it cannot fail again next boot.
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('ui.subscriptions_cache_v1'), isNull);
  });

  test('a JSON object (not a list) is rejected safely', () async {
    SharedPreferences.setMockInitialValues({
      'ui.subscriptions_cache_v1': jsonEncode({'id': 'nope'}),
    });
    expect(await UiPreferencesService().readSubscriptionsCache(), isEmpty);
  });

  test('clearing the cache removes the snapshot', () async {
    final service = UiPreferencesService();
    await service.writeSubscriptionsCache([
      Subscription(id: 'sub-1', name: 'X', url: 'https://x').toJson(),
    ]);
    expect(await service.readSubscriptionsCache(), isNotEmpty);

    await service.clearSubscriptionsCache();
    expect(await service.readSubscriptionsCache(), isEmpty);
  });

  test('cached subscription URLs keep trailing-dot sanitisation', () async {
    // Telegram copy-paste often appends a trailing dot; fromJson strips it.
    final service = UiPreferencesService();
    await service.writeSubscriptionsCache([
      {'id': 'sub-1', 'name': 'Dotted', 'url': 'https://sub.zxc1x1.ru/tok.'},
    ]);

    final restored = (await service.readSubscriptionsCache())
        .map(Subscription.fromJson)
        .toList();
    expect(restored.single.url, 'https://sub.zxc1x1.ru/tok');
  });
}
