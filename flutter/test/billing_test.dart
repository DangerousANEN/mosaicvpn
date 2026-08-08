import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';

void main() {
  group('Billing Data Models', () {
    test('BillingProfile serialization', () {
      final json = {
        'linked': true,
        'telegram_id': 123456,
        'username': 'test_user',
        'short_uuid': 'abc12345',
        'status': 'active',
        'squad_name': 'alpha_squad',
        'email': 'test@example.com',
        'traffic_limit_bytes': 10737418240,
        'used_traffic_bytes': 1073741824,
        'expire_at': '2026-08-01T00:00:00Z',
        'days_left': 15,
        'description': 'Test profile',
      };

      final profile = BillingProfile.fromJson(json);
      expect(profile.linked, true);
      expect(profile.telegramId, 123456);
      expect(profile.username, 'test_user');
      expect(profile.shortUuid, 'abc12345');
      expect(profile.squadName, 'alpha_squad');
      expect(profile.tag, 'alpha_squad');
      expect(profile.trafficLimitBytes, 10737418240);
      expect(profile.usedTrafficBytes, 1073741824);
      expect(profile.daysLeft, 15);

      final exported = profile.toJson();
      expect(exported['telegram_id'], 123456);
      expect(exported['username'], 'test_user');
    });

    test('TopupResponse & TopupStatusResponse serialization', () {
      final topupJson = {
        'invoice_id': 999,
        'pay_url': 'https://t.me/CryptoBot?start=IV999',
        'amount': '15.00',
        'asset': 'USDT',
      };

      final topup = TopupResponse.fromJson(topupJson);
      expect(topup.invoiceId, 999);
      expect(topup.payUrl, 'https://t.me/CryptoBot?start=IV999');
      expect(topup.amount, '15.00');
      expect(topup.asset, 'USDT');

      final statusJson = {
        'invoice_id': 999,
        'status': 'paid',
      };

      final status = TopupStatusResponse.fromJson(statusJson);
      expect(status.invoiceId, 999);
      expect(status.status, 'paid');
    });
  });

  group('MockDaemonApi Billing Endpoints', () {
    late MockDaemonApi api;

    setUp(() {
      api = MockDaemonApi();
    });

    test('getBillingProfile returns initial profile', () async {
      final profile = await api.getBillingProfile();
      expect(profile.linked, true);
      expect(profile.telegramId, 123456789);
    });

    test('linkBillingAccount updates profile', () async {
      await api.linkBillingAccount(888999, sessionToken: 'token_123');
      final profile = await api.getBillingProfile();
      expect(profile.linked, true);
      expect(profile.telegramId, 888999);
      expect(profile.username, 'telegram_888999');
    });

    test('unlinkBillingAccount clears profile', () async {
      await api.unlinkBillingAccount();
      final profile = await api.getBillingProfile();
      expect(profile.linked, false);
      expect(profile.telegramId, 0);
    });

    test('createTopup and getTopupStatus workflow', () async {
      final topup = await api.createTopup(amount: 25.5, days: 30, description: 'Monthly sub');
      expect(topup.invoiceId, greaterThan(0));
      expect(topup.amount, '25.50');
      expect(topup.asset, 'USDT');

      final status = await api.getTopupStatus(topup.invoiceId);
      expect(status.invoiceId, topup.invoiceId);
      expect(status.status, 'paid');
    });
  });
}
