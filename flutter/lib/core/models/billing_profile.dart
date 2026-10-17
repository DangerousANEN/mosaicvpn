/// BillingProfile — billing and account profile for user's MosaicVPN account.
/// Matches Go: api.billingProfileResponse
class BillingProfile {
  final bool linked;
  final int telegramId;
  final String username;
  final String shortUuid;
  final String status;
  final String tag;
  final String squadName;
  final String email;
  final int trafficLimitBytes;
  final int usedTrafficBytes;
  final DateTime? expireAt;
  final int daysLeft;
  final String description;
  /// Daily price in RUB (1 RUB = 1 day by default). Used for the top-up card.
  final int pricePerDayRub;

  /// True when this profile was produced without a successful billing backend
  /// round-trip (offline cache, cold start without network, or a transient
  /// outage). Such a profile keeps the last-known entitlement so the UI can say
  /// "showing last known data" instead of inventing days or blocking the
  /// tunnel. It must never be read as a fresh authoritative balance.
  final bool stale;

  BillingProfile({
    this.linked = false,
    this.telegramId = 0,
    this.username = '',
    this.shortUuid = '',
    this.status = '',
    this.tag = '',
    String? squadName,
    this.email = '',
    this.trafficLimitBytes = 0,
    this.usedTrafficBytes = 0,
    this.expireAt,
    this.daysLeft = 0,
    this.description = '',
    this.pricePerDayRub = 1,
    this.stale = false,
  }) : squadName = squadName ?? tag;

  /// Whether access is actually over. A missing expiry date means "unknown",
  /// not "expired": only an explicit status or a date in the past closes the
  /// account. `daysLeft <= 0` alone is never sufficient here.
  bool get isExpired =>
      status.toLowerCase().contains('expired') ||
      status.toLowerCase().contains('insufficient') ||
      (expireAt != null && expireAt!.isBefore(DateTime.now()));

  factory BillingProfile.fromJson(Map<String, dynamic> j) {
    final rawTelegramId = j['telegram_id'];
    final telegramId = rawTelegramId is num
        ? rawTelegramId.toInt()
        : (rawTelegramId != null ? int.tryParse(rawTelegramId.toString()) ?? 0 : 0);

    final rawTrafficLimit = j['traffic_limit_bytes'];
    final trafficLimitBytes = rawTrafficLimit is num
        ? rawTrafficLimit.toInt()
        : (rawTrafficLimit != null ? int.tryParse(rawTrafficLimit.toString()) ?? 0 : 0);

    final rawUsedTraffic = j['used_traffic_bytes'];
    final usedTrafficBytes = rawUsedTraffic is num
        ? rawUsedTraffic.toInt()
        : (rawUsedTraffic != null ? int.tryParse(rawUsedTraffic.toString()) ?? 0 : 0);

    final rawDays = j['days_left'] ?? j['expire_days_remaining'];
    var daysLeft = rawDays is num
        ? rawDays.toInt()
        : (rawDays != null ? int.tryParse(rawDays.toString()) ?? 0 : 0);

    final tagVal = (j['tag'] ?? j['squad_name'] ?? '').toString();
    final squadVal = (j['squad_name'] ?? j['tag'] ?? '').toString();

    DateTime? expireDate;
    for (final key in const ['expire_at', 'expires_at', 'trial_ends_at']) {
      final raw = j[key];
      if (raw == null || raw.toString().isEmpty) continue;
      expireDate = DateTime.tryParse(raw.toString());
      if (expireDate != null) break;
    }

    if (daysLeft <= 0 && expireDate != null) {
      final diff = expireDate.difference(DateTime.now()).inSeconds;
      if (diff > 0) {
        daysLeft = (diff / 86400.0).ceil();
      }
    }

    return BillingProfile(
      linked: j['linked'] ?? false,
      telegramId: telegramId,
      username: (j['username'] ?? '').toString(),
      shortUuid: (j['short_uuid'] ?? '').toString(),
      status: (j['status'] ?? '').toString(),
      tag: tagVal,
      squadName: squadVal,
      email: (j['email'] ?? '').toString(),
      trafficLimitBytes: trafficLimitBytes,
      usedTrafficBytes: usedTrafficBytes,
      expireAt: expireDate,
      daysLeft: daysLeft,
      description: (j['description'] ?? '').toString(),
      pricePerDayRub: ((j['billing'] as Map?)?['price_per_day_rub'] as num?)?.toInt()
          ?? (j['price_per_day_rub'] as num?)?.toInt()
          ?? 1,
      stale: j['stale'] == true,
    );
  }

  /// Returns a copy flagged as last-known data. Used by offline fallbacks so the
  /// UI can be honest about freshness without inventing a day count.
  BillingProfile asStale() => BillingProfile(
        linked: linked,
        telegramId: telegramId,
        username: username,
        shortUuid: shortUuid,
        status: status,
        tag: tag,
        squadName: squadName,
        email: email,
        trafficLimitBytes: trafficLimitBytes,
        usedTrafficBytes: usedTrafficBytes,
        expireAt: expireAt,
        daysLeft: daysLeft,
        description: description,
        pricePerDayRub: pricePerDayRub,
        stale: true,
      );

  Map<String, dynamic> toJson() => {
        'linked': linked,
        'telegram_id': telegramId,
        'username': username,
        'short_uuid': shortUuid,
        'status': status,
        'tag': tag,
        'squad_name': squadName,
        'email': email,
        'traffic_limit_bytes': trafficLimitBytes,
        'used_traffic_bytes': usedTrafficBytes,
        'expire_at': expireAt?.toIso8601String() ?? '',
        'days_left': daysLeft,
        'expire_days_remaining': daysLeft,
        'description': description,
      };
}
