import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

import '../models/models.dart';
import 'daemon_api_base.dart';
import 'daemon_api_exception.dart';

/// Resolves the current local daemon endpoint from its lockfile.
///
/// mosaicd binds an ephemeral loopback port at every launch, so a desktop
/// client must be able to recover when a previous daemon instance exits and a
/// new instance writes a different port/token pair.
typedef DaemonEndpointResolver = Future<({String baseUrl, String token})?>
    Function();

/// DaemonApi is the HTTP client for the MosaicVPN Go daemon.
///
/// The daemon listens on 127.0.0.1:`<random_port>` and requires a bearer
/// token from the lockfile. The base URL and token are injected at
/// construction time.
class DaemonApi implements DaemonApiBase {
  final Dio _dio;
  final String baseUrl;
  final DaemonEndpointResolver? _endpointResolver;
  Future<({String baseUrl, String token})?>? _endpointRefresh;

  DaemonApi({
    required this.baseUrl,
    required String token,
    DaemonEndpointResolver? endpointResolver,
  })  : _endpointResolver = endpointResolver,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 10),
        )) {
    // A connection-refused error is safe to retry: no HTTP request reached the
    // daemon. This specifically heals the stale random-port case after
    // mosaicd is restarted, without replaying requests that may have reached
    // the backend and merely timed out waiting for a response.
    if (_endpointResolver != null) {
      _dio.interceptors
          .add(InterceptorsWrapper(onError: (error, handler) async {
        if (!_canRecoverFrom(error)) {
          handler.next(error);
          return;
        }

        try {
          final endpoint = await _refreshEndpoint();
          if (endpoint == null) {
            handler.next(error);
            return;
          }
          final headers =
              Map<String, dynamic>.from(error.requestOptions.headers)
                ..['Authorization'] = 'Bearer ${endpoint.token}';
          final request = error.requestOptions.copyWith(
            baseUrl: endpoint.baseUrl,
            headers: headers,
            extra: <String, dynamic>{
              ...error.requestOptions.extra,
              '_mosaic_endpoint_retried': true,
            },
          );
          final response = await _dio.fetch<dynamic>(request);
          handler.resolve(response);
        } on DioException catch (retryError) {
          handler.next(retryError);
        } catch (_) {
          // Keep the original transport error: it tells the UI that the local
          // runtime is unavailable, not that a business operation failed.
          handler.next(error);
        }
      }));
    }
  }

  bool _canRecoverFrom(DioException error) {
    return error.type == DioExceptionType.connectionError &&
        error.requestOptions.extra['_mosaic_endpoint_retried'] != true;
  }

  Future<({String baseUrl, String token})?> _refreshEndpoint() {
    final current = _endpointRefresh;
    if (current != null) return current;
    final resolving = _endpointResolver!();
    _endpointRefresh = resolving;
    return resolving.whenComplete(() => _endpointRefresh = null);
  }

  // ─── Status & Connection ──────────────────────────────────────────

  @override
  Future<VpnStatus> getStatus() async {
    final r = await _dio.get('/v1/status');
    return VpnStatus.fromJson(r.data);
  }

  Future<void> _connectRequest(Map<String, String> body) async {
    try {
      await _dio.post('/v1/connect', data: body);
    } on DioException catch (error) {
      throw DaemonApiException.fromDio(error);
    }
  }

  @override
  Future<void> connect(String serverID) =>
      _connectRequest({'server_id': serverID});

  @override
  Future<void> connectGroup(String groupID) =>
      _connectRequest({'group_id': groupID});

  @override
  Future<SmartGroupCandidateShard> getCandidateShard(
      String groupID, String installationID) async {
    final response = await _dio.get('/v1/groups/$groupID/candidates',
        queryParameters: {'installation_id': installationID});
    return SmartGroupCandidateShard.fromJson(
        response.data as Map<String, dynamic>);
  }

  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
    String groupID,
    String candidateID, {
    String? probeMode,
    int? probeSamples,
    String? probeUrl,
  }) async {
    final response = await _dio.post(
      '/v1/groups/$groupID/probe',
      data: {'candidate_id': candidateID},
      queryParameters: {
        if (probeMode != null) 'probe_mode': probeMode,
        if (probeSamples != null) 'probe_samples': probeSamples,
        if (probeUrl != null && probeUrl.isNotEmpty) 'probe_url': probeUrl,
      },
    );
    return SmartGroupProbeResult.fromJson(
        response.data as Map<String, dynamic>);
  }

  @override
  Future<void> connectGroupCandidate(String groupID, String candidateID) =>
      _connectRequest({'group_id': groupID, 'server_id': candidateID});

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
  Future<Subscription> enrollProviderSubscription({
    required String providerId,
    required String providerAccountId,
    required String subscriptionName,
    required String subscriptionUrl,
    String? sessionToken,
    String? directToken,
    String? username,
  }) async {
    final response = await _dio.post('/v1/providers/enroll', data: {
      'provider_id': providerId,
      'provider_account_id': providerAccountId,
      'subscription_name': subscriptionName,
      'subscription_url': subscriptionUrl,
      if (sessionToken?.isNotEmpty == true) 'session_token': sessionToken,
      if (directToken?.isNotEmpty == true) 'direct_token': directToken,
      if (username?.isNotEmpty == true) 'username': username,
    });
    return Subscription.fromJson(Map<String, dynamic>.from(response.data));
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

  @override
  Future<List<Subscription>> reorderSubscriptions(
      List<String> subscriptionIDs) async {
    final r = await _dio.post('/v1/subscriptions:reorder', data: {
      'subscription_ids': subscriptionIDs,
    });
    return (r.data as List).map((j) => Subscription.fromJson(j)).toList();
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

  @override
  Future<TestResult> testDirectRoute(String groupID) async {
    final r = await _dio.post('/v1/routes/$groupID/test');
    return TestResult.fromJson(r.data);
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
  Future<SpeedTestResult> speedTest({
    String? serverID,
    SpeedProbePolicy? policy,
  }) async {
    final data = <String, dynamic>{};
    if (serverID != null) data['server_id'] = serverID;
    if (policy != null) data['policy'] = policy.toJson();
    final r =
        await _dio.post('/v1/test/speed', data: data.isEmpty ? null : data);
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
  Future<LinkResult> redeemLinkCode(String code,
      {String? subscriptionId}) async {
    final r = await _dio.post('/v1/account/link', data: {
      'code': code,
      if (subscriptionId?.trim().isNotEmpty == true)
        'subscription_id': subscriptionId!.trim(),
    });
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
  Future<ProviderManifest> getProviderManifest({String? subscriptionId}) async {
    final r = await _dio.get(
      '/v1/manifest',
      queryParameters: subscriptionId?.isNotEmpty == true
          ? {'subscription_id': subscriptionId}
          : null,
    );
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

  // ─── Local servers and collections ─────────────────────────────────

  @override
  Future<void> addServer(Server server) async {
    await _dio.post('/v1/servers', data: {
      'server': server.toJson(),
      if (server.importUri.isNotEmpty) 'raw_uri': server.importUri,
    });
  }

  @override
  Future<void> deleteServer(String id) async {
    await _dio.delete('/v1/servers/$id');
  }

  @override
  Future<List<ServerGroup>> listGroups() async {
    final response = await _dio.get('/v1/groups');
    return (response.data as List)
        .map((item) => ServerGroup.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ServerGroup> createGroup(String name) async {
    final response = await _dio.post('/v1/groups', data: {'name': name});
    return ServerGroup.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteGroup(String id) async {
    await _dio.delete('/v1/groups/$id');
  }

  @override
  Future<void> moveToGroup(String serverId, String groupId) async {
    await _dio.post('/v1/servers/$serverId/move', data: {
      'group_id': groupId == ServerGroup.ungroupedId ? '' : groupId,
    });
  }

  @override
  Future<SpeedTestResult> testSpeed(String serverID,
          {Duration? testFor}) async =>
      throw UnimplementedError('testSpeed not supported by real daemon');
}
