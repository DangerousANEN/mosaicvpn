import 'dart:convert';

import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/billing_profile.dart';
import '../models/payment_entry.dart';
import '../models/provider_profile.dart';
import '../models/unified_account.dart';
import 'android_vpn_service.dart';

/// Device-local account material required by Android's native direct runtime.
class AndroidMosaicSession {
  const AndroidMosaicSession({
    required this.directToken,
    this.sessionToken,
    this.username,
    this.subscriptionUrl,
    this.providerId,
    this.providerAccountId,
    this.subscriptionName,
  });

  final String directToken;
  final String? sessionToken;
  final String? username;
  final String? subscriptionUrl;
  final String? providerId;
  final String? providerAccountId;
  final String? subscriptionName;

  Map<String, String> toSecureMap() => <String, String>{
        'direct_token': directToken,
        if (sessionToken?.isNotEmpty == true) 'session_token': sessionToken!,
        if (username?.isNotEmpty == true) 'username': username!,
        if (subscriptionUrl?.isNotEmpty == true)
          'subscription_url': subscriptionUrl!,
        if (providerId?.isNotEmpty == true) 'provider_id': providerId!,
        if (providerAccountId?.isNotEmpty == true)
          'provider_account_id': providerAccountId!,
        if (subscriptionName?.isNotEmpty == true)
          'subscription_name': subscriptionName!,
      };

  static AndroidMosaicSession? fromSecureMap(Map<String, dynamic> value) {
    final directToken = value['direct_token']?.toString() ?? '';
    if (directToken.isEmpty) return null;
    return AndroidMosaicSession(
      directToken: directToken,
      sessionToken: value['session_token']?.toString(),
      username: value['username']?.toString(),
      subscriptionUrl: value['subscription_url']?.toString(),
      providerId: value['provider_id']?.toString(),
      providerAccountId: value['provider_account_id']?.toString(),
      subscriptionName: value['subscription_name']?.toString(),
    );
  }
}

/// Account authority for Android, where a desktop loopback daemon does not
/// exist. The direct token is deliberately stored in Android Keystore-backed
/// secure storage rather than normal app preferences.
class AndroidMosaicAccountService {
  AndroidMosaicAccountService._();

  static final AndroidMosaicAccountService instance =
      AndroidMosaicAccountService._();

  static const _baseUrl = 'https://sub.zxc1x1.ru';
  static const _directTokenKey = 'mosaic_android_direct_token';
  static const _sessionTokenKey = 'mosaic_android_session_token';
  static const _usernameKey = 'mosaic_android_username';
  static const _appAuthStateKey = 'mosaic_android_app_auth_state';
  static const _cachedAccountKey = 'mosaic_android_cached_account.v1';
  static const _cachedManifestKey = 'mosaic_android_cached_manifest.v1';
  // Secure JSON map: local subscription ID -> AndroidMosaicSession fields.
  // A binding grants optional cabinet access only; VPN connection continues
  // through the subscription URL and never reads this map.
  static const _subscriptionBindingsKey =
      'mosaic_android_subscription_cabinet_bindings.v1';
  static const _pairingAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  final Dio _dio = Dio(BaseOptions(
    baseUrl: _baseUrl,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    headers: const {'Accept': 'application/json'},
  ));
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<UnifiedAccount?> readCachedUnifiedAccount() async {
    final raw = (await _prefs).getString(_cachedAccountKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return UnifiedAccount.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      await (await _prefs).remove(_cachedAccountKey);
      return null;
    }
  }

  Future<void> _cacheUnifiedAccount(UnifiedAccount account) async {
    // Cache contains display metadata only; credentials remain in Keystore.
    await (await _prefs).setString(
        _cachedAccountKey,
        jsonEncode({
          'account_id': account.accountId,
          'status': account.status,
          'tier': account.tier,
          'balance_kopecks': account.balanceKopecks,
          'currency': account.currency,
          'trial_ends_at': account.trialEndsAt?.toIso8601String(),
          'expires_at': account.expiresAt?.toIso8601String(),
          'next_charge_estimate_at':
              account.nextChargeEstimateAt?.toIso8601String(),
          'short_uuid': account.shortUuid,
          'sub_url': account.subscriptionUrl,
          'billing': {
            'price_per_day_rub': account.pricePerDayRub,
            'timezone': account.timezone,
            'checkout_discount_percent': account.checkoutDiscountPercent,
          },
          'days_left': account.daysLeft,
          'traffic_used_bytes': account.trafficUsedBytes,
          'traffic_limit_bytes': account.trafficLimitBytes,
          'lifetime_traffic_bytes': account.lifetimeTrafficBytes,
          'device_limit': account.deviceLimit,
        }));
  }

  Future<void> _cacheProviderManifest(Map<String, dynamic> payload) async {
    await (await _prefs).setString(_cachedManifestKey, jsonEncode(payload));
  }

  Future<ProviderManifest?> readCachedProviderManifest() async {
    final raw = (await _prefs).getString(_cachedManifestKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ProviderManifest.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      await (await _prefs).remove(_cachedManifestKey);
      return null;
    }
  }

  Future<AndroidMosaicSession?> restoreSession() async {
    final directToken = await _secureStorage.read(key: _directTokenKey);
    if (directToken == null || directToken.isEmpty) return null;
    return AndroidMosaicSession(
      directToken: directToken,
      sessionToken: await _secureStorage.read(key: _sessionTokenKey),
      username: await _secureStorage.read(key: _usernameKey),
    );
  }

