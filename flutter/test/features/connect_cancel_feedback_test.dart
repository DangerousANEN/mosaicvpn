import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/dashboard/connection_dashboard.dart';

/// A cancel is a decision, not a fault.
///
/// Tapping "Отмена" while a smart-group connect is running aborts it through
/// `SmartGroupSelector`, which surfaces `StateError('Connection cancelled.')`.
/// The dashboard used to render that abort as "Ошибка подключения: Connection
/// cancelled." — i.e. it told the user their VPN was broken at the exact moment
/// they asked it to stop. These tests pin the distinction so a deliberate abort
/// stays silent while a genuine fault is still reported.
void main() {
  group('cancellation classification', () {
    test('an aborted connect is recognised as a cancellation', () {
      expect(
        ConnectionDashboard.isCancellationError(
            StateError('Connection cancelled.')),
        isTrue,
      );
    });

    test('the daemon cancelled-context wording is recognised', () {
      expect(
        ConnectionDashboard.isCancellationError(
            StateError('connect failed: context canceled')),
        isTrue,
      );
    });

    test('a real failure is NOT classified as a cancellation', () {
      expect(
        ConnectionDashboard.isCancellationError(
            StateError('No reachable or verified candidates are available')),
        isFalse,
        reason: 'an unavailable route must still be reported to the user',
      );
      expect(
        ConnectionDashboard.isCancellationError(
            Exception('Не удалось создать TUN: разрешение VPN')),
        isFalse,
      );
    });

    test('a disconnect timeout is not silently swallowed', () {
      expect(
        ConnectionDashboard.isCancellationError(
            TimeoutException('VPN runtime не подтвердил отключение.')),
        isFalse,
      );
    });
  });

  testWidgets('an aborting connect never shows a connection error notice',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _CancellingApi();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(api),
        vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
        subscriptionsForDisplayProvider.overrideWithValue([
          Subscription(
              id: 'local-default',
              name: 'Локальные профили',
              url: '',
              serverCount: 1),
        ]),
        serversProvider.overrideWith((ref) async => [
              Server(
                id: 'server-1',
                name: 'Amsterdam',
                protocol: Protocol.vless,
                subscriptionID: 'local-default',
                importUri:
                    'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@198.51.100.22:443?encryption=none#AMS',
              ),
            ]),
      ],
      child: const MaterialApp(home: Scaffold(body: ConnectionDashboard())),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Start the connect, then abort it the way the Cancel button does.
    final dial = find.byType(GestureDetector).first;
    await tester.tap(dial);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
  });
}

/// Connect always aborts, mimicking an aborted candidate attempt.
class _CancellingApi extends MockDaemonApi {
  @override
  Future<void> connect(String serverId) async {
    throw StateError('Connection cancelled.');
  }
}