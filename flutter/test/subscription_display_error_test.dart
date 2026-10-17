import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/subscription.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';

void main() {
  for (final hasCache in [true, false]) {
    test('daemon failure uses ${hasCache ? 'cached routes' : 'empty fallback'} without throwing', () async {
      final scope = ProviderContainer(overrides: [
        subscriptionsProvider.overrideWith((ref) async => throw StateError('daemon unavailable')),
        cachedSubscriptionsProvider.overrideWith((ref) async => hasCache
            ? [Subscription(id: 'saved', name: 'Saved route')]
            : throw StateError('cache unavailable')),
      ]);
      addTearDown(scope.dispose);
      final subscription = scope.listen(subscriptionsForDisplayProvider,
          (_, __) {}, onError: (_, __) {});
      addTearDown(subscription.close);
      await scope.read(subscriptionsProvider.future).catchError((_) => <Subscription>[]);
      await scope.read(cachedSubscriptionsProvider.future).catchError((_) => <Subscription>[]);
      await Future<void>.delayed(Duration.zero);
      final displayed = scope.read(subscriptionsForDisplayProvider);
      expect(displayed.map((s) => s.id), hasCache ? ['saved'] : isEmpty);
    });
  }

  test('a successful empty live response does not resurrect deleted cached routes', () async {
    final scope = ProviderContainer(overrides: [
      subscriptionsProvider.overrideWith((ref) async => <Subscription>[]),
      cachedSubscriptionsProvider.overrideWith((ref) async => [Subscription(id: 'deleted')]),
    ]);
    addTearDown(scope.dispose);
    final subscription = scope.listen(subscriptionsForDisplayProvider, (_, __) {});
    addTearDown(subscription.close);
    await scope.read(subscriptionsProvider.future);
    await scope.read(cachedSubscriptionsProvider.future);
    expect(scope.read(subscriptionsForDisplayProvider), isEmpty);
  });
}
