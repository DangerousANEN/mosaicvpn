import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/billing_provider.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/provider_profile/provider_profile_screen.dart';

/// The provider profile screen used to render only the provider manifest, so it
/// showed provider-offered billing information regardless of what the user
/// actually had. These tests pin the corrected behaviour: the user's real
/// account state is rendered from billingProfileProvider, and the states that
/// previously produced nonsense (no linked account, unlimited traffic) must
/// stay correct.
///
/// Both async providers the screen watches are overridden so nothing reaches
/// the real HTTP client: its retry/poll timers outlive the widget tree and
/// trip the test binding's pending-timer assertion on teardown.
///
/// The manifest must carry a non-null profile, otherwise the screen short
/// circuits with "No provider profile in manifest" and the account card --
/// the thing under test -- never builds.
Widget _harness(BillingProfile profile) {
  final manifest = ProviderManifest(
    providerName: 'Test Provider',
    profile: ProviderProfile(branding: ProviderBranding()),
  );
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(MockDaemonApi()),
      billingProfileProvider.overrideWith((ref) async => profile),
      providerManifestProvider.overrideWith((ref) async => manifest),
    ],
    child: const MaterialApp(home: ProviderProfileScreen()),
  );
}

void main() {
  group('ProviderManifest direct routes', () {
    test('parses direct_routes separately and exposes all virtual routes', () {
      final manifest = ProviderManifest.fromJson(const {
        'provider_name': 'Test Provider',
        'groups': [
          {'id': 'smart', 'title': 'Smart', 'route_type': 'smart_group'},
        ],
        'direct_routes': [
          {
            'id': 'direct-de',
            'title': 'Direct Germany',
            'route_type': 'direct',
            'type': 'direct_node',
            'country_code': 'DE',
            'protocol': 'vless',
          },
        ],
      });

      expect(manifest.groups, hasLength(1));
      expect(manifest.directRoutes, hasLength(1));
      expect(manifest.routes.map((route) => route.id), ['smart', 'direct-de']);
      final direct = manifest.directRoutes.single;
      expect(direct.routeType, 'direct');
      expect(direct.type, 'direct_node');
      expect(direct.countryCode, 'DE');
      expect(direct.protocol, 'vless');
      expect(direct.nodes, isEmpty);
    });
  });

  group('ProviderProfileScreen account state', () {
    testWidgets('unlinked account shows no tariff or traffic figures',
        (tester) async {
      await tester.pumpWidget(_harness(BillingProfile(linked: false)));
      await tester.pumpAndSettle();

      expect(find.text('No account linked'), findsOneWidget);

      // The bug being guarded against: rendering subscription numbers for a
      // user who has no subscription at all.
      expect(find.textContaining('Days Left'), findsNothing);
      expect(find.textContaining('Traffic Used'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('linked account renders username and traffic', (tester) async {
      await tester.pumpWidget(_harness(BillingProfile(
        linked: true,
        username: 'tg_8749413277',
        status: 'active',
        trafficLimitBytes: 10737418240, // 10 GiB
        usedTrafficBytes: 1073741824, //  1 GiB
        daysLeft: 15,
      )));
      await tester.pumpAndSettle();

      expect(find.text('tg_8749413277'), findsOneWidget);
      expect(find.text('Traffic Used'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
    });

    testWidgets('zero traffic limit means unlimited, not a divide by zero',
        (tester) async {
      await tester.pumpWidget(_harness(BillingProfile(
        linked: true,
        username: 'unlimited_user',
        status: 'active',
        trafficLimitBytes: 0,
        usedTrafficBytes: 5368709120,
        daysLeft: 30,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('Unlimited'), findsOneWidget);
      // A 0-byte limit must not produce a NaN/Infinity progress bar.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expired subscription still renders without throwing',
        (tester) async {
      await tester.pumpWidget(_harness(BillingProfile(
        linked: true,
        username: 'expired_user',
        status: 'expired',
        trafficLimitBytes: 10737418240,
        usedTrafficBytes: 10737418240, // fully consumed
        daysLeft: 0,
      )));
      await tester.pumpAndSettle();

      expect(find.text('expired_user'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('usage above the limit clamps instead of overflowing',
        (tester) async {
      await tester.pumpWidget(_harness(BillingProfile(
        linked: true,
        username: 'over_user',
        status: 'active',
        trafficLimitBytes: 1073741824,
        usedTrafficBytes: 3221225472, // 300% of the limit
        daysLeft: 5,
      )));
      await tester.pumpAndSettle();

      final bars = tester.widgetList<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      for (final bar in bars) {
        final value = bar.value;
        if (value != null) {
          expect(value, lessThanOrEqualTo(1.0));
          expect(value, greaterThanOrEqualTo(0.0));
        }
      }
      expect(tester.takeException(), isNull);
    });
  });
}
