import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/android_hosted_daemon_api.dart';
import '../api/daemon_api.dart';
import '../api/daemon_api_base.dart';
import '../api/unavailable_daemon_api.dart';
import '../config/app_config.dart';
import '../platform/app_platform.dart';
import '../models/models.dart';
import '../services/android_mosaic_account_service.dart';
import '../services/android_vpn_service.dart';
import '../services/daemon_launcher.dart';
import '../services/ui_preferences_service.dart';

// ─── Lockfile helper ────────────────────────────────────────────────

/// Returns candidate lockfile paths ordered by precedence.
List<String> _candidateLockfilePaths() {
  // On web, Platform.environment throws UnsupportedError.
  if (kIsWeb) return [];

  final candidates = <String>[];

  // Portable packages keep all state beside the application. This candidate
  // must come before user-level directories so two portable copies never share
  // subscriptions or attach to each other's daemon.
  final portableData = DaemonLauncher.instance.portableDataDirectory();
  if (portableData != null && portableData.isNotEmpty) {
    candidates.add('$portableData${Platform.pathSeparator}daemon.lock');
    candidates.add('$portableData${Platform.pathSeparator}mosaicd.lock');
  }

  // 1. Environment variable override (if set)
  final envDir = Platform.environment['MOSAIC_DATA_DIR'];
  if (envDir != null && envDir.isNotEmpty) {
    candidates.add('$envDir/daemon.lock');
    candidates.add('$envDir/mosaicd.lock');
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
  final programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
  final xdgData = Platform.environment['XDG_DATA_HOME'];

  if (Platform.isWindows) {
    if (localAppData.isNotEmpty) {
      candidates.add('$localAppData\\MosaicVPN\\daemon.lock');
      candidates.add('$localAppData\\MosaicVPN\\mosaicd.lock');
      candidates.add('$localAppData\\Mosaic\\daemon.lock');
      candidates.add('$localAppData\\Mosaic\\mosaicd.lock');
    }
    if (programData.isNotEmpty) {
      candidates.add('$programData\\MosaicVPN\\daemon.lock');
      candidates.add('$programData\\MosaicVPN\\mosaicd.lock');
      candidates.add('$programData\\Mosaic\\daemon.lock');
      candidates.add('$programData\\Mosaic\\mosaicd.lock');
    }
    candidates.add(r'C:\ProgramData\Mosaic\daemon.lock');
  } else if (Platform.isMacOS) {
    if (home.isNotEmpty) {
      candidates.add('$home/Library/Application Support/MosaicVPN/daemon.lock');
      candidates
          .add('$home/Library/Application Support/MosaicVPN/mosaicd.lock');
      candidates.add('$home/Library/Application Support/Mosaic/daemon.lock');
      candidates.add('$home/Library/Application Support/Mosaic/mosaicd.lock');
    }
  } else {
    // Linux / Unix
    if (xdgData != null && xdgData.isNotEmpty) {
      candidates.add('$xdgData/mosaicvpn/daemon.lock');
      candidates.add('$xdgData/mosaicvpn/mosaicd.lock');
      candidates.add('$xdgData/mosaic/daemon.lock');
      candidates.add('$xdgData/mosaic/mosaicd.lock');
    }
    if (home.isNotEmpty) {
      candidates.add('$home/.local/share/mosaicvpn/mosaicd.lock');
      candidates.add('$home/.local/share/mosaicvpn/daemon.lock');
      candidates.add('$home/.local/share/mosaic/daemon.lock');
      candidates.add('$home/.local/share/mosaic/mosaicd.lock');
      candidates.add('$home/.mosaicvpn/daemon.lock');
      candidates.add('$home/.mosaicvpn/mosaicd.lock');
    }
    candidates.add('/var/lib/mosaicvpn/daemon.lock');
    candidates.add('/var/lib/mosaic/daemon.lock');
  }

  if (home.isNotEmpty) {
    candidates.add('$home/${AppConfig.lockfilePath}');
  }

  return candidates;
}

/// Reads candidate daemon lockfiles and returns (baseUrl, token) if the daemon
/// is reachable via GET /v1/status health-check, otherwise returns null.
Future<({String baseUrl, String token})?> _tryRealDaemon() async {
  // On web, `Platform.environment` is unsupported — skip lockfile discovery entirely.
  if (kIsWeb) return null;

  for (final lockPath in _candidateLockfilePaths()) {
    try {
      final file = File(lockPath);
      if (!file.existsSync()) continue;

      final content = file.readAsStringSync().trim();
      if (content.isEmpty) continue;

      final json = jsonDecode(content) as Map<String, dynamic>;
      final port = json['port'];
      final token = json['token'];
      if (port == null || token == null) continue;

      final host = (json['host'] as String?)?.isNotEmpty == true
          ? json['host'] as String
          : AppConfig.defaultDaemonHost;
      final baseUrl = 'http://$host:$port';
      final api = DaemonApi(baseUrl: baseUrl, token: token.toString());

      // Health-check: ping GET /v1/status. If getStatus times out or throws, daemon is offline or lockfile is stale.
      await api.getStatus().timeout(AppConfig.healthCheckTimeout);
      return (baseUrl: baseUrl, token: token.toString());
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// Resolves a live daemon endpoint and starts a fresh local daemon if the
/// previous endpoint is stale. Kept outside the provider so [DaemonApi] can
/// use the same recovery path after a connection-refused error.
Future<({String baseUrl, String token})?> _resolveLiveDaemonEndpoint() async {
  if (kIsWeb || AppPlatform.isAndroid) return null;
  var real = await _tryRealDaemon();
  if (real != null) return real;

  await DaemonLauncher.instance.ensureDaemonRunning(() async {
    real = await _tryRealDaemon();
    return real != null;
  });
  return real;
}

// ─── Daemon API Provider ────────────────────────────────────────────

/// Provides the API client for the MosaicVPN daemon.
///
/// Attempts to connect to the real Go daemon via lockfile-discovered
/// port+token. If the daemon is unreachable, the provider returns an explicit
/// unavailable-runtime error; production builds never fabricate demo data.
final daemonApiProvider = Provider<DaemonApiBase>((ref) {
  // We return a placeholder synchronously; the actual resolution happens
  // in the async override below. But Provider needs to return something
  // synchronously, so we use a late-init pattern via a wrapper.
  return _ResolvedDaemonApi();
});

/// Async provider that resolves the real-or-mock daemon API.
final resolvedDaemonApiProvider = FutureProvider<DaemonApiBase>((ref) async {
  if (AppPlatform.isAndroid) return AndroidHostedDaemonApi.instance;
  final found = await _resolveLiveDaemonEndpoint();
  if (found != null) {
    return DaemonApi(
      baseUrl: found.baseUrl,
      token: found.token,
      endpointResolver: _resolveLiveDaemonEndpoint,
    );
  }
  return const UnavailableDaemonApi();
});

/// Placeholder that delegates all calls to a lazily-resolved backend.
/// Used until [resolvedDaemonApiProvider] completes.
class _ResolvedDaemonApi implements DaemonApiBase {
  DaemonApiBase? _impl;
  Future<DaemonApiBase>? _resolution;

  Future<DaemonApiBase> _backend() async {
    final cached = _impl;
    // A real client remains valid until its transport-level recovery notices a
    // stale endpoint. Do not permanently cache an unavailable placeholder:
    // mosaicd may have been extracting, restarting or waiting on a stale lock
    // during the first request, and a later Retry must be able to recover.
    if (cached != null && cached is! UnavailableDaemonApi) return cached;
    if (AppPlatform.isAndroid) {
      return _impl = AndroidHostedDaemonApi.instance;
    }

    final inFlight = _resolution;
    if (inFlight != null) return inFlight;

    final resolution = () async {
      final found = await _resolveLiveDaemonEndpoint();
      final impl = (found != null)
          ? DaemonApi(
              baseUrl: found.baseUrl,
              token: found.token,
              endpointResolver: _resolveLiveDaemonEndpoint,
            )
          : const UnavailableDaemonApi();
      _impl = impl;
      return impl;
    }();
    _resolution = resolution;
    try {
      return await resolution;
    } finally {
      // Keep the successful real client in [_impl], but permit another launch
      // attempt after an unavailable result.
      _resolution = null;
    }
  }

  @override
  Future<VpnStatus> getStatus() async => (await _backend()).getStatus();
  @override
  Future<void> connect(String serverID) async =>
      (await _backend()).connect(serverID);
  @override
  Future<void> connectGroup(String groupID) async =>
      (await _backend()).connectGroup(groupID);
  @override
  Future<SmartGroupCandidateShard> getCandidateShard(
          String groupID, String installationID) async =>
      (await _backend()).getCandidateShard(groupID, installationID);
  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
          String groupID, String candidateID) async =>
      (await _backend()).probeGroupCandidate(groupID, candidateID);
  @override
  Future<void> connectGroupCandidate(
          String groupID, String candidateID) async =>
      (await _backend()).connectGroupCandidate(groupID, candidateID);
  @override
  Future<void> disconnect() async => (await _backend()).disconnect();
  @override
  Future<void> shutdownDaemon() async => (await _backend()).shutdownDaemon();
  @override
  Future<List<Subscription>> listSubscriptions() async =>
      (await _backend()).listSubscriptions();
  @override
  Future<Subscription> addSubscription(String name, String url,
          {bool autoRefresh = false, int refreshInterval = 3600}) async =>
      (await _backend()).addSubscription(name, url,
          autoRefresh: autoRefresh, refreshInterval: refreshInterval);
  @override
  Future<Subscription> refreshSubscription(String id) async =>
      (await _backend()).refreshSubscription(id);
  @override
  Future<void> renameSubscription(String id, String name) async =>
      (await _backend()).renameSubscription(id, name);
  @override
  Future<void> deleteSubscription(String id) async =>
      (await _backend()).deleteSubscription(id);
  @override
  Future<List<Subscription>> reorderSubscriptions(
          List<String> subscriptionIDs) async =>
      (await _backend()).reorderSubscriptions(subscriptionIDs);
  @override
  Future<List<Server>> listServers({String? subscriptionID}) async =>
      (await _backend()).listServers(subscriptionID: subscriptionID);
  @override
  Future<TestResult> testServer(String id) async =>
      (await _backend()).testServer(id);
  @override
  Future<List<TestResult>> testAllServers() async =>
      (await _backend()).testAllServers();
  @override
  Future<void> addServer(Server s) async => (await _backend()).addServer(s);
  @override
  Future<void> deleteServer(String id) async =>
      (await _backend()).deleteServer(id);
  @override
  Future<List<ServerGroup>> listGroups() async =>
      (await _backend()).listGroups();
  @override
  Future<ServerGroup> createGroup(String name) async =>
      (await _backend()).createGroup(name);
  @override
  Future<void> deleteGroup(String id) async =>
      (await _backend()).deleteGroup(id);
  @override
  Future<void> moveToGroup(String serverId, String groupId) async =>
      (await _backend()).moveToGroup(serverId, groupId);
  @override
  Future<List<SpeedTestResult>> testSpeedGroup(String groupLabel,
          {Duration? testFor}) async =>
      (await _backend()).testSpeedGroup(groupLabel, testFor: testFor);
  @override
  Future<SpeedTestResult> testSpeed(String serverID,
          {Duration? testFor}) async =>
      (await _backend()).testSpeed(serverID, testFor: testFor);
  @override
  Future<SpeedTestResult> speedTest({
    String? serverID,
    SpeedProbePolicy? policy,
  }) async =>
      (await _backend()).speedTest(serverID: serverID, policy: policy);
  @override
  Future<String> exportConfig({bool includeSubscriptions = true}) async =>
      (await _backend())
          .exportConfig(includeSubscriptions: includeSubscriptions);
  @override
  Future<void> importConfig(String json, {String mode = 'merge'}) async =>
      (await _backend()).importConfig(json, mode: mode);
  @override
  Future<List<Rule>> listRules() async => (await _backend()).listRules();
  @override
  Future<Rule> addRule(Map<String, dynamic> rule) async =>
      (await _backend()).addRule(rule);
  @override
  Future<void> deleteRule(String id) async => (await _backend()).deleteRule(id);
  @override
  Future<void> reorderRules(List<String> orderedIDs) async =>
      (await _backend()).reorderRules(orderedIDs);
  @override
  Future<Preferences> getPrefs() async => (await _backend()).getPrefs();
  @override
  Future<Preferences> setPrefs(Map<String, dynamic> prefs) async =>
      (await _backend()).setPrefs(prefs);
  @override
  Future<List<Profile>> listProfiles() async =>
      (await _backend()).listProfiles();
  @override
  Future<Profile> createProfile(Map<String, dynamic> profile) async =>
      (await _backend()).createProfile(profile);
  @override
  Future<Profile> updateProfile(
          String id, Map<String, dynamic> profile) async =>
      (await _backend()).updateProfile(id, profile);
  @override
  Future<void> deleteProfile(String id) async =>
      (await _backend()).deleteProfile(id);
  @override
  Future<void> activateProfile(String id) async =>
      (await _backend()).activateProfile(id);
  @override
  Future<List<RouteProfile>> listRouteProfiles() async =>
      (await _backend()).listRouteProfiles();
  @override
  Future<RouteProfile> createRouteProfile(Map<String, dynamic> rp) async =>
      (await _backend()).createRouteProfile(rp);
  @override
  Future<RouteProfile> updateRouteProfile(
          String id, Map<String, dynamic> rp) async =>
      (await _backend()).updateRouteProfile(id, rp);
  @override
  Future<void> deleteRouteProfile(String id) async =>
      (await _backend()).deleteRouteProfile(id);
  @override
  Future<List<Connection>> listConnections() async =>
      (await _backend()).listConnections();
  @override
  Future<void> closeConnection(String id) async =>
      (await _backend()).closeConnection(id);
  @override
  Future<void> closeAllConnections() async =>
      (await _backend()).closeAllConnections();
  @override
  Future<TrafficStats> getStats() async => (await _backend()).getStats();
  @override
  Future<void> resetStats() async => (await _backend()).resetStats();
  @override
  Future<DNSConfig> getDNS() async => (await _backend()).getDNS();
  @override
  Future<DNSConfig> setDNS(Map<String, dynamic> dns) async =>
      (await _backend()).setDNS(dns);
  @override
  Future<TestResult> testURL(String url, String serverID) async =>
      (await _backend()).testURL(url, serverID);
  @override
  Future<TestResult> testIP(String serverID) async =>
      (await _backend()).testIP(serverID);
  @override
  Future<WARPConfig> getWARP() async => (await _backend()).getWARP();
  @override
  Future<WARPConfig> setWARP(Map<String, dynamic> warp) async =>
      (await _backend()).setWARP(warp);
  @override
  Future<Map<String, dynamic>> importClipboard(String raw) async =>
      (await _backend()).importClipboard(raw);
  @override
  Future<Map<String, dynamic>> importLink(String link) async =>
      (await _backend()).importLink(link);
  @override
  Future<Map<String, dynamic>> getDiag() async => (await _backend()).getDiag();
  @override
  Future<List<Egress>> listEgresses() async =>
      (await _backend()).listEgresses();
  @override
  Future<Egress> addEgress(Map<String, dynamic> egress) async =>
      (await _backend()).addEgress(egress);
  @override
  Future<Egress> updateEgress(String id, Map<String, dynamic> egress) async =>
      (await _backend()).updateEgress(id, egress);
  @override
  Future<void> deleteEgress(String id) async =>
      (await _backend()).deleteEgress(id);
  @override
  Future<void> toggleEgress(String id, bool active) async =>
      (await _backend()).toggleEgress(id, active);
  @override
  Future<BillingProfile> getBillingProfile() async =>
      (await _backend()).getBillingProfile();
  @override
  Future<void> linkBillingAccount(int telegramId,
          {String? sessionToken}) async =>
      (await _backend())
          .linkBillingAccount(telegramId, sessionToken: sessionToken);
  @override
  Future<void> unlinkBillingAccount() async =>
      (await _backend()).unlinkBillingAccount();
  @override
  Future<TopupResponse> createTopup({
    required double amount,
    int? days,
    String? description,
  }) async =>
      (await _backend()).createTopup(
        amount: amount,
        days: days,
        description: description,
      );
  @override
  Future<TopupStatusResponse> getTopupStatus(int invoiceId) async =>
      (await _backend()).getTopupStatus(invoiceId);

  @override
  Future<LinkResult> redeemLinkCode(String code) async =>
      (await _backend()).redeemLinkCode(code);

  @override
  Future<void> loginWithEmail(String email, String password) async =>
      (await _backend()).loginWithEmail(email, password);

  @override
  Future<List<PaymentEntry>> getPaymentHistory() async =>
      (await _backend()).getPaymentHistory();

  @override
  Future<UnifiedAccount?> getUnifiedAccount() async =>
      (await _backend()).getUnifiedAccount();
  @override
  Future<UnifiedAccount> freezeAccount() async =>
      (await _backend()).freezeAccount();
  @override
  Future<UnifiedAccount> unfreezeAccount() async =>
      (await _backend()).unfreezeAccount();
  @override
  Future<List<CheckoutProviderOption>> getCheckoutOptions() async =>
      (await _backend()).getCheckoutOptions();
  @override
  Future<CheckoutSession> createCheckout(
          {required int amountRub, required String provider}) async =>
      (await _backend())
          .createCheckout(amountRub: amountRub, provider: provider);
  @override
  Future<RotatedSubscriptionLink> rotateSubscriptionLink() async =>
      (await _backend()).rotateSubscriptionLink();

  @override
  Future<ProviderManifest> getProviderManifest() async =>
      (await _backend()).getProviderManifest();

  @override
  Future<Map<String, NodeHealth>> getGroupHealth(String groupId) async =>
      (await _backend()).getGroupHealth(groupId);

  @override
  Future<Server> selectNodeFromGroup(String groupId) async =>
      (await _backend()).selectNodeFromGroup(groupId);

  @override
  Stream<(String, Map<String, dynamic>)> events() async* {
    yield* (await _backend()).events();
  }
}

// ─── Status ─────────────────────────────────────────────────────────

final vpnStatusProvider = StreamProvider.autoDispose<VpnStatus>((ref) async* {
  final api = ref.watch(daemonApiProvider);
  // Poll status every 2 seconds
  final controller = StreamController<VpnStatus>();
  Timer? timer;

  void fetch() async {
    if (controller.isClosed) return;
    try {
      final status = AppPlatform.isAndroid
          ? await _androidVpnStatus()
          : await api.getStatus();
      if (!controller.isClosed) controller.add(status);
    } catch (e) {
      if (!controller.isClosed) controller.add(VpnStatus());
    }
  }

  fetch();
  timer = Timer.periodic(AppConfig.statusPollInterval, (_) => fetch());

  ref.onDispose(() {
    timer?.cancel();
    if (!controller.isClosed) controller.close();
  });

  yield* controller.stream;
});

Future<VpnStatus> _androidVpnStatus() async {
  final native = await AndroidVpnService.instance.status();
  return VpnStatus(
    agentConnected: true,
    state: native.state,
    tunnelMode: 'tun',
    lastError: native.error ?? '',
  );
}

// ─── Servers ───────────────────────────────────────────────────────

final serversProvider = FutureProvider.autoDispose<List<Server>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listServers();
});

// ─── Server Groups ──────────────────────────────────────────────────

final serverGroupsProvider =
    FutureProvider.autoDispose<List<ServerGroup>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listGroups();
});

