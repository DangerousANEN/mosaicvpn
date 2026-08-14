class UnifiedAccount {
  final String accountId;
  final String status;
  final String tier;
  final int balanceKopecks;
  final String currency;
  final DateTime? trialEndsAt;
  final String? shortUuid;
  final String? subscriptionUrl;
  final int pricePerDayKopecks;
  final String timezone;
  final int checkoutDiscountPercent;

  const UnifiedAccount({
    required this.accountId,
    required this.status,
    required this.tier,
    required this.balanceKopecks,
    required this.currency,
    required this.trialEndsAt,
    required this.shortUuid,
    required this.subscriptionUrl,
    required this.pricePerDayKopecks,
    required this.timezone,
    required this.checkoutDiscountPercent,
  });

  factory UnifiedAccount.fromJson(Map<String, dynamic> json) {
    final billing = (json['billing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rub = (json['balance'] as num?)?.toDouble() ?? 0;
    final priceRub = (billing['price_per_day_rub'] as num?)?.toDouble() ?? 0;
    return UnifiedAccount(
      accountId: json['account_id']?.toString() ?? '',
      status: json['status']?.toString() ?? 'unknown',
      tier: json['tier']?.toString() ?? '',
      balanceKopecks: (json['balance_kopecks'] as num?)?.toInt() ?? (rub * 100).round(),
      currency: json['currency']?.toString() ?? 'RUB',
      trialEndsAt: DateTime.tryParse(json['trial_ends_at']?.toString() ?? ''),
      shortUuid: json['short_uuid']?.toString(),
      subscriptionUrl: json['sub_url']?.toString(),
      pricePerDayKopecks: (priceRub * 100).round(),
      timezone: billing['timezone']?.toString() ?? 'Europe/Moscow',
      checkoutDiscountPercent: (billing['checkout_discount_percent'] as num?)?.toInt() ?? 0,
    );
  }

  double get balanceRub => balanceKopecks / 100;
  double get pricePerDayRub => pricePerDayKopecks / 100;
  bool get isActive => status == 'active';
  bool get isFrozen => status == 'frozen';
  bool get needsFunds => status == 'insufficient_funds';
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

  factory CheckoutProviderOption.fromJson(Map<String, dynamic> json) => CheckoutProviderOption(
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

  const RotatedSubscriptionLink({required this.subscriptionUrl, required this.shortUuid});

  factory RotatedSubscriptionLink.fromJson(Map<String, dynamic> json) {
    final url = Uri.tryParse(json['subscription_url']?.toString() ?? '');
    if (url == null || !url.hasScheme) {
      throw const FormatException('Account service returned an invalid subscription link.');
    }
    return RotatedSubscriptionLink(
      subscriptionUrl: url,
      shortUuid: json['short_uuid']?.toString() ?? '',
    );
  }
}
