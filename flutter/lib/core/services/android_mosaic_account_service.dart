import 'dart:convert';

import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  });

  final String directToken;
  final String? sessionToken;
  final String? username;
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

  Future<AndroidMosaicSession?> restoreSession() async {
    final directToken = await _secureStorage.read(key: _directTokenKey);
    if (directToken == null || directToken.isEmpty) return null;
    return AndroidMosaicSession(
      directToken: directToken,
      sessionToken: await _secureStorage.read(key: _sessionTokenKey),
      username: await _secureStorage.read(key: _usernameKey),
    );
  }

  Future<AndroidMosaicSession> redeemTelegramCode(String rawCode) async {
    final code = normalizePairingCode(rawCode);
    if (code.length != 8) {
      throw const FormatException('Введите все 8 символов кода из Telegram.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/link/redeem',
      data: {'code': code},
    );
    final payload = Map<String, dynamic>.from(response.data ?? const {});
    return _savePayload(payload, directKey: 'direct_token');
  }

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

  Future<String> _sessionToken() async {
    final session = await restoreSession();
    final token = session?.sessionToken;
    if (token == null || token.isEmpty) {
      throw StateError('Сначала войдите через сайт или Telegram.');
    }
    return token;
  }

  Future<Map<String, dynamic>> _getAccountJson(String path) async {
    final token = await _sessionToken();
    final response = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: {'token': token},
    );
    return Map<String, dynamic>.from(response.data ?? const {});
  }

  Future<Map<String, dynamic>> _postAccountJson(
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final token = await _sessionToken();
    final response = await _dio.post<Map<String, dynamic>>(
      path,
      data: <String, dynamic>{'token': token, ...?data},
    );
    return Map<String, dynamic>.from(response.data ?? const {});
  }

  Future<UnifiedAccount?> getUnifiedAccount() async {
    final session = await restoreSession();
    if (session == null) return null;
    final payload = await _getAccountJson('/api/billing/profile');
    if (payload['linked'] == false) return null;
    return UnifiedAccount.fromJson(payload['account'] is Map
        ? Map<String, dynamic>.from(payload['account'] as Map)
        : payload);
  }

  Future<UnifiedAccount> setFrozen(bool frozen) async {
    final payload = await _postAccountJson(
      frozen ? '/api/account/freeze' : '/api/account/unfreeze',
    );
    return UnifiedAccount.fromJson(payload['account'] is Map
        ? Map<String, dynamic>.from(payload['account'] as Map)
        : payload);
  }

  Future<List<CheckoutProviderOption>> getCheckoutOptions() async {
    final payload = await _getAccountJson('/api/checkout/options');
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
  }) async {
    final payload = await _postAccountJson('/api/checkout/create', data: {
      'amount_rub': amountRub,
      'provider': provider,
    });
    return CheckoutSession.fromJson(payload);
  }

  Future<RotatedSubscriptionLink> rotateSubscriptionLink() async {
    final payload = await _postAccountJson('/api/subscription/link/rotate');
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
  Future<ProviderManifest> getProviderManifest() async {
    final response = await _dio.get<Map<String, dynamic>>('/api/manifest.json');
    final payload = Map<String, dynamic>.from(response.data ?? const {});
    if (payload.isEmpty) {
      throw StateError('Сервис не вернул список маршрутов.');
    }
    return ProviderManifest.fromJson(payload);
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
  Future<List<PaymentEntry>> getPaymentHistory() async {
    final session = await restoreSession();
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

  /// Downloads the authenticated opaque direct feed and builds an Android TUN
  /// config. The selected user-facing group controls client-side filtering and
  /// sing-box URLTest failover; traffic goes directly to the selected node.
  Future<String> buildNativeTunConfig({String? groupId}) async {
    final session = await restoreSession();
    if (session == null) {
      throw StateError('Сначала войдите в MosaicVPN.');
    }
    final response = await _dio.get<Object>(
      'https://sub.zxc1x1.ru/${Uri.encodeComponent(session.directToken)}',
      options: Options(responseType: ResponseType.plain),
    );
    final payload = response.data?.toString().trim() ?? '';
    if (payload.isEmpty) {
      throw StateError('Сервис не вернул конфигурацию для этого устройства.');
    }
    return _withAndroidTunInbound(payload, groupId: groupId);
  }

  static String normalizePairingCode(String raw) {
    final normalized = StringBuffer();
    for (final unit in raw.toUpperCase().codeUnits) {
      final symbol = String.fromCharCode(unit);
      if (_pairingAlphabet.contains(symbol)) normalized.write(symbol);
    }
    return normalized.toString();
  }

  Future<AndroidMosaicSession> _savePayload(
    Map<String, dynamic> payload, {
    required String directKey,
  }) async {
    final directToken = payload[directKey]?.toString() ?? '';
    if (directToken.isEmpty) {
      throw StateError('Сервис не выдал токен конфигурации для устройства.');
    }
    final sessionToken =
        payload['session_token']?.toString() ?? payload['token']?.toString();
    final username =
        payload['username']?.toString() ?? payload['email']?.toString();
    await _secureStorage.write(key: _directTokenKey, value: directToken);
    if (sessionToken != null && sessionToken.isNotEmpty) {
      await _secureStorage.write(key: _sessionTokenKey, value: sessionToken);
    }
    if (username != null && username.isNotEmpty) {
      await _secureStorage.write(key: _usernameKey, value: username);
    }
    return AndroidMosaicSession(
      directToken: directToken,
      sessionToken: sessionToken,
      username: username,
    );
  }

  /// Builds a TUN config from a single user-imported share URI. This path is
  /// used only for local/user subscriptions; Mosaic direct routes retain the
  /// generic automatic selection and never reveal private pool members.
  static String buildNativeTunConfigFromShareUri(String shareUri) {
    final outbound = _outboundFromShareUri(shareUri);
    return _buildTunConfig(<Map<String, dynamic>>[outbound]);
  }

  static String _withAndroidTunInbound(String payload, {String? groupId}) {
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
          .toList(growable: false);
      if (outbounds.isEmpty) {
        throw const FormatException(
            'Подписка не содержит поддерживаемых серверов.');
      }
      return _buildTunConfig(outbounds);
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
      final rawGroupIDs = outbound.remove('mosaic_group_ids');
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
      return memberships is Set<String> && memberships.contains(groupId);
    }

    final selected = candidates.where(matchesGroup).toList();
    // A selected Smart Group is provider policy, not a best-effort client hint.
    // Never fall back to the complete private pool: the server must include
    // generic membership metadata for the requested group.
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

    return _buildTunConfig(cleanOutbounds, existingConfig: config);
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

  static Map<String, dynamic> _outboundFromShareUri(String raw) {
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
          'encryption': query['encryption'] ?? 'none',
        };
        if ((query['flow'] ?? '').isNotEmpty) outbound['flow'] = query['flow'];
        final security = query['security'] ?? 'none';
        if (security != 'none') {
          final tls = <String, dynamic>{
            'enabled': true,
            if ((query['sni'] ?? '').isNotEmpty) 'server_name': query['sni'],
            if ((query['fp'] ?? '').isNotEmpty)
              'utls': {'enabled': true, 'fingerprint': query['fp']},
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
        final transportType = query['type'] ?? 'tcp';
        if (transportType != 'tcp') {
          outbound['transport'] = {
            'type': transportType,
            if ((query['path'] ?? '').isNotEmpty) 'path': query['path'],
            if ((query['host'] ?? '').isNotEmpty) 'host': query['host'],
            if ((query['mode'] ?? '').isNotEmpty) 'mode': query['mode'],
            if ((query['serviceName'] ?? '').isNotEmpty)
              'service_name': query['serviceName'],
          };
        }
        return outbound;
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
          },
        };
      default:
        throw FormatException(
            'Протокол ${uri.scheme.toUpperCase()} пока не поддержан Android direct runtime.');
    }
  }

  static String _buildTunConfig(List<Map<String, dynamic>> outbounds,
      {Map<String, dynamic>? existingConfig}) {
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
    config['inbounds'] = [
      {
        'type': 'tun',
        'tag': 'mosaic-tun',
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 1400,
        'auto_route': true,
        'strict_route': false,
        'stack': 'system',
        'endpoint_independent_nat': true,
      },
    ];
    config['outbounds'] = [
      ...outbounds,
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
    final existingRoute = config['route'];
    final route = existingRoute is Map
        ? Map<String, dynamic>.from(existingRoute)
        : <String, dynamic>{};
    route['auto_detect_interface'] = true;
    route['final'] = routeTag;
    config['route'] = route;
    return jsonEncode(config);
  }
}