/// User-owned local collections. Official Mosaic pool groups are represented
/// separately by the provider manifest and never expose their physical nodes.
final localServerGroupsProvider =
    FutureProvider.autoDispose<List<ServerGroup>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listGroups();
});

/// Provider-owned smart groups are safe user-facing choices. Desktop obtains
/// the manifest through its loopback daemon; Android reads the production
/// capability manifest directly because no desktop daemon runs on the device.
final mosaicManifestProvider =
    FutureProvider.autoDispose<ProviderManifest>((ref) async {
  if (AppPlatform.isAndroid) {
    return AndroidMosaicAccountService.instance.getProviderManifest();
  }
  final api = ref.watch(daemonApiProvider);
  return api.getProviderManifest();
});

// ─── Subscriptions ─────────────────────────────────────────────────

final subscriptionsProvider =
    FutureProvider.autoDispose<List<Subscription>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listSubscriptions();
});

/// Trigger for "add subscription" dialog — set to true to open dialog.
/// ServersScreen watches this and resets to false after showing dialog.
final addSubscriptionTriggerProvider = StateProvider<bool>((ref) => false);

// ─── Profiles ──────────────────────────────────────────────────────

final profilesProvider = FutureProvider.autoDispose<List<Profile>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listProfiles();
});

// ─── Route Profiles ─────────────────────────────────────────────────

