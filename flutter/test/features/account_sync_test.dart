import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/daemon_api_base.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:mosaic_vpn/core/providers/billing_provider.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';
import 'package:mosaic_vpn/features/account/account_screen.dart';
import 'package:mosaic_vpn/features/account/account_sync_helper.dart';
import 'package:mosaic_vpn/features/account/unified_account_panel.dart';

class _FakeDaemonApi implements DaemonApiBase {
  BillingProfile profile;
  List<Subscription> subscriptions;
  int enrollCalls = 0;
  int addCalls = 0;
  bool failEnroll = false;
  Duration? enrollDelay;
  Subscription? lastEnrolled;
  Map<String, dynamic>? lastEnrollArgs;

  _FakeDaemonApi({
    required this.profile,
    this.subscriptions = const [],
    this.failEnroll = false,
    this.enrollDelay,
  });

  @override
  Future<BillingProfile> getBillingProfile() async => profile;

  @override
  Future<List<PaymentEntry>> getPaymentHistory() async => const [];

  @override
  Future<UnifiedAccount?> getUnifiedAccount() async => null;

  @override
  Future<List<Subscription>> listSubscriptions() async => subscriptions;

  @override
  Future<Subscription> enrollProviderSubscription({
    required String providerId,
    required String providerAccountId,
    required String subscriptionName,
    required String subscriptionUrl,
    String? sessionToken,
    String? directToken,
    String? username,
  }) async {
    enrollCalls++;
    lastEnrollArgs = {
      'providerId': providerId,
      'providerAccountId': providerAccountId,
      'subscriptionName': subscriptionName,
      'subscriptionUrl': subscriptionUrl,
      'sessionToken': sessionToken,
      'directToken': directToken,
      'username': username,
    };
    if (enrollDelay != null) {
      await Future<void>.delayed(enrollDelay!);
    }
    if (failEnroll) {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/providers/enroll'),
        message: 'Route sync failed: upstream unreachable',
      );
    }
    final existingIndex = subscriptions.indexWhere(
        (s) => s.url.trim() == subscriptionUrl.trim());
    if (existingIndex >= 0) {
      final updated = subscriptions[existingIndex].copyWith(
        name: subscriptionName,
        url: subscriptionUrl,
      );
      subscriptions[existingIndex] = updated;
      lastEnrolled = updated;
      return updated;
    }
    final created = Subscription(
      id: 'sub-${subscriptions.length + 1}',
      name: subscriptionName,
      url: subscriptionUrl,
      autoRefresh: true,
      serverCount: 5,
      source: 'url',
    );
    subscriptions = [...subscriptions, created];
    lastEnrolled = created;
    return created;
  }

  @override
  Future<Subscription> addSubscription(
    String name,
    String url, {
    bool autoRefresh = false,
    int refreshInterval = 3600,
  }) async {
    addCalls++;
    final created = Subscription(
      id: 'sub-fallback-${subscriptions.length + 1}',
      name: name,
      url: url,
      autoRefresh: autoRefresh,
      serverCount: 3,
      source: 'url',
    );
    subscriptions = [...subscriptions, created];
    return created;
  }

  @override
  Future<LinkResult> redeemLinkCode(String code,
      {String? subscriptionId}) async {
    return const LinkResult(ok: true, telegramId: 1, username: 'u');
  }

  @override
  Future<void> loginWithEmail(String email, String password) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed: ${invocation.memberName}');
}

class _FakeAccountLoginAuthority implements AccountLoginAuthority {
  int loginWithEmailCalls = 0;
  int redeemTelegramCodeCalls = 0;
  int completeWebsiteLoginCalls = 0;
  int restoreSessionCalls = 0;

  bool failEmailLogin = false;
  bool failTelegramCode = false;
  Duration? emailLoginDelay;
  Duration? telegramCodeDelay;

  AndroidMosaicSession? sessionToReturn;
  AndroidMosaicSession? websiteSessionToReturn;
  AndroidMosaicSession? restoredSession;

  _FakeAccountLoginAuthority({
    this.sessionToReturn,
    this.websiteSessionToReturn,
    this.failEmailLogin = false,
    this.emailLoginDelay,
  });

  @override
  Future<Uri> beginWebsiteLogin() async {
    return Uri.parse('https://sub.zxc1x1.ru/cabinet.html');
  }

