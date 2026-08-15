/// One row of account payment history (T-19).
///
/// Amounts are parsed defensively: providers are inconsistent about whether a
/// money value arrives as a JSON number or a string, and a hard cast would
/// throw and blank the whole cabinet over one odd row.
class PaymentEntry {
  final String id;
  final String provider;
  final double amount;
  final String currency;
  final String status;
  final int days;
  final String description;
  final DateTime? createdAt;
  final DateTime? paidAt;

  const PaymentEntry({
    required this.id,
    this.provider = '',
    this.amount = 0,
    this.currency = '',
    this.status = '',
    this.days = 0,
    this.description = '',
    this.createdAt,
    this.paidAt,
  });

  /// True when the payment settled.
  bool get isPaid => status.toLowerCase() == 'paid';

  /// True while the payment is still in flight.
  bool get isPending => status.toLowerCase() == 'pending';

  /// True when the payment will never settle.
  bool get isFailed {
    final s = status.toLowerCase();
    return s == 'failed' || s == 'canceled' || s == 'cancelled';
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _toDate(dynamic v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  factory PaymentEntry.fromJson(Map<String, dynamic> j) => PaymentEntry(
        id: (j['id'] ?? '').toString(),
        provider: (j['provider'] ?? '').toString(),
        amount: _toDouble(j['amount']),
        currency: (j['currency'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        days: _toInt(j['days']),
        description: (j['description'] ?? '').toString(),
        createdAt: _toDate(j['created_at']),
        paidAt: _toDate(j['paid_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        'amount': amount,
        'currency': currency,
        'status': status,
        if (days != 0) 'days': days,
        if (description.isNotEmpty) 'description': description,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (paidAt != null) 'paid_at': paidAt!.toIso8601String(),
      };
}

/// Result of redeeming a pairing code.
class LinkResult {
  final bool ok;
  final int telegramId;
  final String username;

  const LinkResult({
    required this.ok,
    this.telegramId = 0,
    this.username = '',
  });

  factory LinkResult.fromJson(Map<String, dynamic> j) => LinkResult(
        ok: j['ok'] == true,
        telegramId: PaymentEntry._toInt(j['telegram_id']),
        username: (j['username'] ?? '').toString(),
      );
}

/// Why a pairing code was rejected.
///
/// Modelled explicitly so the UI can tell the user what to do next — "ask the
/// bot for a fresh code" is useful, "request failed" is not.
enum LinkCodeError {
  invalidFormat,
  notFound,
  expired,
  alreadyUsed,
  tooManyAttempts,
  network,
  unknown;

  /// Maps the daemon's HTTP status onto a cause.
  static LinkCodeError fromStatus(int? status) {
    switch (status) {
      case 400:
        return LinkCodeError.invalidFormat;
      case 404:
        return LinkCodeError.notFound;
      case 410:
        return LinkCodeError.expired;
      case 409:
        return LinkCodeError.alreadyUsed;
      case 429:
        return LinkCodeError.tooManyAttempts;
      case null:
        return LinkCodeError.network;
      default:
        return LinkCodeError.unknown;
    }
  }

  String get message {
    switch (this) {
      case LinkCodeError.invalidFormat:
        return 'Enter the complete 8-character code from the bot.';
      case LinkCodeError.notFound:
        return 'Code not recognised. Check the digits and try again.';
      case LinkCodeError.expired:
        return 'Code expired. Ask the bot for a new one.';
      case LinkCodeError.alreadyUsed:
        return 'Code already used. Ask the bot for a new one.';
      case LinkCodeError.tooManyAttempts:
        return 'Too many attempts. Ask the bot for a new code.';
      case LinkCodeError.network:
        return 'Could not reach the daemon.';
      case LinkCodeError.unknown:
        return 'Linking failed.';
    }
  }
}