final routeProfilesProvider =
    FutureProvider.autoDispose<List<RouteProfile>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listRouteProfiles();
});

// ─── Rules ──────────────────────────────────────────────────────────

final rulesProvider = FutureProvider.autoDispose<List<Rule>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listRules();
});

// ─── Connections ────────────────────────────────────────────────────
//
// Polled every 3 seconds (was 1s).  The 1s poll created a new
// List<Connection> every second per active screen, and with the old
// IndexedStack the ConnectionsScreen was always mounted.  3s is still
// real-time enough for a connections table and cuts churn by 3×.

final connectionsProvider =
    StreamProvider.autoDispose<List<Connection>>((ref) async* {
  final api = ref.watch(daemonApiProvider);
  final controller = StreamController<List<Connection>>();
  Timer? timer;

  void fetch() async {
    if (controller.isClosed) return;
    try {
      final conns = await api.listConnections();
      if (!controller.isClosed) controller.add(conns);
    } catch (e) {
      if (!controller.isClosed) controller.add([]);
    }
  }

  fetch();
  timer = Timer.periodic(AppConfig.statsPollInterval, (_) => fetch());

  ref.onDispose(() {
    timer?.cancel();
    if (!controller.isClosed) controller.close();
  });

  yield* controller.stream;
});

// ─── Stats ──────────────────────────────────────────────────────────

