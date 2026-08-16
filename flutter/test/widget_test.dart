import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/app/app_shell.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';

/// Smoke tests for the shell that owns navigation.
///
/// The daemon API is mocked and vpnStatusProvider is replaced with a single
/// value: the real provider polls on a periodic Timer that outlives the widget
/// tree and trips the binding's pending-timer assertion on teardown, while an
/// unmocked HttpClient makes the suite emit network warnings.
Widget _harness({Locale locale = const Locale('ru')}) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(MockDaemonApi()),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: [Locale('en'), Locale('ru')],
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: AppShell(),
      ),
    );

/// Sets a targeted device surface and lets the tree build.
///
/// The connection dashboard intentionally has a repeating route animation, so
/// pumpAndSettle would never complete. The mock manifest resolves after 200 ms;
/// a bounded sequence of pumps lets chained delayed mock requests from every
/// cached tab finish without waiting for the animation.
Future<void> _pumpAt(WidgetTester tester, Size size,
    {Locale locale = const Locale('ru')}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_harness(locale: locale));
  for (var step = 0; step < 8; step++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pump();
}

void main() {
  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
  });

  testWidgets('phone shell exposes four clear primary tabs', (tester) async {
    await _pumpAt(tester, const Size(390, 844));

    // Four primary tasks keep first use calm; technical controls live in «Ещё».
    final bar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(bar.items.length, 4);

    for (final label in ['Подключение', 'Маршруты', 'Аккаунт', 'Ещё']) {
      expect(find.text(label), findsWidgets, reason: 'missing tab: $label');
    }
    expect(tester.takeException(), isNull,
        reason: 'phone navigation must build without a framework exception');
  });

  testWidgets('phone shell lays out without overflow on a small screen',
      (tester) async {
    await _pumpAt(tester, const Size(360, 640));

    expect(tester.takeException(), isNull,
        reason: '360x640 is a real device size and must lay out clean');
  });

  testWidgets('desktop shell starts on the connection dashboard',
      (tester) async {
    await _pumpAt(tester, const Size(1440, 960));

    expect(find.byType(BottomNavigationBar), findsNothing,
        reason: 'wide layout uses the compact sidebar');
    expect(find.text('Не подключено'), findsWidgets,
        reason: 'the primary desktop screen must be ConnectionDashboard');
    expect(find.textContaining('Маршруты: Минимальный пинг'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'desktop dashboard must render without an exception');
  });

  testWidgets('dashboard localizes its primary connection flow in English',
      (tester) async {
    await _pumpAt(tester, const Size(1440, 960), locale: const Locale('en'));

    expect(find.text('Not connected'), findsWidgets);
    expect(find.textContaining('Routes: Minimum ping'), findsOneWidget);
    expect(find.text('Subscriptions'), findsWidgets);
    expect(tester.takeException(), isNull,
        reason: 'English dashboard must render without a framework exception');
  });
}
