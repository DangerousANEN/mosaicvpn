import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/billing_provider.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/billing/billing_screen.dart';

/// Guards the checkout limits and invoice re-entrancy.
///
/// The gateway rejects amounts below `min_amount_rub` (and above the maximum)
/// with an HTTP 400. Sending the request anyway means the user waits for a
/// round-trip and then reads an opaque "Ошибка: DioException…" line, which is a
/// dead end: nothing tells them what to change. The client already receives
/// those limits in `/api/checkout/options`, so it must apply them locally.
class _LimitsApi extends MockDaemonApi {
  _LimitsApi({this.minAmountRub = 0, this.maxAmountRub = 0});

  final int minAmountRub;
  final int maxAmountRub;
  int checkoutCalls = 0;
  int? lastAmountRub;

  @override
  Future<List<CheckoutProviderOption>> getCheckoutOptions() async {
    if (minAmountRub == 0 && maxAmountRub == 0) {
      return super.getCheckoutOptions();
    }
    return [
      CheckoutProviderOption(
        id: 'lava',
        title: 'СБП и карты',
        currency: 'RUB',
        available: true,
        minAmountRub: minAmountRub,
        maxAmountRub: maxAmountRub,
      ),
    ];
  }

  @override
  Future<CheckoutSession> createCheckout(
      {required int amountRub, required String provider}) async {
    checkoutCalls++;
    lastAmountRub = amountRub;
    return CheckoutSession(
      provider: provider,
      checkoutUrl: Uri.parse('https://pay.lava.ru/test'),
      amountRub: amountRub,
      message: '',
    );
  }
}

BillingProfile _profile({int daysLeft = 20, int pricePerDayRub = 1}) =>
    BillingProfile(
      linked: true,
      telegramId: 424242,
      username: 'nikita',
      status: 'active',
      daysLeft: daysLeft,
      pricePerDayRub: pricePerDayRub,
    );

Widget _wrap(_LimitsApi api, {int pricePerDayRub = 1}) => ProviderScope(
      overrides: [
        daemonApiProvider.overrideWithValue(api),
        billingProfileProvider.overrideWith(
            (ref) async => _profile(pricePerDayRub: pricePerDayRub)),
      ],
      child: const MaterialApp(home: BillingScreen()),
    );

Future<void> _pumpReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> _tapTopup(WidgetTester tester) async {
  final button = find.textContaining('Пополнить на');
  expect(button, findsOneWidget);
  await tester.tap(button);
  await _pumpReady(tester);
}

void main() {
  testWidgets('an amount below the gateway minimum never reaches the network',
      (tester) async {
    tester.view.physicalSize = const Size(520, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 30 days × 1 ₽ = 30 ₽, below the 50 ₽ minimum.
    final api = _LimitsApi(minAmountRub: 50, maxAmountRub: 5000);
    await tester.pumpWidget(_wrap(api));
    await _pumpReady(tester);

    await _tapTopup(tester);

    expect(api.checkoutCalls, 0,
        reason: 'the client must reject the amount locally');
    expect(find.textContaining('Минимум 50 ₽'), findsOneWidget,
        reason: 'the user needs to know the real minimum, not a raw HTTP error');
  });

  testWidgets('an amount above the gateway maximum never reaches the network',
      (tester) async {
    tester.view.physicalSize = const Size(520, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _LimitsApi(minAmountRub: 1, maxAmountRub: 20);
    await tester.pumpWidget(_wrap(api));
    await _pumpReady(tester);

    await _tapTopup(tester);

    expect(api.checkoutCalls, 0);
    expect(find.textContaining('Максимум 20 ₽'), findsOneWidget);
  });

  testWidgets('a valid amount is charged in rubles, not in days',
      (tester) async {
    tester.view.physicalSize = const Size(520, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _LimitsApi();
    await tester.pumpWidget(_wrap(api, pricePerDayRub: 5));
    await _pumpReady(tester);

    await _tapTopup(tester);

    expect(api.checkoutCalls, 1);
    expect(api.lastAmountRub, 150,
        reason: '30 days at 5 ₽/day must be billed as 150 ₽, not 30');
  });
}
