import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/billing_profile.dart';
import '../models/provider_profile.dart';

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

  /// Downloads the authenticated opaque direct feed and builds an Android TUN
  /// config. The selected user-facing group controls client-side filtering and
  /// sing-box URLTest failover; traffic goes directly to the selected node.
  Future<String> buildNativeTunConfig({String? groupId}) async {
    final session = await restoreSession();
    if (session == null) {
      throw StateError('Сначала войдите в MosaicVPN.');
    }
    final response = await _dio.get<Object>(
      '/api/direct/singbox',
      queryParameters: {'token': session.directToken},
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

  static String _withAndroidTunInbound(String payload, {String? groupId}) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException(
          'Direct subscription is not a sing-box JSON configuration.');
    }
    final config = Map<String, dynamic>.from(decoded);
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
      if (groupId == null || groupId.isEmpty) return true;
      final memberships = outbound['_mosaic_group_ids'];
      return memberships is Set<String> && memberships.contains(groupId);
    }

    var selected = candidates.where(matchesGroup).toList();
    // A group is a preference, not a dead end: if its pool is temporarily
    // empty, retain reachability through the full authenticated pool.
    if (selected.isEmpty) selected = candidates;
    final tags = <String>[];
    final cleanOutbounds = <Map<String, dynamic>>[];
    for (final outbound in selected) {
      final clean = Map<String, dynamic>.from(outbound)
        ..removeWhere((key, _) => key.toString().startsWith('_mosaic_'));
      tags.add(clean['tag'] as String);
      cleanOutbounds.add(clean);
    }

    const routeTag = 'mosaic-selected-route';
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
      ...cleanOutbounds,
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