  Future<Map<String, AndroidMosaicSession>> _readSubscriptionBindings() async {
    final raw = await _secureStorage.read(key: _subscriptionBindingsKey);
    if (raw == null || raw.isEmpty) return <String, AndroidMosaicSession>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, AndroidMosaicSession>{};
      final bindings = <String, AndroidMosaicSession>{};
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final session = AndroidMosaicSession.fromSecureMap(
          Map<String, dynamic>.from(value),
        );
        if (session != null) bindings[key] = session;
      });
      return bindings;
    } on FormatException {
      return <String, AndroidMosaicSession>{};
    }
  }

  Future<void> _writeSubscriptionBindings(
    Map<String, AndroidMosaicSession> bindings,
  ) =>
      _secureStorage.write(
        key: _subscriptionBindingsKey,
        value: jsonEncode(bindings.map(
          (key, value) => MapEntry(key, value.toSecureMap()),
        )),
      );

  Future<AndroidMosaicSession?> restoreBinding(String subscriptionID) async {
    if (subscriptionID.trim().isEmpty) return null;
    return (await _readSubscriptionBindings())[subscriptionID];
  }

  Future<bool> hasBinding(String subscriptionID) async =>
      (await restoreBinding(subscriptionID)) != null;

  Future<void> saveBinding(
    String subscriptionID,
    AndroidMosaicSession session,
  ) async {
    if (subscriptionID.trim().isEmpty) {
      throw const FormatException(
          'Не удалось определить подписку для кабинета.');
    }
    final bindings = await _readSubscriptionBindings();
    bindings[subscriptionID] = session;
    await _writeSubscriptionBindings(bindings);
  }

  Future<void> clearBinding(String subscriptionID) async {
    final bindings = await _readSubscriptionBindings();
    if (bindings.remove(subscriptionID) != null) {
      await _writeSubscriptionBindings(bindings);
    }
  }

  Future<AndroidMosaicSession> redeemTelegramCode(String rawCode) async {
    final payload = await _redeemPairingCodePayload(rawCode);
    return _savePayload(payload, directKey: 'direct_token');
  }

  /// Attaches a one-time website or Telegram code to the exact URL source that
  /// the user opened. The code is burned by the server before this method gets a
  /// response; a mismatch therefore cannot accidentally attach one account's
  /// cabinet to another account's subscription.
  Future<AndroidMosaicSession> attachCabinetCode({
    required String subscriptionID,
    required String subscriptionUrl,
    required String rawCode,
  }) async {
    final payload = await _redeemPairingCodePayload(rawCode);
    final session = _sessionFromPayload(payload, directKey: 'direct_token');
    final returnedUrl = session.subscriptionUrl?.trim() ?? '';
    if (!_sameMosaicSubscriptionUrl(subscriptionUrl, returnedUrl)) {
      throw StateError(
        'Этот код относится к другой подписке. Откройте нужную подписку и запросите новый код.',
      );
    }
    await saveBinding(
      subscriptionID,
      AndroidMosaicSession(
        directToken: session.directToken,
        sessionToken: session.sessionToken,
        username: session.username,
        subscriptionUrl: subscriptionUrl.trim(),
        providerId: session.providerId ?? 'mosaicvpn',
        providerAccountId: session.providerAccountId,
        subscriptionName: session.subscriptionName,
      ),
    );
    return session;
  }

  Future<Map<String, dynamic>> _redeemPairingCodePayload(String rawCode) async {
    final code = normalizePairingCode(rawCode);
    if (code.length != 8) {
      throw const FormatException('Введите все 8 символов одноразового кода.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/link/redeem',
      data: {'code': code},
    );
    return Map<String, dynamic>.from(response.data ?? const {});
  }

  /// Compares opaque subscription identities while tolerating a cosmetic
  /// trailing slash. Dart represents `/ABC/` as `['ABC', '']`; using
  /// `pathSegments.last` directly would reject an otherwise identical URL
  /// returned canonically by the server after the one-time code is redeemed.
  static bool sameSubscriptionUrlForTesting(String left, String right) {
    final leftUri = Uri.tryParse(left.trim());
    final rightUri = Uri.tryParse(right.trim());
    if (leftUri == null || rightUri == null) return false;
    final leftSegments = leftUri.pathSegments.where((s) => s.isNotEmpty);
    final rightSegments = rightUri.pathSegments.where((s) => s.isNotEmpty);
    final leftIdentity = leftSegments.isEmpty ? null : leftSegments.last;
    final rightIdentity = rightSegments.isEmpty ? null : rightSegments.last;
    return leftUri.isScheme('https') &&
        rightUri.isScheme('https') &&
        leftUri.host.toLowerCase() == rightUri.host.toLowerCase() &&
        leftIdentity != null &&
        rightIdentity != null &&
        leftIdentity == rightIdentity;
  }

  bool _sameMosaicSubscriptionUrl(String left, String right) =>
      sameSubscriptionUrlForTesting(left, right);

  Future<AndroidMosaicSession> loginWithEmail(
      String email, String password) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/auth/login',
      data: {'email': email.trim(), 'password': password},
    );
    final payload = Map<String, dynamic>.from(response.data ?? const {});
    return _savePayload(payload, directKey: 'client_token');
  }

  Future<void> clearSession() async {
    await _secureStorage.delete(key: _directTokenKey);
    await _secureStorage.delete(key: _sessionTokenKey);
    await _secureStorage.delete(key: _usernameKey);
    await _secureStorage.delete(key: _appAuthStateKey);
    await _secureStorage.delete(key: _subscriptionBindingsKey);
  }

  /// Creates the website URL for primary sign-in. Existing cabinet sessions
  /// complete immediately; otherwise the website asks the user to authenticate
  /// there, then returns a code to the app through the registered deep link.
  Future<Uri> beginWebsiteLogin() async {
    final state = _randomState();
    await _secureStorage.write(key: _appAuthStateKey, value: state);
    return Uri.parse('$_baseUrl/cabinet.html').replace(queryParameters: {
      'return_to': 'mosaicvpn://auth/callback',
      'state': state,
    });
  }

  /// Consumes a one-time browser callback and stores fresh account material.
  /// State is verified locally and server-side before the code is exchanged.
  Future<AndroidMosaicSession?> completeWebsiteLoginIfPresent() async {
    final callback = await AndroidVpnService.instance.consumeAuthCallback();
    if (callback == null) return null;
    final code = callback.queryParameters['code'] ?? '';
    final state = callback.queryParameters['state'] ?? '';
    final expected = await _secureStorage.read(key: _appAuthStateKey) ?? '';
    await _secureStorage.delete(key: _appAuthStateKey);
    if (code.isEmpty ||
        state.isEmpty ||
        expected.isEmpty ||
        state != expected) {
      throw const FormatException(
          'Не удалось подтвердить вход через сайт. Повторите попытку.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/app-auth/exchange',
      data: {'code': code, 'state': state},
    );
    return _savePayload(
      Map<String, dynamic>.from(response.data ?? const {}),
      directKey: 'direct_token',
    );
  }

  /// Exchanges a browser-issued Add-to-app callback. The website owns this
  /// explicit enrollment gesture; the server still validates code/state,
  /// expiry, single-use and purpose before issuing any account material.
  Future<AndroidMosaicSession?> completeEnrollmentIfPresent() async {
    final callback =
        await AndroidVpnService.instance.consumeEnrollmentCallback();
    if (callback == null) return null;
    return completeEnrollmentCallback(callback);
  }

  /// Redeems a verified website or explicit fallback enrollment callback on any
  /// Flutter platform and persists the resulting hosted cabinet session in the
  /// platform secure store. Despite its historical name, this service is also
  /// the shared Mosaic account authority for desktop browser enrollment.
  Future<AndroidMosaicSession> completeEnrollmentCallback(Uri callback) async {
    final isVerifiedWebsiteCallback = callback.scheme == 'https' &&
        callback.host == 'sub.zxc1x1.ru' &&
        callback.path == '/enroll/callback';
    final isCustomSchemeFallback = callback.scheme == 'mosaicvpn' &&
        callback.host == 'enroll' &&
        callback.path == '/callback';
    if (!isVerifiedWebsiteCallback && !isCustomSchemeFallback) {
      throw const FormatException(
          'Получена неподдерживаемая ссылка добавления подписки.');
    }
    final code = callback.queryParameters['code'] ?? '';
    final state = callback.queryParameters['state'] ?? '';
    if (code.isEmpty || state.isEmpty) {
      throw const FormatException(
          'Не удалось подтвердить добавление подписки в приложение.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/app-auth/exchange',
      data: {'code': code, 'state': state},
    );
    final payload = Map<String, dynamic>.from(response.data ?? const {});
    if (payload['purpose']?.toString() != 'enroll') {
      throw const FormatException(
          'Сервис вернул неподходящий код добавления. Повторите действие на сайте.');
    }
    return _savePayload(payload, directKey: 'direct_token');
  }

  String _randomState() {
    final random = Random.secure();
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List<String>.generate(
      48,
      (_) => alphabet[random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }

  Future<String> _sessionToken({String? subscriptionID}) async {
    final session = subscriptionID?.trim().isNotEmpty == true
        ? await restoreBinding(subscriptionID!)
        : await restoreSession();
    final token = session?.sessionToken;
    if (token == null || token.isEmpty) {
      throw StateError(subscriptionID?.trim().isNotEmpty == true
          ? 'Сначала подключите кабинет этой подписки.'
          : 'Сначала войдите через сайт или Telegram.');
    }
    return token;
  }

  Future<Map<String, dynamic>> _getAccountJson(
    String path, {
    String? subscriptionID,
  }) async {
    final token = await _sessionToken(subscriptionID: subscriptionID);
    final response = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: {'token': token},
    );
    return Map<String, dynamic>.from(response.data ?? const {});
  }

  Future<Map<String, dynamic>> _postAccountJson(
    String path, {
    Map<String, dynamic>? data,
    String? subscriptionID,
  }) async {
    final token = await _sessionToken(subscriptionID: subscriptionID);
    final response = await _dio.post<Map<String, dynamic>>(
      path,
      data: <String, dynamic>{'token': token, ...?data},
    );
    return Map<String, dynamic>.from(response.data ?? const {});
  }

  /// Reads safe subscription metadata without requiring a browser session.
  /// This is limited to the holder of an existing MosaicVPN subscription URL;
  /// it never grants balance, payment, device or account-control access.
  Future<SubscriptionBaseProfile> getSubscriptionBaseProfile(
    String subscriptionUrl,
  ) async {
    final uri = Uri.tryParse(subscriptionUrl.trim());
    if (uri == null ||
        !uri.isScheme('https') ||
        uri.host.toLowerCase() != Uri.parse(_baseUrl).host ||
        uri.pathSegments.isEmpty) {
      throw const FormatException('Не удалось определить ссылку MosaicVPN.');
    }
    final opaqueID = uri.pathSegments.last;
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/subscription/profile/${Uri.encodeComponent(opaqueID)}',
    );
    final payload = Map<String, dynamic>.from(response.data ?? const {});
    final raw = payload['profile'];
    if (raw is! Map) {
      throw StateError('Сервис не вернул базовый профиль подписки.');
    }
    return SubscriptionBaseProfile.fromJson(
      Map<String, dynamic>.from(raw),
    );
  }

  Future<UnifiedAccount?> getUnifiedAccount({String? subscriptionID}) async {
    final session = subscriptionID?.trim().isNotEmpty == true
        ? await restoreBinding(subscriptionID!)
        : await restoreSession();
    if (session == null) return null;
    try {
      final payload = await _getAccountJson(
        '/api/billing/profile',
        subscriptionID: subscriptionID,
      );
      if (payload['linked'] == false) return null;
      final account = UnifiedAccount.fromJson(payload['account'] is Map
          ? Map<String, dynamic>.from(payload['account'] as Map)
          : payload);
      await _cacheUnifiedAccount(account);
      return account;
    } on DioException {
      // Offline mode may show the last verified display snapshot, never tokens.
      return readCachedUnifiedAccount();
    }
  }

  Future<UnifiedAccount> setFrozen(
    bool frozen, {
    String? subscriptionID,
  }) async {
    final payload = await _postAccountJson(
      frozen ? '/api/account/freeze' : '/api/account/unfreeze',
      subscriptionID: subscriptionID,
    );
    return UnifiedAccount.fromJson(payload['account'] is Map
        ? Map<String, dynamic>.from(payload['account'] as Map)
        : payload);
  }

  Future<List<CheckoutProviderOption>> getCheckoutOptions({
    String? subscriptionID,
  }) async {
    final payload = await _getAccountJson(
      '/api/checkout/options',
      subscriptionID: subscriptionID,
    );
    final raw = payload['providers'];
    if (raw is! List) return const <CheckoutProviderOption>[];
    return raw
        .whereType<Map>()
        .map((value) =>
            CheckoutProviderOption.fromJson(Map<String, dynamic>.from(value)))
        .toList(growable: false);
  }

  Future<CheckoutSession> createCheckout({
    required int amountRub,
    required String provider,
    String? subscriptionID,
  }) async {
    final payload = await _postAccountJson(
      '/api/checkout/create',
      subscriptionID: subscriptionID,
      data: {
        'amount_rub': amountRub,
        'provider': provider,
      },
    );
    return CheckoutSession.fromJson(payload);
  }

  Future<RotatedSubscriptionLink> rotateSubscriptionLink({
    String? subscriptionID,
  }) async {
    final payload = await _postAccountJson(
      '/api/subscription/link/rotate',
      subscriptionID: subscriptionID,
    );
    return RotatedSubscriptionLink.fromJson(payload);
  }

  /// Downloads the per-device direct subscription and returns a full native
  /// sing-box configuration with one Android TUN inbound. Traffic egresses
  /// directly from the device to the selected provider node.
  /// Fetches the public capability manifest used by the direct client.
  ///
  /// It contains route metadata only, never a physical node pool, source URLs,
  /// or account information. Android resolves the selected group locally from
  /// the authenticated opaque direct feed.
  Future<ProviderManifest> getProviderManifest({String? subscriptionId}) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/manifest.json',
        queryParameters:
            subscriptionId == null ? null : {'subscription_id': subscriptionId},
      );
      final payload = Map<String, dynamic>.from(response.data ?? const {});
      if (payload.isEmpty) {
        throw StateError('Сервис не вернул список маршрутов.');
      }
      await _cacheProviderManifest(payload);
      return ProviderManifest.fromJson(payload);
    } on DioException {
      final cached = await readCachedProviderManifest();
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Returns the Android account cabinet through the hosted authority. A brief
  /// billing-sync outage must never make an already-linked device look signed
  /// out, so the persisted device session is used as a safe fallback.
  Future<BillingProfile> getBillingProfile() async {
    final session = await restoreSession();
    if (session == null) return BillingProfile();

    final local = BillingProfile(
      linked: true,
      username: session.username ?? '',
      email: session.username?.contains('@') == true ? session.username! : '',
      status: 'active',
      description: 'This Android device is linked to a MosaicVPN profile.',
    );
    final token = session.sessionToken;
    if (token == null || token.isEmpty) return local;

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/billing/profile',
        queryParameters: {'token': token},
      );
      final payload = Map<String, dynamic>.from(response.data ?? const {});
      final rawTrialEndsAt = payload['trial_ends_at']?.toString();
      final trialEndsAt =
          rawTrialEndsAt == null ? null : DateTime.tryParse(rawTrialEndsAt);
      final now = DateTime.now();
      final daysLeft = trialEndsAt == null
          ? 0
          : trialEndsAt
              .difference(DateTime(now.year, now.month, now.day))
              .inDays
              .clamp(0, 9999);
      return BillingProfile(
        linked: true,
        username: session.username ?? '',
        email: session.username?.contains('@') == true ? session.username! : '',
        shortUuid: payload['short_uuid']?.toString() ?? '',
        status: payload['status']?.toString() ?? 'active',
        tag: payload['tier']?.toString() ?? '',
        expireAt: trialEndsAt,
        daysLeft: daysLeft,
        description: 'MosaicVPN direct profile on this Android device.',
      );
    } on DioException {
      // A server-side billing refresh is not a reason to block VPN access or
      // turn the cabinet into an opaque Dio error. The next refresh retries.
      return local;
    }
  }

  /// Returns hosted payment history for the linked account. Billing outages
  /// must not turn the entire Android cabinet into a VPN-runtime error.
  Future<List<PaymentEntry>> getPaymentHistory({String? subscriptionID}) async {
    final session = subscriptionID?.trim().isNotEmpty == true
        ? await restoreBinding(subscriptionID!)
        : await restoreSession();
    final token = session?.sessionToken;
    if (token == null || token.isEmpty) return const <PaymentEntry>[];
    try {
      final response = await _dio.get<Object>(
        '/api/billing/payments',
        queryParameters: {'token': token},
      );
      final raw = response.data;
      final list = raw is List
          ? raw
          : raw is Map && raw['payments'] is List
              ? raw['payments'] as List
              : const <dynamic>[];
      return list
          .whereType<Map>()
          .map((value) =>
              PaymentEntry.fromJson(Map<String, dynamic>.from(value)))
          .toList(growable: false);
    } on DioException {
      return const <PaymentEntry>[];
    }
  }

  /// Fetches a user-provided subscription and returns its share URI rows.
  /// Parsing is deliberately local; no imported credentials are forwarded to
  /// the Mosaic VPS. Unsupported rows are returned for UI visibility but are
  /// rejected with a precise message at connection time.
  Future<List<String>> fetchSubscriptionShareUris(String url) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || !parsed.hasScheme || !parsed.isScheme('https')) {
      throw const FormatException('Укажите корректный HTTPS URL подписки.');
    }
    final response = await _dio.getUri<Object>(
      parsed,
      options: Options(responseType: ResponseType.plain),
    );
    final payload = response.data?.toString().trim() ?? '';
    if (payload.isEmpty) {
      throw const FormatException('Подписка не содержит серверов.');
    }
    final decoded = _decodeSubscriptionPayload(payload);
    return decoded
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.contains('://'))
        .toList(growable: false);
  }

  /// Builds a native Android TUN configuration from an ordinary HTTPS
  /// subscription URL. A subscription is sufficient for connection; cabinet
  /// authentication is an optional account capability and must never gate the
  /// route parser or the VPN runtime.
  Future<String> buildNativeTunConfigFromSubscriptionUrl(
    String subscriptionUrl, {
    String? groupId,
    List<String> bypassPackages = const [],
    List<String> proxyPackages = const [],
  }) async {
    final uri = Uri.tryParse(subscriptionUrl.trim());
    if (uri == null || !uri.hasScheme || !uri.isScheme('https')) {
      throw const FormatException('Укажите корректный HTTPS URL подписки.');
    }
    final response = await _dio.getUri<Object>(
      uri,
      options: Options(responseType: ResponseType.plain),
    );
    final data = response.data;
    // A JSON feed decoded by dio (Map/List) must never be stringified into a
    // fake share-URI line; re-encode it so the JSON branch below parses it.
    final String payload;
    if (data is Map || data is List) {
      payload = jsonEncode(data);
    } else {
      payload = data?.toString().trim() ?? '';
    }
    if (payload.isEmpty) {
      throw StateError(
          'Подписка не вернула конфигурацию для этого устройства.');
    }
    return buildNativeTunConfigFromSubscriptionPayload(payload,
        groupId: groupId,
        bypassPackages: bypassPackages,
        proxyPackages: proxyPackages);
  }

  /// Smart Groups never parse the ordinary direct subscription row. The
  /// selected route resolves from a separate capability-scoped candidate feed,
  /// so the private candidates remain hidden from the subscription UI.
  Future<String> buildNativeTunConfigFromScopedCandidates(
    String subscriptionUrl, {
    required String groupId,
    List<String> bypassPackages = const [],
    List<String> proxyPackages = const [],
  }) async {
    final outbounds =
        await fetchGroupCandidates(subscriptionUrl, groupId: groupId);
    if (outbounds.isEmpty) {
      throw StateError(
          'Сервис не вернул кандидатов для выбранной Smart Group.');
    }
    return _buildTunConfig(
      outbounds,
      bypassPackages: bypassPackages,
      proxyPackages: proxyPackages,
    );
  }

  /// Fetches the candidate feed of [subscriptionUrl] and returns the outbound
  /// entries belonging to [groupId] (normalized `mosaic_group_ids` matching).
  /// Shared by the TUN config builder and the Android latency-test facade so
  /// both always agree on what a Smart Group contains.
  Future<List<Map<String, dynamic>>> fetchGroupCandidates(
    String subscriptionUrl, {
    required String groupId,
  }) async {
    final uri = Uri.tryParse(subscriptionUrl.trim());
    if (uri == null || !uri.isScheme('https') || uri.pathSegments.length != 1) {
      throw const FormatException('Не удалось определить ссылку MosaicVPN.');
    }
    final candidateUri = uri.replace(
      path:
          '/api/client-candidates/${Uri.encodeComponent(uri.pathSegments.single)}',
      query: null,
    );
    final response = await _dio.getUri<Object>(
      candidateUri,
      options: Options(responseType: ResponseType.plain),
    );
    final data = response.data;
    // The feed is a sing-box style JSON document. Depending on the announced
    // content-type dio may hand over a String or an already decoded Map; only
    // primitives are stringified so a Map survives as structured data.
    final String payload;
    if (data is Map || data is List) {
      payload = jsonEncode(data);
    } else {
      payload = data?.toString().trim() ?? '';
    }
    if (payload.isEmpty) {
      return const [];
    }
    final decodedConfig = _decodeCandidateDocument(payload);
    final rawOutbounds = decodedConfig?['outbounds'];
    if (rawOutbounds is! List) return const [];
    String normalize(String value) => value.toLowerCase().replaceAll('_', '-');
    final wanted = normalize(groupId);
    final hasMembershipMetadata = <bool>[];
    final members = <Map<String, dynamic>>[];
    for (final value in rawOutbounds) {
      if (value is! Map) continue;
      final outbound = Map<String, dynamic>.from(value);
      final rawGroupIDs = outbound.remove('mosaic_group_ids') ??
          outbound.remove('mosaic_candidate_groups');
      final groupIDs = rawGroupIDs is List
          ? rawGroupIDs.map((value) => value.toString()).toSet()
          : <String>{};
      outbound.removeWhere((key, _) => key.toString().startsWith('mosaic_'));
      final tag = outbound['tag']?.toString() ?? '';
      final type = outbound['type']?.toString() ?? '';
      if (tag.isEmpty ||
          type.isEmpty ||
          type == 'direct' ||
          type == 'block' ||
          type == 'dns' ||
          type == 'urltest' ||
          type == 'selector') {
        continue;
      }
      final matches = groupIDs.any((id) => normalize(id) == wanted);
      hasMembershipMetadata.add(groupIDs.isNotEmpty);
      if (matches) members.add(outbound);
    }
    // Compatibility with older Remnawave feeds that cannot carry custom
    // membership metadata: every usable outbound becomes a group candidate.
    if (members.isEmpty && !hasMembershipMetadata.any((value) => value)) {
      return rawOutbounds
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .where((outbound) =>
              (outbound['tag']?.toString().isNotEmpty == true) &&
              !const ['direct', 'block', 'dns', 'urltest', 'selector']
                  .contains(outbound['type']?.toString()))
          .toList(growable: false);
    }
    return members;
  }

  /// Decodes a candidate document: raw sing-box JSON or base64 share lines
  /// wrapped into a synthetic config. Returns null when nothing parses.
  static Map<String, dynamic>? _decodeCandidateDocument(String payload) {
    final compact = payload.trim();
    if (compact.startsWith('{')) {
      try {
        final decoded = jsonDecode(compact);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on FormatException {
        return null;
      }
    }
    try {
      final normalized =
          base64.normalize(compact.replaceAll(RegExp(r'\s+'), ''));
      final text = utf8.decode(base64Decode(normalized), allowMalformed: false);
      if (text.trim().startsWith('{')) {
        final decoded = jsonDecode(text);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // Not a base64 JSON document; treat as unsupported legacy feed.
    }
    return null;
  }

  /// Downloads the authenticated opaque feed only for the legacy account
  /// fallback. New URL-backed subscriptions use
  /// [buildNativeTunConfigFromSubscriptionUrl] and connect without a cabinet
  /// login.
  Future<String> buildNativeTunConfig({String? groupId}) async {
    final session = await restoreSession();
    if (session == null) {
      throw StateError(
          'Добавьте или обновите подписку MosaicVPN, затем повторите подключение.');
    }
    return buildNativeTunConfigFromSubscriptionUrl(
      'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}',
      groupId: groupId,
    );
  }

  static String normalizePairingCode(String raw) {
    final normalized = StringBuffer();
    for (final unit in raw.toUpperCase().codeUnits) {
      final symbol = String.fromCharCode(unit);
      if (_pairingAlphabet.contains(symbol)) normalized.write(symbol);
    }
    return normalized.toString();
  }

  AndroidMosaicSession _sessionFromPayload(
    Map<String, dynamic> payload, {
    required String directKey,
  }) {
    final directToken = payload[directKey]?.toString() ?? '';
    if (directToken.isEmpty) {
      throw StateError('Сервис не выдал токен конфигурации для устройства.');
    }
    return AndroidMosaicSession(
      directToken: directToken,
      sessionToken:
          payload['session_token']?.toString() ?? payload['token']?.toString(),
      username: payload['username']?.toString() ?? payload['email']?.toString(),
      subscriptionUrl: payload['subscription_url']?.toString(),
      providerId: payload['provider_id']?.toString(),
      providerAccountId: payload['provider_account_id']?.toString(),
      subscriptionName: payload['subscription_name']?.toString(),
    );
  }

  Future<AndroidMosaicSession> _savePayload(
    Map<String, dynamic> payload, {
    required String directKey,
  }) async {
    final session = _sessionFromPayload(payload, directKey: directKey);
    await _secureStorage.write(
        key: _directTokenKey, value: session.directToken);
    if (session.sessionToken?.isNotEmpty == true) {
      await _secureStorage.write(
          key: _sessionTokenKey, value: session.sessionToken);
    }
    if (session.username?.isNotEmpty == true) {
      await _secureStorage.write(key: _usernameKey, value: session.username);
    }
    return session;
  }

  /// Builds a TUN config from a single user-imported share URI. This path is
  /// used only for local/user subscriptions; Mosaic direct routes retain the
  /// generic automatic selection and never reveal private pool members.
  static String buildNativeTunConfigFromShareUri(
    String shareUri, {
    List<String> bypassPackages = const [],
    List<String> proxyPackages = const [],
  }) {
    final outbound = _outboundFromShareUri(shareUri);
    if (outbound == null) {
      throw const FormatException(
          'Транспорт XHTTP (Xray) не поддерживается этим клиентом. '
          'Выберите сервер с поддерживаемым транспортом (ws/grpc/reality).');
    }
    return _buildTunConfig(
      <Map<String, dynamic>>[outbound],
      bypassPackages: bypassPackages,
      proxyPackages: proxyPackages,
    );
  }

  /// Converts a downloaded subscription payload into a complete native TUN
  /// configuration. This is public for the Android hosted facade, which owns
  /// the selected local subscription and must not depend on a cabinet session.
  static String buildNativeTunConfigFromSubscriptionPayload(
    String payload, {
    String? groupId,
    List<String> bypassPackages = const [],
    List<String> proxyPackages = const [],
  }) =>
      _withAndroidTunInbound(
        payload,
        groupId: groupId,
        bypassPackages: bypassPackages,
        proxyPackages: proxyPackages,
      );

  static String _withAndroidTunInbound(
    String payload, {
    String? groupId,
    List<String> bypassPackages = const [],
    List<String> proxyPackages = const [],
  }) {
    final normalized = _decodeSubscriptionPayload(payload);
    Map<String, dynamic>? config;
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map) config = Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Standard subscription feeds are base64-encoded share URI lines.
    }
    if (config == null) {
      final outbounds = normalized
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .map(_outboundFromShareUri)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      if (outbounds.isEmpty) {
        throw const FormatException(
            'Подписка не содержит поддерживаемых серверов.');
      }
      return _buildTunConfig(
        outbounds,
        bypassPackages: bypassPackages,
        proxyPackages: proxyPackages,
      );
    }
    final rawOutbounds = config['outbounds'];
    if (rawOutbounds is! List || rawOutbounds.isEmpty) {
      throw const FormatException('Direct configuration has no outbounds.');
    }

    final candidates = <Map<String, dynamic>>[];
    for (final value in rawOutbounds) {
      if (value is! Map) continue;
      final outbound = Map<String, dynamic>.from(value);
      // `mosaic_*` values are feed-selection hints, not a sing-box schema.
      // Remove them before handing the config to libbox.
      // The provider sends generic group memberships as `mosaic_group_ids`.
      // The Android client must not infer membership from hard-coded Mosaic IDs
      // or country/special-purpose hints.
      final rawGroupIDs = outbound.remove('mosaic_group_ids') ??
          outbound.remove('mosaic_candidate_groups');
      final groupIDs = rawGroupIDs is List
          ? rawGroupIDs.map((value) => value.toString()).toSet()
          : <String>{};
      outbound.removeWhere((key, _) => key.toString().startsWith('mosaic_'));
      _normalizeAndroidTransport(outbound);
      // Outbounds marked by the normalizer speak a wire protocol libbox cannot
      // serve (Xray XHTTP). Dropping them keeps the TUN config valid instead of
      // producing routes that connect but never carry traffic.
      if (outbound.containsKey('_mosaic_unsupported_transport')) {
        continue;
      }
      final tag = outbound['tag']?.toString() ?? '';
      final type = outbound['type']?.toString() ?? '';
      if (tag.isEmpty ||
          type.isEmpty ||
          type == 'direct' ||
          type == 'block' ||
          type == 'dns') {
        continue;
      }
      outbound['_mosaic_group_ids'] = groupIDs;
      candidates.add(outbound);
    }
    if (candidates.isEmpty) {
      throw const FormatException(
          'Direct configuration has no usable outbounds.');
    }

    bool matchesGroup(Map<String, dynamic> outbound) {
      // The hosted fallback manifest is unavailable on older deployments. Its
      // generic automatic route is intentionally the complete authenticated
      // direct feed, not a named/hidden private pool category.
      if (groupId == null ||
          groupId.isEmpty ||
          groupId == 'android-direct-auto') {
        return true;
      }
      final memberships = outbound['_mosaic_group_ids'];
      if (memberships is! Set<String>) return false;
      // The collector publishes snake_case ids (`min_latency`, `max_speed`)
      // while the manifest uses hyphenated ids (`min-latency`, `max-speed`);
      // compare on a normalized form so both spellings match.
      String normalize(String value) =>
          value.toLowerCase().replaceAll('_', '-');
      final wanted = normalize(groupId);
      return memberships.any((id) => normalize(id) == wanted);
    }

    final hasMembershipMetadata = candidates.any((outbound) {
      final memberships = outbound['_mosaic_group_ids'];
      return memberships is Set<String> && memberships.isNotEmpty;
    });
    var selected = candidates.where(matchesGroup).toList();
    // Older Remnawave feeds contain only standard share URI rows. Their
    // provider manifest still declares legitimate selection policies, but the
    // feed cannot carry custom `mosaic_group_ids`. In that compatibility mode,
    // apply the requested Smart Group policy to the authenticated opaque set
    // instead of failing every route. When membership metadata exists, it
    // remains authoritative and we never broaden the selected candidate set.
    if (selected.isEmpty &&
        !hasMembershipMetadata &&
        groupId != null &&
        groupId.isNotEmpty) {
      selected = List<Map<String, dynamic>>.from(candidates);
    }
    if (selected.isEmpty) {
      if (groupId != null && groupId.isNotEmpty) {
        throw StateError(
            'Профиль не содержит серверных данных для выбранного маршрута. Обновите подписку.');
      }
      throw const FormatException('Direct configuration has no usable routes.');
    }
    final tags = <String>[];
    final cleanOutbounds = <Map<String, dynamic>>[];
    for (final outbound in selected) {
      final clean = Map<String, dynamic>.from(outbound)
        ..removeWhere((key, _) => key.toString().startsWith('_mosaic_'));
      tags.add(clean['tag'] as String);
      cleanOutbounds.add(clean);
    }

    return _buildTunConfig(
      cleanOutbounds,
      existingConfig: config,
      bypassPackages: bypassPackages,
      proxyPackages: proxyPackages,
    );
  }

  /// Marks outbounds whose transport this runtime cannot speak. Xray's XHTTP
  /// is a distinct wire protocol: relabelling it as sing-box `http` yields a
  /// config that connects but never carries data. The caller removes marked
  /// entries so the feed only offers usable routes.
  static void _normalizeAndroidTransport(Map<String, dynamic> outbound) {
    final value = outbound['transport'];
    if (value is! Map) return;
    final transport = Map<String, dynamic>.from(value);
    final type = transport['type']?.toString().toLowerCase();
    if (type == 'xhttp') {
      outbound['_mosaic_unsupported_transport'] = 'xhttp';
      return;
    }
    // sing-box rejects an unknown `host` field on ws/grpc/httpupgrade; the
    // WebSocket/HTTP-Upgrade Host belongs in `headers`.
    if (type == 'ws' || type == 'httpupgrade') {
      final host = transport.remove('host');
      if (host is String && host.isNotEmpty) {
        transport['headers'] = <String, dynamic>{
          'Host': host.split(',').first.trim(),
        };
      } else if (host is List && host.isNotEmpty) {
        transport['headers'] = <String, dynamic>{'Host': host.first};
      }
    } else if (type == 'grpc') {
      transport.remove('host');
    }
    outbound['transport'] = transport;
  }

  static String _decodeSubscriptionPayload(String value) {
    final compact = value.trim();
    if (compact.startsWith('{')) return compact;
    final withoutWhitespace = compact.replaceAll(RegExp(r'\s+'), '');
    try {
      final normalized = base64.normalize(withoutWhitespace);
      final decoded =
          utf8.decode(base64Decode(normalized), allowMalformed: false);
      if (decoded.contains('://')) return decoded;
    } on FormatException {
      // Plain share URI feeds are accepted below.
    }
    return compact;
  }

  /// Returns `null` for servers whose wire protocol this runtime cannot speak
  /// (currently Xray's XHTTP transport). Callers must filter nulls instead of
  /// treating them as failures: one unsupported link must not poison the feed.
  static Map<String, dynamic>? _outboundFromShareUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme.isEmpty) {
      throw FormatException(
          'Некорректная ссылка сервера: ${raw.length > 48 ? raw.substring(0, 48) : raw}');
    }
    final tag = uri.fragment.isEmpty
        ? '${uri.scheme}-${uri.host}:${uri.hasPort ? uri.port : 0}'
        : Uri.decodeComponent(uri.fragment);
    final query = uri.queryParameters;
    switch (uri.scheme.toLowerCase()) {
      case 'vless':
        final uuid = uri.userInfo;
        if (uuid.isEmpty || uri.host.isEmpty) {
          throw const FormatException(
              'VLESS ссылка не содержит UUID или адрес.');
        }
        final outbound = <String, dynamic>{
          'type': 'vless',
          'tag': tag,
          'server': uri.host,
          'server_port': uri.hasPort ? uri.port : 443,
          'uuid': uuid,
        };
        // `encryption=none` is a VLESS URI compatibility parameter, not a
        // sing-box 1.13 outbound property. Passing it through makes libbox
        // reject the complete config with `unknown field "encryption"`.
        // It is therefore intentionally consumed and not serialized.
        if ((query['flow'] ?? '').isNotEmpty) outbound['flow'] = query['flow'];
        final security = query['security'] ?? 'none';
        if (security != 'none') {
          final tls = <String, dynamic>{
            'enabled': true,
            if ((query['sni'] ?? '').isNotEmpty) 'server_name': query['sni'],
            if ((query['fp'] ?? '').isNotEmpty)
              'utls': {'enabled': true, 'fingerprint': query['fp']},
            // allowInsecure=1 / insecure=1 in the share link must survive into
            // the sing-box TLS block, exactly like the desktop generator does.
            // Mosaic nodes present a sub.zxc1x1.ru certificate while masquerading
            // as sni=vk.com; without this flag the Android TLS handshake fails
            // hostname verification and the tunnel never carries traffic.
            if (_shareFlag(query,
                    const ['allowInsecure', 'allow_insecure', 'insecure']) ||
                (query['skip-cert-verify'] ?? '').toLowerCase() == 'true')
              'insecure': true,
          };
          if (security == 'reality') {
            tls['reality'] = {
              'enabled': true,
              if ((query['pbk'] ?? '').isNotEmpty) 'public_key': query['pbk'],
              if ((query['sid'] ?? '').isNotEmpty) 'short_id': query['sid'],
            };
          }
          outbound['tls'] = tls;
        }
        final transportType = (query['type'] ?? 'tcp').toLowerCase();
        // Xray's XHTTP transport is a distinct wire protocol, not HTTP. sing-box
        // cannot speak it; silently relabelling it as `http` produces configs
        // that connect but never carry data. Skip such servers entirely so the
        // feed only offers routes this runtime can actually use.
        if (transportType == 'xhttp') {
          return null;
        }
        if (transportType != 'tcp') {
          final hostParam = query['host'] ?? '';
          outbound['transport'] = {
            'type': transportType,
            if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
            if ((query['serviceName'] ?? '').isNotEmpty)
              'service_name': query['serviceName'],
            if (transportType == 'ws' ||
                transportType == 'httpupgrade') ...<String, dynamic>{
              // sing-box has no `host` transport field; the WebSocket and
              // HTTP-Upgrade Host header lives under `headers`.
              if (hostParam.isNotEmpty)
                'headers': {'Host': hostParam.split(',').first.trim()},
            } else if (transportType == 'http' && hostParam.isNotEmpty)
              'host': <String>[
                ...hostParam
                    .split(',')
                    .map((h) => h.trim())
                    .where((h) => h.isNotEmpty),
              ],
          };
        }
        return outbound;
      case 'shadowsocks':
      case 'ss':
        var credentials = _decodeShadowsocksCredentials(uri.userInfo);
        var server = uri.host;
        var port = uri.hasPort ? uri.port : 8388;
        // Legacy subscriptions encode `method:password@host:port` as the
        // complete URI payload. SIP002 uses the modern userinfo form above.
        if (credentials == null || server.isEmpty) {
          final legacy = _decodeLegacyShadowsocksUri(raw);
          if (legacy != null) {
            credentials = (legacy.$1, legacy.$2);
            server = legacy.$3;
            port = legacy.$4;
          }
        }
        if (credentials == null || server.isEmpty) {
          throw const FormatException(
              'Shadowsocks ссылка не содержит метод, пароль или адрес.');
        }
        return {
          'type': 'shadowsocks',
          'tag': tag,
          'server': server,
          'server_port': port,
          'method': credentials.$1,
          'password': credentials.$2,
        };
      case 'vmess':
        return _vmessOutbound(raw, tag);
      case 'trojan':
        if (uri.userInfo.isEmpty || uri.host.isEmpty) {
          throw const FormatException(
              'Trojan ссылка не содержит пароль или адрес.');
        }
        return {
          'type': 'trojan',
          'tag': tag,
          'server': uri.host,
          'server_port': uri.hasPort ? uri.port : 443,
          'password': uri.userInfo,
          'tls': {
            'enabled': true,
            if ((query['sni'] ?? '').isNotEmpty) 'server_name': query['sni'],
            // See the VLESS branch: share links carrying allowInsecure must
            // produce tls.insecure, or hostname verification kills the tunnel.
            if (_shareFlag(query,
                    const ['allowInsecure', 'allow_insecure', 'insecure']) ||
                (query['skip-cert-verify'] ?? '').toLowerCase() == 'true')
              'insecure': true,
          },
        };
      default:
        throw FormatException(
            'Протокол ${uri.scheme.toUpperCase()} пока не поддержан Android direct runtime.');
    }
  }

  /// True when any of [names] appears in the share-URI query with a truthy
  /// value (1/true). Share links spell this flag inconsistently across
  /// exporters: `allowInsecure=1`, `allow_insecure=1`, `insecure=1`.
  static bool _shareFlag(Map<String, String> query, List<String> names) {
    for (final name in names) {
      final raw = query[name]?.toLowerCase();
      if (raw == '1' || raw == 'true') return true;
    }
    return false;
  }

  static (String, String)? _decodeShadowsocksCredentials(String value) {
    if (value.isEmpty) return null;
    var decoded = value;
    if (!decoded.contains(':')) {
      try {
        decoded = utf8.decode(base64Url.decode(base64Url.normalize(decoded)));
      } on FormatException {
        return null;
      }
    }
    final separator = decoded.indexOf(':');
    if (separator <= 0 || separator == decoded.length - 1) return null;
    return (decoded.substring(0, separator), decoded.substring(separator + 1));
  }

  static (String, String, String, int)? _decodeLegacyShadowsocksUri(
      String raw) {
    final payload = raw.trim().substring('ss://'.length).split('#').first;
    try {
      final decoded =
          utf8.decode(base64Url.decode(base64Url.normalize(payload)));
      final separator = decoded.lastIndexOf('@');
      if (separator <= 0 || separator == decoded.length - 1) return null;
      final credentials =
          _decodeShadowsocksCredentials(decoded.substring(0, separator));
      final endpoint = Uri.tryParse('ss://${decoded.substring(separator + 1)}');
      if (credentials == null || endpoint == null || endpoint.host.isEmpty) {
        return null;
      }
      return (
        credentials.$1,
        credentials.$2,
        endpoint.host,
        endpoint.hasPort ? endpoint.port : 8388,
      );
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _vmessOutbound(String raw, String fallbackTag) {
    final payload = raw.trim().substring('vmess://'.length);
    Map<String, dynamic> source;
    try {
      final decoded =
          utf8.decode(base64Url.decode(base64Url.normalize(payload)));
      final json = jsonDecode(decoded);
      if (json is! Map) throw const FormatException('VMess JSON is invalid.');
      source = Map<String, dynamic>.from(json);
    } on FormatException {
      throw const FormatException(
          'VMess ссылка содержит некорректную конфигурацию.');
    }
    final server = source['add']?.toString() ?? '';
    final uuid = source['id']?.toString() ?? '';
    if (server.isEmpty || uuid.isEmpty) {
      throw const FormatException('VMess ссылка не содержит адрес или UUID.');
    }
    final port = int.tryParse(source['port']?.toString() ?? '') ?? 443;
    final tag = source['ps']?.toString().trim();
    final outbound = <String, dynamic>{
      'type': 'vmess',
      'tag': tag == null || tag.isEmpty ? fallbackTag : tag,
      'server': server,
      'server_port': port,
      'uuid': uuid,
      if (int.tryParse(source['aid']?.toString() ?? '') case final alterId?)
        'alter_id': alterId,
      if ((source['scy']?.toString() ?? '').isNotEmpty)
        'security': source['scy'].toString(),
    };
    final tlsEnabled = source['tls']?.toString() == 'tls';
    if (tlsEnabled || (source['sni']?.toString() ?? '').isNotEmpty) {
      outbound['tls'] = {
        'enabled': true,
        if ((source['sni']?.toString() ?? '').isNotEmpty)
          'server_name': source['sni'].toString(),
        if ((source['fp']?.toString() ?? '').isNotEmpty)
          'utls': {'enabled': true, 'fingerprint': source['fp'].toString()},
      };
    }
    final network = source['net']?.toString() ?? 'tcp';
    if (network == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        if ((source['path']?.toString() ?? '').isNotEmpty)
          'path': source['path'].toString(),
        if ((source['host']?.toString() ?? '').isNotEmpty)
          'headers': {'Host': source['host'].toString()},
      };
    } else if (network == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        if ((source['path']?.toString() ?? '').isNotEmpty)
          'service_name': source['path'].toString(),
      };
    }
    return outbound;
  }

  static String _buildTunConfig(List<Map<String, dynamic>> outbounds,
      {Map<String, dynamic>? existingConfig,
      List<String> bypassPackages = const [],
      List<String> proxyPackages = const []}) {
    if (outbounds.isEmpty) {
      throw const FormatException(
          'Подписка не содержит поддерживаемых серверов.');
    }
    const routeTag = 'mosaic-selected-route';
    final tags =
        outbounds.map((outbound) => outbound['tag'] as String).toList();
    final config = existingConfig == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(existingConfig);
    // Debug builds ship a verbose runtime log; libbox forwards these lines to
    // the CommandServerHandler.writeDebugMessage callback, which persists them
    // to files/singbox.log for post-mortem analysis.
    config['log'] = {'level': 'debug'};
    config['inbounds'] = [
      {
        'type': 'tun',
        'tag': 'mosaic-tun',
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 1400,
        'auto_route': true,
        'strict_route': false,
        'stack': 'gvisor',
        'endpoint_independent_nat': true,
        // Exclave-style per-app split tunneling. include/exclude are mutually
        // exclusive in sing-box; exclude (bypass) wins when both are supplied.
        if (bypassPackages.isNotEmpty) 'exclude_package': bypassPackages,
        if (bypassPackages.isEmpty && proxyPackages.isNotEmpty)
          'include_package': proxyPackages,
      },
    ];
    // A single-candidate config means the user picked a concrete physical
    // route (e.g. Mosaic Direct). Routing through a urltest group there adds
    // a health-check dependency loop: the checker needs working outbound
    // connectivity to gstatic before any traffic is forwarded, and on a
    // freshly raised TUN that first probe can stall, leaving every client
    // connection reset. Route straight to the selected outbound instead.
    final directSelection = outbounds.length == 1;
    config['outbounds'] = [
      ...outbounds,
      if (!directSelection)
        {
          'type': 'urltest',
          'tag': routeTag,
          'outbounds': tags,
          'url': 'https://www.gstatic.com/generate_204',
          'interval': '15s',
          'tolerance': 50,
          'interrupt_exist_connections': true,
        },
      {'type': 'direct', 'tag': 'direct'},
    ];
    final effectiveFinal = directSelection ? tags.first : routeTag;
    // A TUN config needs explicit resolvers and DNS hijack. Provide both
    // secure remote DNS and direct/fallback resolvers with IPv4 preference.
    const dnsTag = 'mosaic-doh-bootstrap';
    config['dns'] = {
      'servers': [
        {
          'type': 'https',
          'tag': dnsTag,
          'server': '1.1.1.1',
          'server_port': 443,
          'path': '/dns-query',
        },
        {
          'type': 'udp',
          'tag': 'dns-direct',
          'server': '77.88.8.8',
          'server_port': 53,
          'detour': 'direct',
        },
        {
          'type': 'udp',
          'tag': 'dns-fallback',
          'server': '8.8.8.8',
          'server_port': 53,
          'detour': 'direct',
        },
      ],
      'final': dnsTag,
      'strategy': 'prefer_ipv4',
    };
    final existingRoute = config['route'];
    final route = existingRoute is Map
        ? Map<String, dynamic>.from(existingRoute)
        : <String, dynamic>{};
    final existingRules = route['rules'];
    route['rules'] = [
      // Classify DNS and TCP streams before hijack-dns. Without sniffing,
      // Android TUN DNS packets are not marked as protocol=dns and domain
      // connections lose their SNI/Host before reaching camouflage servers.
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      if (existingRules is List) ...existingRules,
    ];
    route['auto_detect_interface'] = true;
    route['default_domain_resolver'] = dnsTag;
    route['final'] = effectiveFinal;
    config['route'] = route;
    return jsonEncode(config);
  }
}
