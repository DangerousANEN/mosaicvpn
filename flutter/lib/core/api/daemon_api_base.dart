import 'dart:async';

import '../models/models.dart';

/// Abstract interface shared by both the real [DaemonApi] and the
/// [MockDaemonApi].  Riverpod providers depend on this type so the app can
/// transparently fall back to mock data when the Go daemon is not running.
///
/// Methods that exist only in the mock (server/group CRUD) are declared here
/// as well and the real [DaemonApi] throws [UnimplementedError] for them.
abstract class DaemonApiBase {
  // ─── Status & Connection ──────────────────────────────────────────

  Future<VpnStatus> getStatus();
  Future<void> connect(String serverID);
  Future<void> disconnect();

  // ─── Subscriptions ─────────────────────────────────────────────────

  Future<List<Subscription>> listSubscriptions();
  Future<Subscription> addSubscription(String name, String url,
      {bool autoRefresh = false, int refreshInterval = 3600});
  Future<Subscription> refreshSubscription(String id);
  Future<void> renameSubscription(String id, String name);
  Future<void> deleteSubscription(String id);

  // ─── Servers ───────────────────────────────────────────────────────

  Future<List<Server>> listServers({String? subscriptionID});
  Future<TestResult> testServer(String id);
  Future<List<TestResult>> testAllServers();

  // Mock-only server CRUD (real daemon throws UnimplementedError)
  Future<void> addServer(Server s);
  Future<void> deleteServer(String id);

  // ─── Server Groups ──────────────────────────────────────────────────

  Future<List<ServerGroup>> listGroups();
  Future<ServerGroup> createGroup(String name);
  Future<void> deleteGroup(String id);
  Future<void> moveToGroup(String serverId, String groupId);

  // ─── Speed Tests ────────────────────────────────────────────────────

  Future<List<SpeedTestResult>> testSpeedGroup(String groupLabel,
      {Duration? testFor});
  Future<SpeedTestResult> testSpeed(String serverID, {Duration? testFor});
  Future<SpeedTestResult> speedTest({String? serverID});

  // ─── Backup / Restore ───────────────────────────────────────────────

  Future<String> exportConfig({bool includeSubscriptions = true});
  Future<void> importConfig(String json, {String mode = 'merge'});

  // ─── Routing Rules ────────────────────────────────────────────────

  Future<List<Rule>> listRules();
  Future<Rule> addRule(Map<String, dynamic> rule);
  Future<void> deleteRule(String id);
  Future<void> reorderRules(List<String> orderedIDs);

  // ─── Preferences ──────────────────────────────────────────────────

  Future<Preferences> getPrefs();
  Future<Preferences> setPrefs(Map<String, dynamic> prefs);

  // ─── Profiles ─────────────────────────────────────────────────────

  Future<List<Profile>> listProfiles();
  Future<Profile> createProfile(Map<String, dynamic> profile);
  Future<Profile> updateProfile(String id, Map<String, dynamic> profile);
  Future<void> deleteProfile(String id);
  Future<void> activateProfile(String id);

  // ─── Route Profiles ────────────────────────────────────────────────

  Future<List<RouteProfile>> listRouteProfiles();
  Future<RouteProfile> createRouteProfile(Map<String, dynamic> rp);
  Future<RouteProfile> updateRouteProfile(String id, Map<String, dynamic> rp);
  Future<void> deleteRouteProfile(String id);

  // ─── Connections ──────────────────────────────────────────────────

  Future<List<Connection>> listConnections();
  Future<void> closeConnection(String id);
  Future<void> closeAllConnections();

  // ─── Stats ────────────────────────────────────────────────────────

  Future<TrafficStats> getStats();
  Future<void> resetStats();

  // ─── DNS ──────────────────────────────────────────────────────────

  Future<DNSConfig> getDNS();
  Future<DNSConfig> setDNS(Map<String, dynamic> dns);

  // ─── Tests (URL / IP) ─────────────────────────────────────────────

  Future<TestResult> testURL(String url, String serverID);
  Future<TestResult> testIP(String serverID);

  // ─── WARP ─────────────────────────────────────────────────────────

  Future<WARPConfig> getWARP();
  Future<WARPConfig> setWARP(Map<String, dynamic> warp);

  // ─── Import ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> importClipboard(String raw);
  Future<Map<String, dynamic>> importLink(String link);

  // ─── Diag ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getDiag();

  // ─── Egresses ─────────────────────────────────────────────────────

  Future<List<Egress>> listEgresses();
  Future<Egress> addEgress(Map<String, dynamic> egress);
  Future<Egress> updateEgress(String id, Map<String, dynamic> egress);
  Future<void> deleteEgress(String id);
  Future<void> toggleEgress(String id, bool active);

  // ─── Billing ───────────────────────────────────────────────────────

  Future<BillingProfile> getBillingProfile();
  Future<void> linkBillingAccount(int telegramId, {String? sessionToken});
  Future<void> unlinkBillingAccount();
  Future<TopupResponse> createTopup({
    required double amount,
    int? days,
    String? description,
  });
  Future<TopupStatusResponse> getTopupStatus(int invoiceId);

  // ─── Account cabinet (T-19) ────────────────────────────────────────

  /// Redeems a pairing code shown by the Telegram bot.
  Future<LinkResult> redeemLinkCode(String code);

  /// Payment history, newest first.
  Future<List<PaymentEntry>> getPaymentHistory();

  // ─── Provider Manifest ─────────────────────────────────────────────

  Future<ProviderManifest> getProviderManifest();

  // ─── Pool / Group Selection ────────────────────────────────────────

  Future<Map<String, NodeHealth>> getGroupHealth(String groupId);
  Future<Server> selectNodeFromGroup(String groupId);

  // ─── Events (SSE) ─────────────────────────────────────────────────

  Stream<(String, Map<String, dynamic>)> events();
}