final trafficStatsProvider =
    StreamProvider.autoDispose<TrafficStats>((ref) async* {
  final api = ref.watch(daemonApiProvider);
  final controller = StreamController<TrafficStats>();
  Timer? timer;

  void fetch() async {
    if (controller.isClosed) return;
    try {
      final stats = await api.getStats();
      if (!controller.isClosed) controller.add(stats);
    } catch (e) {
      if (!controller.isClosed) controller.add(TrafficStats());
    }
  }

  fetch();
  timer = Timer.periodic(AppConfig.logsPollInterval, (_) => fetch());

  ref.onDispose(() {
    timer?.cancel();
    if (!controller.isClosed) controller.close();
  });

  yield* controller.stream;
});

// ─── Preferences ───────────────────────────────────────────────────

final prefsProvider = FutureProvider.autoDispose<Preferences>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getPrefs();
});

// ─── Favorite Servers (q7) ──────────────────────────────────────────
//
/// Local in-memory set of favorite server IDs. Persisted to prefs.
final favoriteServersProvider =
    StateNotifierProvider<FavoriteServersNotifier, Set<String>>((ref) {
  final api = ref.watch(daemonApiProvider);
  return FavoriteServersNotifier(api, ref);
});

class FavoriteServersNotifier extends StateNotifier<Set<String>> {
  final DaemonApiBase _api;
  final Ref _ref;
  bool _loaded = false;

