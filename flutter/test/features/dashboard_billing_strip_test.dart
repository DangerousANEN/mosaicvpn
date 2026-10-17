import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/billing_provider.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/dashboard/connection_dashboard.dart';

/// The access strip above the dial is the only place a user learns about their
/// access state without opening the cabinet. It must distinguish three
/// situations that used to look identical:
///  * a real expiry (blocking, "пополнить"),
///  * last-known data from an offline fallback (not blocking, honest wording),
///  * a healthy account (no strip at all).
///
/// The strip only renders once the dashboard has a route to show, so the tests
/// supply a local subscription with one server instead of letting the empty
/// state fall through to the onboarding card.
const _subId = 'local-default';

Widget _dashboard(BillingProfile profile) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
        billingProfileProvider.overrideWith((ref) async => profile),
        subscriptionsForDisplayProvider.overrideWithValue([
          Subscription(
            id: _subId,
            name: 'Локальные профили',
            url: '',
            serverCount: 1,
          ),
        ]),
        serversProvider.overrideWith((ref) async => [
              Server(
                id: 'server-1',
                name: 'Amsterdam',
                protocol: Protocol.vless,
                subscriptionID: _subId,
                importUri:
                    'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@198.51.100.22:443?encryption=none#AMS',
              ),
            ]),
      ],
      child: const MaterialApp(home: Scaffold(body: ConnectionDashboard())),
    );

Future<void> _pump(WidgetTester tester, BillingProfile profile) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_dashboard(profile));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('an expired account shows the blocking renewal strip',
      (tester) async {
    await _pump(
        tester,
        BillingProfile(
            linked: true, status: 'insufficient_funds', daysLeft: 0));

    expect(find.text('Доступ закончился'), findsOneWidget);
    expect(find.text('Пополнить'), findsWidgets);
  });

  testWidgets('an offline fallback says the data is last-known, not expired',
      (tester) async {
    await _pump(
        tester,
        BillingProfile(
            linked: true, status: 'unknown', daysLeft: 0, stale: true));

    expect(find.text('Доступ закончился'), findsNothing,
        reason: 'a network hiccup must not claim the access ended');
    expect(find.textContaining('Данные обновятся'), findsOneWidget);
  });

  testWidgets('last-known data keeps its real remaining days visible',
      (tester) async {
    await _pump(
        tester,
        BillingProfile(
            linked: true, status: 'active', daysLeft: 9, stale: true));

    expect(find.textContaining('Последние данные: 9 дн.'), findsOneWidget);
    expect(find.text('Доступ закончился'), findsNothing);
  });

  testWidgets('a healthy account shows no access strip at all',
      (tester) async {
    await _pump(
        tester,
        BillingProfile(linked: true, status: 'active', daysLeft: 20));

    expect(find.text('Доступ закончился'), findsNothing);
    expect(find.textContaining('Последние данные'), findsNothing);
    expect(find.textContaining('Осталось'), findsNothing);
  });
}