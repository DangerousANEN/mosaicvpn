import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

import '../models/models.dart';
import 'daemon_api_base.dart';

/// DaemonApi is the HTTP client for the MosaicVPN Go daemon.
///
/// The daemon listens on 127.0.0.1:`<random_port>` and requires a bearer
/// token from the lockfile. The base URL and token are injected at
/// construction time.
class DaemonApi implements DaemonApiBase {
  final Dio _dio;
  final String baseUrl;

  DaemonApi({required this.baseUrl, required String token})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 10),
        ));

  // ─── Status & Connection ──────────────────────────────────────────

  @override
  Future<VpnStatus> getStatus() async {
    final r = await _dio.get('/v1/status');
    return VpnStatus.fromJson(r.data);
  }

  @override
  Future<void> connect(String serverID) async {
    await _dio.post('/v1/connect', data: {'server_id': serverID});
  }

  @override
  Future<void> disconnect() async {
    await _dio.post('/v1/disconnect');
  }

  @override
  Future<void> shutdownDaemon() async {
    await _dio.post('/v1/runtime/shutdown');
  }

  // ─── Subscriptions ─────────────────────────────────────────────────

  @override
  Future<List<Subscription>> listSubscriptions() async {
    final r = await _dio.get('/v1/subscriptions');
    return (r.data as List).map((j) => Subscription.fromJson(j)).toList();
  }

  @override
  Future<Subscription> addSubscription(String name, String url,
      {bool autoRefresh = false, int refreshInterval = 3600}) async {
    final r = await _dio.post('/v1/subscriptions', data: {
      'name': name,
      'url': url,
      'auto_refresh': autoRefresh,
      'refresh_interval_seconds': refreshInterval,
    });
    return Subscription.fromJson(r.data);
  }

  @override
  Future<Subscription> refreshSubscription(String id) async {
    final r = await _dio.post('/v1/subscriptions/$id/refresh');
    return Subscription.fromJson(r.data);
  }

  @override
  Future<void> renameSubscription(String id, String name) async {
    await _dio.patch('/v1/subscriptions/$id', data: {'name': name});
  }

  @override
  Future<void> deleteSubscription(String id) async {
    await _dio.delete('/v1/subscriptions/$id');
  }

  // ─── Servers ───────────────────────────────────────────────────────

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async {
    final r = await _dio.get('/v1/servers',
        queryParameters: subscriptionID != null
            ? {'subscription_id': subscriptionID}
            : null);
    return (r.data as List).map((j) => Server.fromJson(j)).toList();
  }

  @override
  Future<TestResult> testServer(String id) async {
    final r = await _dio.post('/v1/servers/$id/test');
    return TestResult.fromJson(r.data);
  }

  @override
  Future<List<TestResult>> testAllServers() async {
    final r = await _dio.post('/v1/servers/test-all');
    return (r.data as List).map((j) => TestResult.fromJson(j)).toList();
  }

  // ─── Speed Tests ────────────────────────────────────────────────────
  // group speed test (multi-server) endpoint. Single-server speed test
  // is exposed via the existing `speedTest({String? serverID})` below.

  @override
  Future<List<SpeedTestResult>> testSpeedGroup(String groupLabel,
      {Duration? testFor}) async {
    final r = await _dio.post('/v1/groups/$groupLabel/speedtest', data: {
      if (testFor != null) 'duration_seconds': testFor.inSeconds,
    });
    return (r.data as List).map((j) => SpeedTestResult.fromJson(j)).toList();
  }

  // ─── Backup / Restore (Phase 2.5) ─────────────────────────────────

  /// Exports the entire client config (servers, groups, subscriptions,
  /// preferences) as a JSON string. When `includeSubscriptions` is false,
  /// subscription URLs are stripped from the export.
  @override
  Future<String> exportConfig({bool includeSubscriptions = true}) async {
    final r = await _dio.get('/v1/export',
        queryParameters: {'include_subscriptions': includeSubscriptions});
    return jsonEncode(r.data);
  }

  /// Imports a JSON config string previously produced by [exportConfig].
  /// `mode` controls merge behaviour: "merge" (default) adds non-conflicting
  /// items; "replace" wipes existing state before loading.
  @override
  Future<void> importConfig(String json, {String mode = 'merge'}) async {
    final decoded = jsonDecode(json);
    await _dio.post('/v1/import', data: {'config': decoded, 'mode': mode});
  }

  // ─── Routing Rules ────────────────────────────────────────────────

  @override
  Future<List<Rule>> listRules() async {
    final r = await _dio.get('/v1/rules');
    return (r.data as List).map((j) => Rule.fromJson(j)).toList();
  }

  @override
  Future<Rule> addRule(Map<String, dynamic> rule) async {
    final r = await _dio.post('/v1/rules', data: rule);
    return Rule.fromJson(r.data);
  }

  @override
  Future<void> deleteRule(String id) async {
    await _dio.delete('/v1/rules/$id');
  }

  @override
  Future<void> reorderRules(List<String> orderedIDs) async {
    await _dio.post('/v1/rules:reorder', data: {'ids': orderedIDs});
  }

  // ─── Preferences ──────────────────────────────────────────────────

  @override
  Future<Preferences> getPrefs() async {
    final r = await _dio.get('/v1/prefs');
    return Preferences.fromJson(r.data);
  }

  @override
  Future<Preferences> setPrefs(Map<String, dynamic> prefs) async {
    final r = await _dio.put('/v1/prefs', data: prefs);
    return Preferences.fromJson(r.data);
  }

  // ─── Profiles ─────────────────────────────────────────────────────

  @override
  Future<List<Profile>> listProfiles() async {
    final r = await _dio.get('/v1/profiles');
    return (r.data as List).map((j) => Profile.fromJson(j)).toList();
  }

  @override
  Future<Profile> createProfile(Map<String, dynamic> profile) async {
    final r = await _dio.post('/v1/profiles', data: profile);
    return Profile.fromJson(r.data);
  }

  @override
  Future<Profile> updateProfile(String id, Map<String, dynamic> profile) async {
    final r = await _dio.put('/v1/profiles/$id', data: profile);
    return Profile.fromJson(r.data);
  }

  @override
  Future<void> deleteProfile(String id) async {
    await _dio.delete('/v1/profiles/$id');
  }

  @override
  Future<void> activateProfile(String id) async {
    await _dio.post('/v1/profiles/$id/activate');
  }

  // ─── Route Profiles ──────────────────────────────────────────────

  @override
  Future<List<RouteProfile>> listRouteProfiles() async {
    final r = await _dio.get('/v1/route-profiles');
    return (r.data as List).map((j) => RouteProfile.fromJson(j)).toList();
  }

  @override
  Future<RouteProfile> createRouteProfile(Map<String, dynamic> rp) async {
    final r = await _dio.post('/v1/route-profiles', data: rp);
    return RouteProfile.fromJson(r.data);
  }

  @override
  Future<RouteProfile> updateRouteProfile(
      String id, Map<String, dynamic> rp) async {
    final r = await _dio.put('/v1/route-profiles/$id', data: rp);
    return RouteProfile.fromJson(r.data);
  }

  @override
  Future<void> deleteRouteProfile(String id) async {
    await _dio.delete('/v1/route-profiles/$id');
  }

  // ─── Connections ──────────────────────────────────────────────────

  @override
  Future<List<Connection>> listConnections() async {
    final r = await _dio.get('/v1/connections');
    return (r.data as List).map((j) => Connection.fromJson(j)).toList();
  }

  @override
  Future<void> closeConnection(String id) async {
    await _dio.post('/v1/connections/$id/close');
  }

  @override
  Future<void> closeAllConnections() async {
    await _dio.post('/v1/connections/close-all');
  }

  // ─── Stats ────────────────────────────────────────────────────────

  @override
  Future<TrafficStats> getStats() async {
    final r = await _dio.get('/v1/stats');
    return TrafficStats.fromJson(r.data);
  }

  @override
  Future<void> resetStats() async {
    await _dio.post('/v1/stats/reset');
  }

  // ─── DNS ──────────────────────────────────────────────────────────

  @override
  Future<DNSConfig> getDNS() async {
    final r = await _dio.get('/v1/dns');
    return DNSConfig.fromJson(r.data);
  }

  @override
  Future<DNSConfig> setDNS(Map<String, dynamic> dns) async {
    final r = await _dio.put('/v1/dns', data: dns);
    return DNSConfig.fromJson(r.data);
  }

  // ─── Tests ────────────────────────────────────────────────────────

  @override
  Future<TestResult> testURL(String url, String serverID) async {
    final r = await _dio
        .post('/v1/test/url', data: {'url': url, 'server_id': serverID});
    return TestResult.fromJson(r.data);
  }

  @override
  Future<TestResult> testIP(String serverID) async {
    final r = await _dio.post('/v1/test/ip', data: {'server_id': serverID});
    return TestResult.fromJson(r.data);
  }

  @override
  Future<SpeedTestResult> speedTest({String? serverID}) async {
    final r = await _dio.post('/v1/test/speed',
        data: serverID != null ? {'server_id': serverID} : null);
    return SpeedTestResult.fromJson(r.data);
  }

  // ─── WARP ─────────────────────────────────────────────────────────

  @override
  Future<WARPConfig> getWARP() async {
    final r = await _dio.get('/v1/warp');
    return WARPConfig.fromJson(r.data);
  }

  @override
  Future<WARPConfig> setWARP(Map<String, dynamic> warp) async {
    final r = await _dio.put('/v1/warp', data: warp);
    return WARPConfig.fromJson(r.data);
  }

  // ─── Import ───────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> importClipboard(String raw) async {
    final r = await _dio.post('/v1/import/clipboard', data: {'raw': raw});
    return r.data;
  }

  @override
  Future<Map<String, dynamic>> importLink(String link) async {
    final r = await _dio.post('/v1/import/link', data: {'link': link});
    return r.data;
  }

  // ─── Diag ─────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getDiag() async {
    final r = await _dio.get('/v1/diag');
    return r.data;
  }

  // ─── Egresses (multi-proxy listeners) ──────────────────────────────

  @override
  Future<List<Egress>> listEgresses() async {
    final r = await _dio.get('/v1/egresses');
    return (r.data as List).map((j) => Egress.fromJson(j)).toList();
  }

  @override
  Future<Egress> addEgress(Map<String, dynamic> egress) async {
    final r = await _dio.post('/v1/egresses', data: egress);
    return Egress.fromJson(r.data);
  }

  @override
  Future<Egress> updateEgress(String id, Map<String, dynamic> egress) async {
    final r = await _dio.put('/v1/egresses/$id', data: egress);
    return Egress.fromJson(r.data);
  }

  @override
  Future<void> deleteEgress(String id) async {
    await _dio.delete('/v1/egresses/$id');
  }

  @override
  Future<void> toggleEgress(String id, bool active) async {
    await _dio.post('/v1/egresses/$id/toggle', data: {'active': active});
  }

  // ─── Billing ───────────────────────────────────────────────────────

  @override
  Future<BillingProfile> getBillingProfile() async {
    final r = await _dio.get('/v1/billing/profile');
    return BillingProfile.fromJson(r.data);
  }

  @override
  Future<void> linkBillingAccount(int telegramId,
      {String? sessionToken}) async {
    final data = <String, dynamic>{'telegram_id': telegramId};
    if (sessionToken != null && sessionToken.isNotEmpty) {
      data['session_token'] = sessionToken;
    }
    await _dio.post('/v1/billing/link', data: data);
  }

  @override
  Future<void> unlinkBillingAccount() async {
    await _dio.post('/v1/billing/unlink', data: {});
  }

  @override
  Future<TopupResponse> createTopup({
    required double amount,
    int? days,
    String? description,
  }) async {
    final data = <String, dynamic>{
      'amount': amount,
      if (days != null) 'days': days,
      if (description != null) 'description': description,
    };
    final r = await _dio.post('/v1/billing/topup', data: data);
    return TopupResponse.fromJson(r.data);
  }

  @override
  Future<TopupStatusResponse> getTopupStatus(int invoiceId) async {
    final r = await _dio.get('/v1/billing/topup/$invoiceId');
    return TopupStatusResponse.fromJson(r.data);
  }

  // ─── Account cabinet (T-19) ────────────────────────────────────────

  @override
  Future<LinkResult> redeemLinkCode(String code) async {
    final r = await _dio.post('/v1/account/link', data: {'code': code});
    return LinkResult.fromJson(Map<String, dynamic>.from(r.data as Map));
  }

  @override
  Future<void> loginWithEmail(String email, String password) async {
    await _dio.post('/v1/account/email-login',
        data: {'email': email, 'password': password});
  }

  @override
  Future<List<PaymentEntry>> getPaymentHistory() async {
    final r = await _dio.get('/v1/account/payments');
    final raw = (r.data as Map)['payments'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => PaymentEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  // ─── Unified account ────────────────────────────────────────────────

  @override
  Future<UnifiedAccount?> getUnifiedAccount() async {
    final r = await _dio.get('/v1/account/overview');
    final raw = r.data as Map;
    if (raw['linked'] != true || raw['account'] is! Map) return null;
    return UnifiedAccount.fromJson(
        Map<String, dynamic>.from(raw['account'] as Map));
  }

  @override
  Future<UnifiedAccount> freezeAccount() async {
    await _dio.post('/v1/account/freeze', data: const {});
    final account = await getUnifiedAccount();
    if (account == null) {
      throw const FormatException('Account is no longer linked.');
    }
    return account;
  }

  @override
  Future<UnifiedAccount> unfreezeAccount() async {
    await _dio.post('/v1/account/unfreeze', data: const {});
    final account = await getUnifiedAccount();
    if (account == null) {
      throw const FormatException('Account is no longer linked.');
    }
    return account;
  }

  @override
  Future<List<CheckoutProviderOption>> getCheckoutOptions() async {
    final r = await _dio.get('/v1/billing/checkout-options');
    final raw = (r.data as Map)['providers'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) =>
            CheckoutProviderOption.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  @override
  Future<CheckoutSession> createCheckout(
      {required int amountRub, required String provider}) async {
    final r = await _dio.post('/v1/billing/checkout',
        data: {'amount_rub': amountRub, 'provider': provider});
    return CheckoutSession.fromJson(Map<String, dynamic>.from(r.data as Map));
  }

  @override
  Future<RotatedSubscriptionLink> rotateSubscriptionLink() async {
    final r =
        await _dio.post('/v1/account/subscription-link/rotate', data: const {});
    return RotatedSubscriptionLink.fromJson(
        Map<String, dynamic>.from(r.data as Map));
  }

  // ─── Provider Manifest ─────────────────────────────────────────────

  @override
  Future<ProviderManifest> getProviderManifest() async {
    final r = await _dio.get('/v1/manifest');
    return ProviderManifest.fromJson(r.data);
  }

  @override
  Future<Map<String, NodeHealth>> getGroupHealth(String groupId) async {
    final r = await _dio.get('/v1/groups/$groupId/health');
    final map = <String, NodeHealth>{};
    if (r.data is Map) {
      for (final entry in (r.data as Map).entries) {
        final key = entry.key.toString();
        if (entry.value is Map) {
          map[key] = NodeHealth.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    }
    return map;
  }

  @override
  Future<Server> selectNodeFromGroup(String groupId) async {
    final r = await _dio.get('/v1/groups/$groupId/select');
    return Server.fromJson(r.data);
  }

  // ─── Events (SSE) ─────────────────────────────────────────────────

  /// Subscribe to daemon events via Server-Sent Events.
  /// Returns a stream of (event, data) pairs.
  @override
  Stream<(String, Map<String, dynamic>)> events() async* {
    final client = HttpClient();
    final uri = Uri.parse('$baseUrl/v1/events');

    while (true) {
      try {
        final request = await client.getUrl(uri);
        request.headers.contentType = ContentType.parse('text/event-stream');
        request.headers.set('Accept', 'text/event-stream');
        request.headers
            .set('Authorization', _dio.options.headers['Authorization']!);

        final response = await request.close();
        if (response.statusCode != 200) {
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }

        String buffer = '';
        await for (final chunk in response) {
          buffer += utf8.decode(chunk);

          while (buffer.contains('\n\n')) {
            final idx = buffer.indexOf('\n\n');
            final block = buffer.substring(0, idx);
            buffer = buffer.substring(idx + 2);

            String event = '';
            String dataStr = '';

            for (final line in block.split('\n')) {
              if (line.startsWith('event: ')) {
                event = line.substring(7).trim();
              } else if (line.startsWith('data: ')) {
                dataStr = line.substring(6);
              }
            }

            if (dataStr.isNotEmpty) {
              try {
                final data = jsonDecode(dataStr);
                yield (event, data);
              } catch (_) {
                yield (event, {});
              }
            }
          }
        }
      } catch (_) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  // ─── Mock-only stubs (real daemon does not support these yet) ──────

  @override
  Future<void> addServer(Server s) async =>
      throw UnimplementedError('addServer not supported by real daemon');

  @override
  Future<void> deleteServer(String id) async =>
      throw UnimplementedError('deleteServer not supported by real daemon');

  @override
  Future<List<ServerGroup>> listGroups() async =>
      throw UnimplementedError('listGroups not supported by real daemon');

  @override
  Future<ServerGroup> createGroup(String name) async =>
      throw UnimplementedError('createGroup not supported by real daemon');

  @override
  Future<void> deleteGroup(String id) async =>
      throw UnimplementedError('deleteGroup not supported by real daemon');

  @override
  Future<void> moveToGroup(String serverId, String groupId) async =>
      throw UnimplementedError('moveToGroup not supported by real daemon');

  @override
  Future<SpeedTestResult> testSpeed(String serverID,
          {Duration? testFor}) async =>
      throw UnimplementedError('testSpeed not supported by real daemon');
}