  FavoriteServersNotifier(this._api, this._ref) : super({}) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await _api.getPrefs();
      if (!_loaded) {
        state = prefs.favoriteServerIDs.toSet();
        _loaded = true;
      }
    } catch (_) {}
  }

  Future<void> toggle(String serverID) async {
    final next = Set<String>.from(state);
    if (next.contains(serverID)) {
      next.remove(serverID);
    } else {
      next.add(serverID);
    }
    state = next;
    // Persist
    try {
      await _api.setPrefs({'favorite_server_ids': next.toList()});
      _ref.invalidate(prefsProvider);
    } catch (_) {}
  }

  bool isFavorite(String serverID) => state.contains(serverID);
}

// ─── Theme Mode (q8) ───────────────────────────────────────────────
//
final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, String>((ref) {
  return ThemeModeNotifier(UiPreferencesService());
});

class ThemeModeNotifier extends StateNotifier<String> {
  final UiPreferencesService _preferences;
  bool _loaded = false;

  ThemeModeNotifier(this._preferences) : super('system') {
    _load();
  }

  static const values = ['system', 'light', 'dark'];

  Future<void> _load() async {
    final mode = await _preferences.readThemeMode();
    if (!_loaded && values.contains(mode)) {
      state = mode!;
    }
    _loaded = true;
  }

