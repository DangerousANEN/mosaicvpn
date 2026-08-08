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
  }) : squadName = squadName ?? tag;

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
    final daysLeft = rawDays is num
        ? rawDays.toInt()
        : (rawDays != null ? int.tryParse(rawDays.toString()) ?? 0 : 0);

    final tagVal = (j['tag'] ?? j['squad_name'] ?? '').toString();
    final squadVal = (j['squad_name'] ?? j['tag'] ?? '').toString();

    DateTime? expireDate;
    if (j['expire_at'] != null && j['expire_at'].toString().isNotEmpty) {
      expireDate = DateTime.tryParse(j['expire_at'].toString());
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
    );
  }

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