  @override
  Future<AndroidMosaicSession?> completeWebsiteLoginIfPresent() async {
    completeWebsiteLoginCalls++;
    return websiteSessionToReturn;
  }

  @override
  Future<AndroidMosaicSession> redeemTelegramCode(String rawCode) async {
    redeemTelegramCodeCalls++;
    if (telegramCodeDelay != null) {
      await Future<void>.delayed(telegramCodeDelay!);
    }
    if (failTelegramCode) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/telegram/redeem'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/telegram/redeem'),
          statusCode: 404,
        ),
      );
    }
    return sessionToReturn ??
        const AndroidMosaicSession(
          directToken: 'tok-tg-123',
          subscriptionUrl: 'https://sub.zxc1x1.ru/tok-tg-123',
          username: 'tguser',
        );
  }

  @override
  Future<AndroidMosaicSession> loginWithEmail(
      String email, String password) async {
    loginWithEmailCalls++;
    if (emailLoginDelay != null) {
      await Future<void>.delayed(emailLoginDelay!);
    }
    if (failEmailLogin) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/auth/login'),
          statusCode: 401,
        ),
      );
    }
    return sessionToReturn ??
        const AndroidMosaicSession(
          directToken: 'tok-email-456',
          subscriptionUrl: 'https://sub.zxc1x1.ru/tok-email-456',
          username: 'test@example.com',
        );
  }

  @override
  Future<AndroidMosaicSession?> restoreSession() async {
    restoreSessionCalls++;
    return restoredSession ?? sessionToReturn;
  }
}

BillingProfile _unlinkedProfile() => BillingProfile(
      linked: false,
      telegramId: 0,
      username: '',
      shortUuid: '',
      status: 'UNLINKED',
      tag: '',
      squadName: '',
      email: '',
      trafficLimitBytes: 0,
      usedTrafficBytes: 0,
      expireAt: null,
      daysLeft: 0,
      description: '',
    );

Future<void> _pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Widget _buildScope({
  required _FakeDaemonApi api,
  required _FakeAccountLoginAuthority auth,
  BillingProfile? profile,
}) {
  return ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(api),
      accountLoginAuthorityProvider.overrideWithValue(auth),
      accountSyncServiceProvider.overrideWithValue(AccountSyncService(api: api)),
      billingProfileProvider.overrideWith((ref) async => profile ?? api.profile),
      paymentHistoryProvider.overrideWith((ref) async => const []),
      unifiedAccountProvider.overrideWith((ref) async => null),
      androidMosaicSessionProvider.overrideWith((ref) async => auth.restoredSession),
    ],
    child: const MaterialApp(
      home: AccountScreen(),
    ),
  );
}

