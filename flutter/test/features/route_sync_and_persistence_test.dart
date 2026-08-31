import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/services/ui_preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Route Synchronization & Persistence Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Selected subscription and route providers sync and persist values',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final uiPrefs = UiPreferencesService();

      // Initial state is null
      expect(container.read(selectedSubscriptionIdProvider), isNull);
      expect(container.read(selectedRouteIdProvider), isNull);

      // Set subscription ID
      await container
          .read(selectedSubscriptionIdProvider.notifier)
          .set('sub-test-123');
      expect(container.read(selectedSubscriptionIdProvider), 'sub-test-123');

      // Verify persisted in SharedPreferences
      final savedSub = await uiPrefs.readSelectedSubscriptionId();
      expect(savedSub, 'sub-test-123');

      // Set route ID
      await container
          .read(selectedRouteIdProvider.notifier)
          .set('mosaic:sub-test-123:direct');
      expect(container.read(selectedRouteIdProvider),
          'mosaic:sub-test-123:direct');

      // Verify persisted in SharedPreferences
      final savedRoute = await uiPrefs.readSelectedRouteId();
      expect(savedRoute, 'mosaic:sub-test-123:direct');

      // Test last connected route persistence
      await uiPrefs.writeLastConnectedRouteId('mosaic:sub-test-123:direct');
      await uiPrefs.writeLastConnectedSubscriptionId('sub-test-123');

      expect(await uiPrefs.readLastConnectedRouteId(),
          'mosaic:sub-test-123:direct');
      expect(await uiPrefs.readLastConnectedSubscriptionId(), 'sub-test-123');
    });

    test('Selected subscription and route providers restore on fresh startup',
        () async {
      SharedPreferences.setMockInitialValues({
        'ui.selected_subscription_id': 'sub-saved-999',
        'ui.selected_route_id': 'min-latency',
        'ui.last_connected_route_id': 'min-latency',
        'ui.last_connected_subscription_id': 'sub-saved-999',
      });

      final container = ProviderContainer();
      // Access notifiers to start their initial async load
      container.read(selectedSubscriptionIdProvider.notifier);
      container.read(selectedRouteIdProvider.notifier);

      // Wait for async SharedPreferences load
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(selectedSubscriptionIdProvider), 'sub-saved-999');
      expect(container.read(selectedRouteIdProvider), 'min-latency');

      container.dispose();
    });
  });
}
