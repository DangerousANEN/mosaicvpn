import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  Future<String> buildNativeTunConfig() async {
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
    return _withAndroidTunInbound(payload);
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

  static String _withAndroidTunInbound(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException(
          'Direct subscription is not a sing-box JSON configuration.');
    }
    final config = Map<String, dynamic>.from(decoded);
    final outbounds = config['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      throw const FormatException('Direct configuration has no outbounds.');
    }

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

    final existingRoute = config['route'];
    final route = existingRoute is Map
        ? Map<String, dynamic>.from(existingRoute)
        : <String, dynamic>{};
    route['auto_detect_interface'] = true;
    route.putIfAbsent('final', () {
      for (final outbound in outbounds) {
        if (outbound is Map && outbound['tag'] is String) {
          final type = outbound['type']?.toString();
          if (type != 'direct' && type != 'block' && type != 'dns') {
            return outbound['tag'];
          }
        }
      }
      return (outbounds.first as Map)['tag'];
    });
    config['route'] = route;
    return jsonEncode(config);
  }
}
