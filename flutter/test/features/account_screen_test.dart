import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/daemon_api_base.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/features/account/account_screen.dart';

/// Minimal fake: only the cabinet endpoints matter here, and going through
/// MockDaemonApi would drag in unrelated network-ish behaviour.
class _FakeApi implements DaemonApiBase {
  final BillingProfile profile;
  final List<PaymentEntry> payments;
  final int? linkFailStatus;

  int linkCalls = 0;
  String? lastCode;

  _FakeApi({
    required this.profile,
    this.payments = const [],
    this.linkFailStatus,
  });

  @override
  Future<BillingProfile> getBillingProfile() async => profile;

  @override
  Future<List<PaymentEntry>> getPaymentHistory() async => payments;

  @override
  Future<LinkResult> redeemLinkCode(String code) async {
    linkCalls++;
    lastCode = code;
    if (linkFailStatus != null) {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/account/link'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/account/link'),
          statusCode: linkFailStatus,
        ),
      );
    }
    return const LinkResult(ok: true, telegramId: 1, username: 'u');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed: ${invocation.memberName}');
}

BillingProfile _profile({
  bool linked = true,
  String username = 'nikita',
  String status = 'ACTIVE',
  int daysLeft = 20,
  int limit = 0,
  int used = 0,
}) =>
    BillingProfile(
      linked: linked,
      telegramId: linked ? 424242 : 0,
      username: username,
      shortUuid: '',
      status: status,
      tag: '',
      squadName: '',
      email: '',
      trafficLimitBytes: limit,
      usedTrafficBytes: used,
      expireAt: null,
      daysLeft: daysLeft,
      description: '',
    );

Widget _wrap(_FakeApi api, {Size size = const Size(390, 844)}) {
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(api),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: const MaterialApp(home: AccountScreen()),
    ),
  );
}

void main() {
  group('AccountScreen linking', () {
    testWidgets('unlinked account shows the pairing form, not a cabinet',
        (tester) async {
      final api = _FakeApi(profile: _profile(linked: false, username: ''));
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      expect(find.text('Link account'), findsOneWidget);
      expect(find.text('Payment history'), findsNothing);
    });

    testWidgets('empty code is rejected locally without calling the daemon',
        (tester) async {
      final api = _FakeApi(profile: _profile(linked: false));
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Link account'));
      await tester.pumpAndSettle();

      expect(api.linkCalls, 0);
      expect(find.text('Enter the code from the bot.'), findsOneWidget);
    });

    testWidgets('expired code surfaces the "ask for a new one" hint',
        (tester) async {
      final api = _FakeApi(profile: _profile(linked: false), linkFailStatus: 410);
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('pairing-code-input')), 'AB23CD45');
      await tester.tap(find.text('Link account'));
      await tester.pumpAndSettle();

      expect(api.linkCalls, 1);
      expect(find.text('Code expired. Ask the bot for a new one.'),
          findsOneWidget);
    });

    testWidgets('unknown code does not claim the code expired', (tester) async {
      final api = _FakeApi(profile: _profile(linked: false), linkFailStatus: 404);
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('pairing-code-input')), 'ZZ99ZZ99');
      await tester.tap(find.text('Link account'));
      await tester.pumpAndSettle();

      expect(find.text('Code not recognised. Check the digits and try again.'),
          findsOneWidget);
      expect(find.textContaining('expired'), findsNothing);
    });

    testWidgets('lowercase input reaches the daemon as typed for normalisation',
        (tester) async {
      final api = _FakeApi(profile: _profile(linked: false), linkFailStatus: 404);
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('pairing-code-input')), 'ab23cd45');
      await tester.tap(find.text('Link account'));
      await tester.pumpAndSettle();

      expect(api.lastCode, 'ab23cd45');
    });
  });

  group('AccountScreen cabinet', () {
    testWidgets('linked account shows subscription and payment history',
        (tester) async {
      final api = _FakeApi(
        profile: _profile(daysLeft: 12),
        payments: [
          PaymentEntry(
            id: 'p1',
            provider: 'lava',
            amount: 199,
            currency: 'RUB',
            status: 'paid',
            days: 30,
            createdAt: DateTime(2026, 7, 1),
            paidAt: DateTime(2026, 7, 1),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      expect(find.text('nikita'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('in 12 days'), findsOneWidget);
      expect(find.text('Payment history'), findsOneWidget);
      expect(find.text('199 RUB'), findsOneWidget);
    });

    testWidgets('expired subscription is not reported as remaining days',
        (tester) async {
      final api = _FakeApi(profile: _profile(daysLeft: 0, status: 'EXPIRED'));
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      expect(find.text('expired'), findsOneWidget);
      expect(find.textContaining('in 0'), findsNothing);
    });

    testWidgets('usage over the limit clamps instead of overflowing',
        (tester) async {
      // 12 GB used against a 10 GB plan: a raw ratio would exceed 1.0 and
      // assert inside LinearProgressIndicator.
      final api = _FakeApi(
        profile: _profile(
          limit: 10 * 1024 * 1024 * 1024,
          used: 12 * 1024 * 1024 * 1024,
        ),
      );
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, 1.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unlimited plan reports usage without a progress bar',
        (tester) async {
      final api = _FakeApi(profile: _profile(limit: 0, used: 5 * 1024 * 1024));
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('unlimited'), findsOneWidget);
    });

    testWidgets('linked account with no payments says so explicitly',
        (tester) async {
      final api = _FakeApi(profile: _profile(), payments: const []);
      await tester.pumpWidget(_wrap(api));
      await tester.pumpAndSettle();

      expect(find.text('No payments yet.'), findsOneWidget);
    });

    testWidgets('lays out without overflow on a 360px phone', (tester) async {
      final api = _FakeApi(
        profile: _profile(
          username: 'a_very_long_account_name_that_should_ellipsize',
          limit: 100 * 1024 * 1024 * 1024,
          used: 42 * 1024 * 1024 * 1024,
        ),
        payments: [
          PaymentEntry(
            id: 'p1',
            provider: 'cryptobot',
            amount: 4.25,
            currency: 'USDT',
            status: 'pending',
            description:
                'a long human readable payment description that must ellipsize',
            createdAt: DateTime(2026, 8, 1),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(api, size: const Size(360, 640)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
