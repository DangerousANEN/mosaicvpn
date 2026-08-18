class UnifiedAccount {
  final String accountId;
  final String status;
  final String tier;
  final int balanceKopecks;
  final String currency;
  final DateTime? trialEndsAt;
  final DateTime? expiresAt;
  final DateTime? nextChargeEstimateAt;
  final String? shortUuid;
  final String? subscriptionUrl;
  final int pricePerDayKopecks;
  final String timezone;
  final int checkoutDiscountPercent;
  final int daysLeft;
  final int trafficUsedBytes;
  final int trafficLimitBytes;
  final int lifetimeTrafficBytes;
  final int deviceLimit;
  final List<SubscriptionDevice> devices;
  final SubscriptionStatistics statistics;

  const UnifiedAccount({
    required this.accountId,
    required this.status,
    required this.tier,
    required this.balanceKopecks,
    required this.currency,
    required this.trialEndsAt,
    this.expiresAt,
    this.nextChargeEstimateAt,
    required this.shortUuid,
    required this.subscriptionUrl,
    required this.pricePerDayKopecks,
    required this.timezone,
    required this.checkoutDiscountPercent,
    this.daysLeft = 0,
    this.trafficUsedBytes = 0,
    this.trafficLimitBytes = 0,
    this.lifetimeTrafficBytes = 0,
    this.deviceLimit = 0,
    this.devices = const [],
    this.statistics = const SubscriptionStatistics(
      routesAvailable: 0,
      devicesSeen: 0,
      providerStatus: '',
      lastSyncAt: null,
    ),
  });

  factory UnifiedAccount.fromJson(Map<String, dynamic> json) {
    final billing =
        (json['billing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rub = (json['balance'] as num?)?.toDouble() ?? 0;
    final priceRub = (billing['price_per_day_rub'] as num?)?.toDouble() ?? 0;
    final devices = (json['devices'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => SubscriptionDevice.fromJson(row.cast<String, dynamic>()))
        .toList(growable: false);
    return UnifiedAccount(
      accountId: json['account_id']?.toString() ?? '',
      status: json['status']?.toString() ?? 'unknown',
      tier: json['tier']?.toString() ?? '',
      balanceKopecks:
          (json['balance_kopecks'] as num?)?.toInt() ?? (rub * 100).round(),
      currency: json['currency']?.toString() ?? 'RUB',
      trialEndsAt: DateTime.tryParse(json['trial_ends_at']?.toString() ?? ''),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      nextChargeEstimateAt:
          DateTime.tryParse(json['next_charge_estimate_at']?.toString() ?? ''),
      shortUuid: json['short_uuid']?.toString(),
      subscriptionUrl: json['sub_url']?.toString(),
      pricePerDayKopecks: (priceRub * 100).round(),
      timezone: billing['timezone']?.toString() ?? 'Europe/Moscow',
      checkoutDiscountPercent:
          (billing['checkout_discount_percent'] as num?)?.toInt() ?? 0,
      daysLeft: (json['days_left'] as num?)?.toInt() ?? rub.floor(),
      trafficUsedBytes: (json['traffic_used_bytes'] as num?)?.toInt() ?? 0,
      trafficLimitBytes: (json['traffic_limit_bytes'] as num?)?.toInt() ?? 0,
      lifetimeTrafficBytes:
          (json['lifetime_traffic_bytes'] as num?)?.toInt() ?? 0,
      deviceLimit: (json['device_limit'] as num?)?.toInt() ?? 0,
      devices: devices,
      statistics: SubscriptionStatistics.fromJson(
          (json['statistics'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }

  double get balanceRub => balanceKopecks / 100;
  double get pricePerDayRub => pricePerDayKopecks / 100;
  bool get isActive => status == 'active';
  bool get isFrozen => status == 'frozen';
  bool get needsFunds => status == 'insufficient_funds';
  bool get hasTrafficLimit => trafficLimitBytes > 0;
}

/// Safe metadata visible to whoever holds a subscription capability URL. This
/// intentionally excludes balance, payment history, device identifiers,
/// subscription credentials and all account-control fields.
class SubscriptionBaseProfile {
  const SubscriptionBaseProfile({
    required this.providerName,
    required this.status,
    required this.tier,
    required this.expiresAt,
    required this.daysLeft,
    required this.trafficUsedBytes,
    required this.trafficLimitBytes,
    required this.lifetimeTrafficBytes,
    required this.deviceLimit,
    required this.lastSyncAt,
  });

  final String providerName;
  final String status;
  final String tier;
  final DateTime? expiresAt;
  final int daysLeft;
  final int trafficUsedBytes;
  final int trafficLimitBytes;
  final int lifetimeTrafficBytes;
  final int deviceLimit;
  final DateTime? lastSyncAt;

  factory SubscriptionBaseProfile.fromJson(Map<String, dynamic> json) =>
      SubscriptionBaseProfile(
        providerName: json['provider_name']?.toString() ?? 'MosaicVPN',
        status: json['status']?.toString() ?? 'unknown',
        tier: json['tier']?.toString() ?? '',
        expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
        daysLeft: (json['days_left'] as num?)?.toInt() ?? 0,
        trafficUsedBytes: (json['traffic_used_bytes'] as num?)?.toInt() ?? 0,
        trafficLimitBytes: (json['traffic_limit_bytes'] as num?)?.toInt() ?? 0,
        lifetimeTrafficBytes:
            (json['lifetime_traffic_bytes'] as num?)?.toInt() ?? 0,
        deviceLimit: (json['device_limit'] as num?)?.toInt() ?? 0,
        lastSyncAt: DateTime.tryParse(json['last_sync_at']?.toString() ?? ''),
      );

  bool get hasTrafficLimit => trafficLimitBytes > 0;
}

class SubscriptionDevice {
  final String id;
  final String label;
  final String platform;
  final DateTime? lastSeenAt;

  const SubscriptionDevice({
    required this.id,
    required this.label,
    required this.platform,
    required this.lastSeenAt,
  });

  factory SubscriptionDevice.fromJson(Map<String, dynamic> json) =>
      SubscriptionDevice(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? 'Устройство',
        platform: json['platform']?.toString() ?? '',
        lastSeenAt: DateTime.tryParse(json['last_seen_at']?.toString() ?? ''),
      );
}

class SubscriptionStatistics {
  final int routesAvailable;
  final int devicesSeen;
  final String providerStatus;
  final DateTime? lastSyncAt;

  const SubscriptionStatistics({
    required this.routesAvailable,
    required this.devicesSeen,
    required this.providerStatus,
    required this.lastSyncAt,
  });

  factory SubscriptionStatistics.fromJson(Map<String, dynamic> json) =>
      SubscriptionStatistics(
        routesAvailable: (json['routes_available'] as num?)?.toInt() ?? 0,
        devicesSeen: (json['devices_seen'] as num?)?.toInt() ?? 0,
        providerStatus: json['provider_status']?.toString() ?? '',
        lastSyncAt: DateTime.tryParse(json['last_sync_at']?.toString() ?? ''),
      );
}

class CheckoutProviderOption {
  final String id;
  final String title;
  final String currency;
  final bool available;
  final int minAmountRub;
  final int maxAmountRub;

  const CheckoutProviderOption({
    required this.id,
    required this.title,
    required this.currency,
    required this.available,
    required this.minAmountRub,
    required this.maxAmountRub,
  });

  factory CheckoutProviderOption.fromJson(Map<String, dynamic> json) =>
      CheckoutProviderOption(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? 'Payment',
        currency: json['currency']?.toString() ?? '',
        available: json['available'] == true,
        minAmountRub: (json['min_amount_rub'] as num?)?.toInt() ?? 10,
        maxAmountRub: (json['max_amount_rub'] as num?)?.toInt() ?? 365,
      );
}

class CheckoutSession {
  final String provider;
  final Uri checkoutUrl;
  final int amountRub;
  final String message;

  const CheckoutSession({
    required this.provider,
    required this.checkoutUrl,
    required this.amountRub,
    required this.message,
  });

  factory CheckoutSession.fromJson(Map<String, dynamic> json) {
    final url = Uri.tryParse(json['checkout_url']?.toString() ?? '');
    if (url == null || !url.hasScheme) {
      throw const FormatException('Payment service returned an invalid URL.');
    }
    return CheckoutSession(
      provider: json['provider']?.toString() ?? '',
      checkoutUrl: url,
      amountRub: (json['amount_rub'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
    );
  }
}

class RotatedSubscriptionLink {
  final Uri subscriptionUrl;
  final String shortUuid;

  const RotatedSubscriptionLink(
      {required this.subscriptionUrl, required this.shortUuid});

  factory RotatedSubscriptionLink.fromJson(Map<String, dynamic> json) {
    final url = Uri.tryParse(json['subscription_url']?.toString() ?? '');
    if (url == null || !url.hasScheme) {
      throw const FormatException(
          'Account service returned an invalid subscription link.');
    }
    return RotatedSubscriptionLink(
      subscriptionUrl: url,
      shortUuid: json['short_uuid']?.toString() ?? '',
    );
  }
}
