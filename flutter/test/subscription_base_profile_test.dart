import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/unified_account.dart';

void main() {
  test('parses allow-listed subscription metadata without account controls',
      () {
    final profile = SubscriptionBaseProfile.fromJson(const {
      'provider_name': 'MosaicVPN',
      'status': 'active',
      'tier': 'standard',
      'expires_at': '2026-09-01T00:00:00+00:00',
      'days_left': 14,
      'traffic_used_bytes': 1024,
      'traffic_limit_bytes': 4096,
      'lifetime_traffic_bytes': 8192,
      'device_limit': 5,
      'last_sync_at': '2026-08-18T00:00:00+00:00',
      // Extra sensitive keys must not be modelled or required by the base UI.
      'devices': [],
      'balance': 999,
      'subscription_url': 'must-not-be-used',
    });

    expect(profile.providerName, 'MosaicVPN');
    expect(profile.status, 'active');
    expect(profile.daysLeft, 14);
    expect(profile.hasTrafficLimit, isTrue);
    expect(profile.trafficUsedBytes, 1024);
    expect(profile.deviceLimit, 5);
    expect(profile.expiresAt, isNotNull);
  });
}
