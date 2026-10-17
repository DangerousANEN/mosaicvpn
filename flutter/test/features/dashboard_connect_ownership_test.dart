import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:mosaic_vpn/core/providers/billing_provider.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/dashboard/connection_dashboard.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosaic_vpn/core/theme/atlas_theme.dart';

// Only the daemon boundary is controlled. Every tap runs the actual dashboard
// handler; completers deliver old responses in a deterministic order.
class ControlledConnectApi extends MockDaemonApi {
  final connects = <Completer<void>>[];
  final disconnects = <Completer<void>>[];
  bool holdDisconnect = false;

  @override
  Future<void> connect(String serverId) {
    final result = Completer<void>();
    connects.add(result);
    return result.future;
  }

  @override
  Future<void> disconnect() {
    final result = Completer<void>();
    disconnects.add(result);
    if (!holdDisconnect) result.complete();
    return result.future;
  }

  @override
  Future<VpnStatus> getStatus() async => VpnStatus(agentConnected: true);
}

Future<ProviderContainer> mountConnectDashboard(
    WidgetTester tester, ControlledConnectApi api,
    {Size size = const Size(1200, 900), ThemeData? theme}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(api),
      billingProfileProvider.overrideWith((ref) async => BillingProfile()),
      vpnStatusProvider.overrideWith(
          (ref) => Stream.value(VpnStatus(agentConnected: true))),
      subscriptionsForDisplayProvider.overrideWithValue([
        Subscription(id: 'local', name: 'Local', url: '', serverCount: 1),
      ]),
      serversProvider.overrideWith((ref) async => [
            Server(id: 'route-a', name: 'Amsterdam',
                protocol: Protocol.vless, subscriptionID: 'local'),
          ]),
    ],
    child: MaterialApp(theme: theme ?? AtlasTheme.themeData,
        debugShowCheckedModeBanner: false, home: const ConnectionDashboard()),
  ));
  await settleDashboard(tester);
  return ProviderScope.containerOf(
      tester.element(find.byType(ConnectionDashboard)));
}

Future<void> settleDashboard(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> tapConnectAction(WidgetTester tester) async {
  final button = find.byType(FilledButton).first;
  expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  await tester.tap(button);
  await settleDashboard(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  testWidgets('late completion cannot clear the new attempt or save cancelled route',
      (tester) async {
    final api = ControlledConnectApi();
    final scope = await mountConnectDashboard(tester, api);
    await tapConnectAction(tester); // connect A
    expect(api.connects, hasLength(1));
    expect(scope.read(connectingRouteProvider), 'route-a');
    await tapConnectAction(tester); // cancel A
    expect(api.disconnects, hasLength(1));
    await tapConnectAction(tester); // connect B
    expect(api.connects, hasLength(2));
    api.connects[0].complete(); // cancelled A returns late
    await settleDashboard(tester);
    expect(scope.read(connectingRouteProvider), 'route-a',
        reason: 'A must not end B in its finally block');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ui.last_connected_route_id'), isNull,
        reason: 'cancelled A must not persist a successful route');
    expect(find.text('Cancel connection'), findsOneWidget);
    api.connects[1].complete();
    await settleDashboard(tester);
    expect(scope.read(connectingRouteProvider), isNull);
    expect(prefs.getString('ui.last_connected_route_id'), 'route-a');
  });

  testWidgets('a new connect waits until pending disconnect finishes', (tester) async {
    final api = ControlledConnectApi()..holdDisconnect = true;
    await mountConnectDashboard(tester, api);
    await tapConnectAction(tester);
    await tapConnectAction(tester); // cancel, but teardown is still pending
    expect(api.disconnects, hasLength(1));
    await tapConnectAction(tester); // queue a retry
    expect(api.connects, hasLength(1),
        reason: 'new tunnel must not race old asynchronous teardown');
    api.disconnects.single.complete();
    await settleDashboard(tester);
    expect(api.connects, hasLength(2));
    api.connects[0].complete();
    api.connects[1].complete();
    await settleDashboard(tester);
  });

  testWidgets('failed teardown prevents queued restart until a successful stop', (tester) async {
    final api = ControlledConnectApi()..holdDisconnect = true;
    await mountConnectDashboard(tester, api);
    await tapConnectAction(tester);
    await tapConnectAction(tester);
    await tapConnectAction(tester);
    api.disconnects.single.completeError(TimeoutException('stop-timeout'));
    await settleDashboard(tester);
    expect(api.connects, hasLength(1));
    expect(find.textContaining('stop-timeout'), findsOneWidget);
    api.holdDisconnect = false;
    await tapConnectAction(tester);
    expect(api.disconnects, hasLength(2));
    expect(api.connects, hasLength(2));
    api.connects[0].complete();
    api.connects[1].complete();
    await settleDashboard(tester);
  });

  testWidgets('late failure from a cancelled attempt stays silent', (tester) async {
    final api = ControlledConnectApi();
    await mountConnectDashboard(tester, api);
    await tapConnectAction(tester);
    await tapConnectAction(tester);
    api.connects.single.completeError(StateError('old request network failure'));
    await settleDashboard(tester);
    expect(find.byType(SnackBar), findsNothing,
        reason: 'a stale network response is not a failure of the new intent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed dashboard never uses ref after connect completes', (tester) async {
    final api = ControlledConnectApi();
    await mountConnectDashboard(tester, api);
    await tapConnectAction(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    api.connects.single.complete();
    await settleDashboard(tester);
    expect(tester.takeException(), isNull);
    expect((await SharedPreferences.getInstance())
        .getString('ui.last_connected_route_id'), isNull);
  });

  testWidgets('phone compass can cancel a pending connection', (tester) async {
    final api = ControlledConnectApi();
    await mountConnectDashboard(tester, api, size: const Size(390, 844));
    final semantics = tester.ensureSemantics();
    try {
    await tester.tap(find.bySemanticsLabel('Подключить VPN'));
    await settleDashboard(tester);
    expect(api.connects, hasLength(1), reason: 'the tap must reach the real connect handler');
    expect(find.bySemanticsLabel('Отменить подключение'), findsOneWidget);
    expect(find.text('ПОДКЛЮЧЕНИЕ…'), findsOneWidget);
    expect(find.text('ОТКЛЮЧЕНО'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Отменить подключение'));
    await settleDashboard(tester);
    expect(api.disconnects, hasLength(1));
    api.connects.single.complete();
    await settleDashboard(tester);
    expect(find.byType(SnackBar), findsNothing);
    } finally {
      semantics.dispose();
    }
  });
}