  Future<void> set(String mode) async {
    if (!values.contains(mode)) return;
    state = mode;
    await _preferences.writeThemeMode(mode);
  }

  ThemeMode get flutterThemeMode => switch (state) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}

// ─── Language (i18n) ─────────────────────────────────────────────
//
final languageProvider = StateNotifierProvider<LanguageNotifier, String>((ref) {
  return LanguageNotifier(UiPreferencesService());
});

class LanguageNotifier extends StateNotifier<String> {
  final UiPreferencesService _preferences;
  bool _loaded = false;

  LanguageNotifier(this._preferences) : super('system') {
    _load();
  }

  static const values = ['system', 'en', 'ru'];

  Future<void> _load() async {
    final language = await _preferences.readLanguage();
    if (!_loaded && values.contains(language)) {
      state = language!;
    }
    _loaded = true;
  }

  Future<void> set(String lang) async {
    if (!values.contains(lang)) return;
    state = lang;
    await _preferences.writeLanguage(lang);
  }
}

// ─── WARP Config ────────────────────────────────────────────────────

final warpConfigProvider = FutureProvider.autoDispose<WARPConfig>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getWARP();
});

// ─── DNS Config ─────────────────────────────────────────────────────

final dnsConfigProvider = FutureProvider.autoDispose<DNSConfig>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getDNS();
});

