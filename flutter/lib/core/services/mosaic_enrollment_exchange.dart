import 'package:dio/dio.dart';

/// Verified, one-time website enrollment material returned by MosaicVPN.
///
/// The browser URI itself carries no long-lived credential. This payload is
/// produced only after the API atomically redeems the opaque code/state pair.
class MosaicWebsiteEnrollment {
  const MosaicWebsiteEnrollment({
    required this.subscriptionUrl,
    required this.subscriptionName,
    required this.providerId,
    required this.providerAccountId,
  });

  final String subscriptionUrl;
  final String subscriptionName;
  final String providerId;
  final String providerAccountId;
}

/// Platform-neutral callback validation and redemption for website enrollment.
/// Native platform launchers may receive arbitrary URI invocations, so the
/// source URI is allowlisted before its short-lived data reaches the API.
class MosaicEnrollmentExchange {
  MosaicEnrollmentExchange._();

  static const _baseUrl = 'https://sub.zxc1x1.ru';
  static final Dio _dio = Dio(BaseOptions(
    baseUrl: _baseUrl,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    headers: const {'Accept': 'application/json'},
  ));

  static bool isSupportedCallback(Uri uri) {
    final isVerifiedWebsiteCallback = uri.scheme == 'https' &&
        uri.host == 'sub.zxc1x1.ru' &&
        uri.path == '/enroll/callback';
    final isCustomSchemeFallback = uri.scheme == 'mosaicvpn' &&
        uri.host == 'enroll' &&
        uri.path == '/callback';
    return isVerifiedWebsiteCallback || isCustomSchemeFallback;
  }

  /// Canonical short-lived callback identity used by desktop callers to ignore
  /// duplicate URI deliveries. The server still enforces one-time redemption;
  /// this only prevents the same running app from redeeming an already accepted
  /// callback a second time and surfacing a misleading HTTP 409 to the user.
  static String? callbackDeliveryKey(Uri callback) {
    if (!isSupportedCallback(callback)) return null;
    final code = callback.queryParameters['code'] ?? '';
    final state = callback.queryParameters['state'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(code) ||
        !RegExp(r'^[A-Za-z0-9]{16,128}$').hasMatch(state)) {
      return null;
    }
    return '$code::$state';
  }

  static Future<MosaicWebsiteEnrollment> redeem(Uri callback) async {
    if (!isSupportedCallback(callback)) {
      throw const FormatException(
          'Получена неподдерживаемая ссылка добавления подписки.');
    }
    final key = callbackDeliveryKey(callback);
    if (key == null) {
      throw const FormatException(
          'Ссылка добавления неполная или уже недействительна. Повторите действие на сайте.');
    }
    final separator = key.lastIndexOf('::');
    final code = key.substring(0, separator);
    final state = key.substring(separator + 2);
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/app-auth/exchange',
      data: {'code': code, 'state': state},
    );
    final payload = Map<String, dynamic>.from(response.data ?? const {});
    if (payload['purpose']?.toString() != 'enroll') {
      throw const FormatException(
          'Сервис вернул неподходящий код добавления. Повторите действие на сайте.');
    }
    final subscriptionUrl =
        payload['subscription_url']?.toString().trim() ?? '';
    final subscriptionUri = Uri.tryParse(subscriptionUrl);
    if (subscriptionUri == null ||
        subscriptionUri.scheme != 'https' ||
        subscriptionUri.host != 'sub.zxc1x1.ru') {
      throw const FormatException(
          'Сервис не вернул корректную ссылку подписки.');
    }
    return MosaicWebsiteEnrollment(
      subscriptionUrl: subscriptionUrl,
      subscriptionName:
          payload['subscription_name']?.toString().trim().isNotEmpty == true
              ? payload['subscription_name'].toString().trim()
              : 'MosaicVPN',
      providerId: payload['provider_id']?.toString().trim() ?? 'mosaicvpn',
      providerAccountId:
          payload['provider_account_id']?.toString().trim() ?? '',
    );
  }
}
