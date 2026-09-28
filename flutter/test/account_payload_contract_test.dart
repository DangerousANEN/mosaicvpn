import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Regression guard for the account-payload contract.
///
/// The account endpoints (/api/auth/register, /api/auth/login) answer with
/// `token` plus a ready `subscription_url`; they do NOT send `client_token` or
/// `direct_token`. Because the client demanded one of those two keys, a
/// perfectly successful signup was turned into "Сервис не выдал токен
/// конфигурации для устройства" and the one-tap onboarding could never finish.
class AccountPayloadContractTest {
  static void register() {
    TestWidgetsFlutterBinding.ensureInitialized();

    const channel = MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    });

    test('signup payload carrying token + subscription_url yields a session',
        () async {
      final account = AndroidMosaicAccountService.instance;
      final payload = {
        'token': 'session-abc123',
        'telegram_id': -7,
        'username': 'web_7',
        'expires_at': '2026-10-28T19:37:10+00:00',
        'subscription_url': 'https://sub.zxc1x1.ru/wMvk6jZ42Eea5qRT',
      };
      final session = account.debugSessionFromPayload(payload);
      expect(session.directToken, 'wMvk6jZ42Eea5qRT',
          reason: 'the profile token is the last segment of subscription_url');
      expect(session.sessionToken, 'session-abc123',
          reason: 'the session token is the separate cabinet credential');
      expect(session.subscriptionUrl, 'https://sub.zxc1x1.ru/wMvk6jZ42Eea5qRT');
    });

    test('explicit client_token still wins when present', () async {
      final account = AndroidMosaicAccountService.instance;
      final session = account.debugSessionFromPayload({
        'client_token': 'explicit-token',
        'token': 'other-token',
        'subscription_url': 'https://sub.zxc1x1.ru/from-url',
      });
      expect(session.directToken, 'explicit-token');
    });

    test('a payload with no usable token still fails loudly', () async {
      final account = AndroidMosaicAccountService.instance;
      expect(
        () => account.debugSessionFromPayload({'username': 'web_7'}),
        throwsA(isA<StateError>()),
      );
    });
  }
}

void main() => AccountPayloadContractTest.register();