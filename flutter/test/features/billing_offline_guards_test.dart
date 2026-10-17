import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/billing_profile.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';

/// Guards the entitlement contract of the cabinet profile.
///
/// Users connect through the tunnel with the subscription link, so a client that
/// guesses "expired" from a missing field locks them out of a working VPN. These
/// tests pin the rules:
///  * the authoritative key is `expires_at` (the unified account payload), not
///    only `expire_at`;
///  * "no expiry date" means unknown, never expired;
///  * an offline fallback replays real data marked stale instead of inventing
///    days, and keeps the real daily tariff.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BillingProfile entitlement parsing', () {
    test('reads the unified expires_at key and derives days left', () {
      final expiry = DateTime.now().add(const Duration(days: 12, hours: 2));
      final profile = BillingProfile.fromJson({
        'linked': true,
        'status': 'active',
        'expires_at': expiry.toUtc().toIso8601String(),
      });

      expect(profile.expireAt, isNotNull);
      expect(profile.daysLeft, greaterThanOrEqualTo(12));
      expect(profile.isExpired, isFalse);
    });

    test('a profile with no expiry date is unknown, not expired', () {
      final profile = BillingProfile(
        linked: true,
        status: 'unknown',
        daysLeft: 0,
        stale: true,
      );

      expect(profile.isExpired, isFalse,
          reason: 'a transient outage must not block the tunnel');
    });

    test('an explicit insufficient_funds status still expires access', () {
      final profile = BillingProfile(
        linked: true,
        status: 'insufficient_funds',
        daysLeft: 0,
      );

      expect(profile.isExpired, isTrue);
    });

    test('a past expiry date expires access', () {
      final profile = BillingProfile(
        linked: true,
        status: 'active',
        expireAt: DateTime.now().subtract(const Duration(hours: 1)),
        daysLeft: 0,
      );

      expect(profile.isExpired, isTrue);
    });

    test('asStale keeps entitlement values and only flips the freshness flag',
        () {
      final fresh = BillingProfile(
        linked: true,
        status: 'active',
        daysLeft: 9,
        pricePerDayRub: 3,
      );
      final stale = fresh.asStale();

      expect(stale.stale, isTrue);
      expect(fresh.stale, isFalse);
      expect(stale.daysLeft, 9);
      expect(stale.pricePerDayRub, 3);
      expect(stale.status, 'active');
    });
  });

  group('unified account payload mapping', () {
    final service = AndroidMosaicAccountService.instance;

    test('keeps days_left and the real daily tariff', () {
      final expiry = DateTime.now().add(const Duration(days: 20));
      final profile = service.debugBillingProfileFromPayload({
        'telegram_id': 42,
        'username': 'web_42',
        'status': 'active',
        'short_uuid': 'abc',
        'expires_at': expiry.toUtc().toIso8601String(),
        'days_left': 20,
        'traffic_used_bytes': 2048,
        'traffic_limit_bytes': 4096,
        'billing': {'price_per_day_rub': 5},
      });

      expect(profile.linked, isTrue);
      expect(profile.daysLeft, 20);
      expect(profile.pricePerDayRub, 5,
          reason: 'charging the default 1 RUB/day undercharges the user');
      expect(profile.usedTrafficBytes, 2048);
      expect(profile.trafficLimitBytes, 4096);
      expect(profile.isExpired, isFalse);
    });

    test('a paying account past its trial keeps the paid entitlement', () {
      final expiry = DateTime.now().add(const Duration(days: 7));
      final profile = service.debugBillingProfileFromPayload({
        'status': 'active',
        'expires_at': expiry.toUtc().toIso8601String(),
      });

      expect(profile.daysLeft, greaterThanOrEqualTo(7));
      expect(profile.isExpired, isFalse);
    });

    test('the daily tariff never collapses to zero', () {
      final profile = service.debugBillingProfileFromPayload({
        'status': 'active',
        'billing': {'price_per_day_rub': 0},
      });

      expect(profile.pricePerDayRub, 1);
    });
  });
}