// ─── Egresses ────────────────────────────────────────────────────────

final egressesProvider = FutureProvider.autoDispose<List<Egress>>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.listEgresses();
});

// ─── Events ─────────────────────────────────────────────────────────

final eventsProvider =
    StreamProvider.autoDispose<(String, Map<String, dynamic>)>((ref) async* {
  final api = ref.watch(daemonApiProvider);
  yield* api.events();
});

// ─── Client Location (GeoIP) ─────────────────────────────────────────

/// Client's real location via IP geolocation.
/// Returns (lat, lon, city, country). Falls back to Moscow if lookup fails.
/// NOT autoDispose — the location should persist across widget rebuilds so
/// the "You" pin doesn't reset to Moscow on every dashboard refresh.
final clientLocationProvider =
    FutureProvider<({double lat, double lon, String city, String country})>(
        (ref) async {
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.receiveTimeout,
    ));
    // ip-api.com is free, no API key required, supports HTTPS
    final r = await dio.get<Map<String, dynamic>>('https://ipapi.co/json/');
    final data = r.data ?? {};
    final lat = (data['latitude'] as num?)?.toDouble() ?? 55.75;
    final lon = (data['longitude'] as num?)?.toDouble() ?? 37.62;
    final city = (data['city'] as String?) ?? 'Moscow';
    final country = (data['country_name'] as String?) ?? 'Russia';
    return (lat: lat, lon: lon, city: city, country: country);
  } catch (_) {
    // Fallback: ip-api.com over HTTP
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
      ));
      final r = await dio.get<Map<String, dynamic>>('http://ip-api.com/json/');
      final data = r.data ?? {};
      final lat = (data['lat'] as num?)?.toDouble() ?? 55.75;
      final lon = (data['lon'] as num?)?.toDouble() ?? 37.62;
      final city = (data['city'] as String?) ?? 'Moscow';
      final country = (data['country'] as String?) ?? 'Russia';
      return (lat: lat, lon: lon, city: city, country: country);
    } catch (_) {
      return (lat: 55.75, lon: 37.62, city: 'Moscow', country: 'Russia');
    }
  }
});