void main() {
  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
  });

  group('AccountSyncService unit tests', () {
    test('normalizes subscription URL correctly', () {
      const s1 = AndroidMosaicSession(directToken: 'abc');
      expect(AccountSyncService.normalizeSubscriptionUrl(s1),
          'https://sub.zxc1x1.ru/abc');

      const s2 = AndroidMosaicSession(
        directToken: 'abc',
        subscriptionUrl: 'sub.zxc1x1.ru/custom-token...',
      );
      expect(AccountSyncService.normalizeSubscriptionUrl(s2),
          'https://sub.zxc1x1.ru/custom-token');

      const s3 = AndroidMosaicSession(
        directToken: 'abc',
        subscriptionUrl: 'https://sub.zxc1x1.ru/feed',
      );
      expect(AccountSyncService.normalizeSubscriptionUrl(s3),
          'https://sub.zxc1x1.ru/feed');
    });

    test('deduplicates concurrent in-flight sync calls for the same session',
        () async {
      final api = _FakeDaemonApi(
        profile: _unlinkedProfile(),
        enrollDelay: const Duration(milliseconds: 100),
      );
      final sync = AccountSyncService(api: api);
      const session = AndroidMosaicSession(
        directToken: 'shared-token',
        subscriptionUrl: 'https://sub.zxc1x1.ru/shared-token',
        username: 'same-user',
      );

      final f1 = sync.syncSession(session);
      final f2 = sync.syncSession(session);

      final results = await Future.wait([f1, f2]);
      expect(results[0].id, results[1].id);
      expect(api.enrollCalls, 1);
      expect(api.subscriptions.length, 1);
    });

    test('updates existing subscription without creating duplicates', () async {
      final existing = Subscription(
        id: 'sub-existing',
        name: 'Old Name',
        url: 'https://sub.zxc1x1.ru/tok-1',
        autoRefresh: true,
        serverCount: 2,
        source: 'url',
      );
      final api = _FakeDaemonApi(
        profile: _unlinkedProfile(),
        subscriptions: [existing],
      );
      final sync = AccountSyncService(api: api);
      const session = AndroidMosaicSession(
        directToken: 'tok-1',
        subscriptionUrl: 'https://sub.zxc1x1.ru/tok-1',
        subscriptionName: 'Updated Name',
      );

      final enrolled = await sync.syncSession(session);
      expect(enrolled.id, 'sub-existing');
      expect(enrolled.name, 'Updated Name');
      expect(api.subscriptions.length, 1);
    });

    test('invalidates all dependent providers', () {
      final invalidated = <dynamic>[];
      AccountSyncService.invalidateDependentProviders((provider) {
        invalidated.add(provider);
      });
      expect(invalidated.contains(androidMosaicSessionProvider), isTrue);
      expect(invalidated.contains(billingProfileProvider), isTrue);
      expect(invalidated.contains(unifiedAccountProvider), isTrue);
      expect(invalidated.contains(subscriptionsProvider), isTrue);
      expect(invalidated.contains(mosaicManifestProvider), isTrue);
      expect(invalidated.contains(serversProvider), isTrue);
      expect(invalidated.contains(serverGroupsProvider), isTrue);
    });
  });

  group('AccountScreen Android email login synchronization', () {
    testWidgets(
        'successful email login triggers route enrollment and updates cabinet',
        (tester) async {
      final api = _FakeDaemonApi(profile: _unlinkedProfile());
      final auth = _FakeAccountLoginAuthority(
        sessionToReturn: const AndroidMosaicSession(
          directToken: 'email-tok-99',
          subscriptionUrl: 'https://sub.zxc1x1.ru/email-tok-99',
          username: 'alice@example.com',
        ),
      );

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      await _pumpAsync(tester);

      // Select Email tab
      await tester.tap(find.text('Почта'));
      await _pumpAsync(tester);

      // Fill email and password
      await tester.enterText(
          find.widgetWithText(TextField, 'E-mail'), 'alice@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Пароль'), 'password123');

      // Submit
      await tester.tap(find.text('Войти с паролем'));
      await _pumpAsync(tester);

      expect(auth.loginWithEmailCalls, 1);
      expect(api.enrollCalls, 1);
      expect(api.lastEnrollArgs?['directToken'], 'email-tok-99');
      expect(api.lastEnrollArgs?['subscriptionUrl'],
          'https://sub.zxc1x1.ru/email-tok-99');
      expect(api.subscriptions.length, 1);
    });

    testWidgets(
        'bad password displays bad-password error and does NOT call route sync',
        (tester) async {
      final api = _FakeDaemonApi(profile: _unlinkedProfile());
      final auth = _FakeAccountLoginAuthority(failEmailLogin: true);

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      await _pumpAsync(tester);

      await tester.tap(find.text('Почта'));
      await _pumpAsync(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'E-mail'), 'bob@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Пароль'), 'wrongpassword');

      await tester.tap(find.text('Войти с паролем'));
      await _pumpAsync(tester);

      expect(auth.loginWithEmailCalls, 1);
      expect(api.enrollCalls, 0);
      expect(
        find.text(
            'Email or password is incorrect. Try again or create an account on the website.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'successful auth with failing route sync displays recoverable route-sync error, not bad-password',
        (tester) async {
      final api = _FakeDaemonApi(
        profile: _unlinkedProfile(),
        failEnroll: true,
      );
      final auth = _FakeAccountLoginAuthority(
        sessionToReturn: const AndroidMosaicSession(
          directToken: 'email-tok-err',
          subscriptionUrl: 'https://sub.zxc1x1.ru/email-tok-err',
          username: 'charlie@example.com',
        ),
      );

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      await _pumpAsync(tester);

      await tester.tap(find.text('Почта'));
      await _pumpAsync(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'E-mail'), 'charlie@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Пароль'), 'validpassword123');

      await tester.tap(find.text('Войти с паролем'));
      await _pumpAsync(tester);

      expect(auth.loginWithEmailCalls, 1);
      expect(api.enrollCalls, 1);

      // Must NOT display incorrect password
      expect(
        find.text(
            'Email or password is incorrect. Try again or create an account on the website.'),
        findsNothing,
      );

      // Displays recoverable route sync error
      expect(
        find.text(AccountSyncService.routeSyncErrorMessage),
        findsOneWidget,
      );

      // Verify Retry recovery button exists and tapping it retries sync
      api.failEnroll = false; // recovery now succeeds
      final retryButton = find.byKey(const ValueKey('route-sync-retry-button'));
      expect(retryButton, findsOneWidget);

      await tester.tap(retryButton);
      await _pumpAsync(tester);

      expect(api.enrollCalls, 2);
      expect(api.subscriptions.length, 1);
      expect(find.byKey(const ValueKey('route-sync-retry-button')), findsNothing);
    });

    testWidgets('double submit on email login does not send duplicate calls',
        (tester) async {
      final api = _FakeDaemonApi(profile: _unlinkedProfile());
      final auth = _FakeAccountLoginAuthority(
        emailLoginDelay: const Duration(milliseconds: 80),
      );

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      await _pumpAsync(tester);

      await tester.tap(find.text('Почта'));
      await _pumpAsync(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'E-mail'), 'dave@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Пароль'), 'password123');

      // Tap twice quickly
      await tester.tap(find.text('Войти с паролем'));
      await tester.tap(find.text('Войти с паролем'));
      await _pumpAsync(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await _pumpAsync(tester);

      expect(auth.loginWithEmailCalls, 1);
      expect(api.enrollCalls, 1);
    });
  });

  group('AccountScreen Android Telegram pairing code synchronization', () {
    testWidgets('successful code redemption enrolls route and updates cabinet',
        (tester) async {
      final api = _FakeDaemonApi(profile: _unlinkedProfile());
      final auth = _FakeAccountLoginAuthority(
        sessionToReturn: const AndroidMosaicSession(
          directToken: 'tg-direct-tok',
          subscriptionUrl: 'https://sub.zxc1x1.ru/tg-direct-tok',
          username: 'tguser',
        ),
      );

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      await _pumpAsync(tester);

      await tester.enterText(
          find.byKey(const ValueKey('pairing-code-input')), 'AB23CD45');
      await tester.tap(find.text('Link account'));
      await _pumpAsync(tester);

      expect(auth.redeemTelegramCodeCalls, 1);
      expect(api.enrollCalls, 1);
      expect(api.lastEnrollArgs?['directToken'], 'tg-direct-tok');
      expect(api.subscriptions.length, 1);
    });

    testWidgets(
        'code redemption route-sync error displays recoverable error separate from code errors',
        (tester) async {
      final api = _FakeDaemonApi(
        profile: _unlinkedProfile(),
        failEnroll: true,
      );
      final auth = _FakeAccountLoginAuthority();

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      await _pumpAsync(tester);

      await tester.enterText(
          find.byKey(const ValueKey('pairing-code-input')), 'AB23CD45');
      await tester.tap(find.text('Link account'));
      await _pumpAsync(tester);

      expect(auth.redeemTelegramCodeCalls, 1);
      expect(api.enrollCalls, 1);

      // Must not display "Code expired" or "Code not recognised"
      expect(find.textContaining('Code expired'), findsNothing);
      expect(find.textContaining('Code not recognised'), findsNothing);

      // Displays route sync error
      expect(
        find.text(AccountSyncService.routeSyncErrorMessage),
        findsOneWidget,
      );
    });
  });

  group('AccountScreen Android website login synchronization', () {
    testWidgets('website login callback triggers post-auth route enrollment',
        (tester) async {
      final api = _FakeDaemonApi(profile: _unlinkedProfile());
      final auth = _FakeAccountLoginAuthority(
        websiteSessionToReturn: const AndroidMosaicSession(
          directToken: 'web-tok-789',
          subscriptionUrl: 'https://sub.zxc1x1.ru/web-tok-789',
          username: 'webuser',
        ),
      );

      await tester.pumpWidget(_buildScope(api: api, auth: auth));
      // First post-frame callback runs _finishWebsiteLogin
      await _pumpAsync(tester);

      expect(auth.completeWebsiteLoginCalls, 1);
      expect(api.enrollCalls, 1);
      expect(api.lastEnrollArgs?['directToken'], 'web-tok-789');
      expect(api.subscriptions.length, 1);
    });
  });
}
