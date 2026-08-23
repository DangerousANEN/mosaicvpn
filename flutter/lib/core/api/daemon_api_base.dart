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

  /// Connects an explicit server from a user-owned third-party subscription.
  Future<void> connect(String serverID);

  /// Resolves and connects a provider smart group entirely inside the daemon.
  /// The client receives no physical pool node ID or endpoint details.
  Future<void> connectGroup(String groupID);

  /// Returns a bounded opaque candidate subset for a smart group. Endpoint
  /// details remain inside the local daemon; this is not a UI server list.
  Future<SmartGroupCandidateShard> getCandidateShard(
      String groupID, String installationID);

  /// Runs a bounded probe from the user's device through the local daemon.
  Future<SmartGroupProbeResult> probeGroupCandidate(
      String groupID, String candidateID);

  /// Connects a candidate only after the daemon verifies it belongs to groupID.
  Future<void> connectGroupCandidate(String groupID, String candidateID);

  Future<void> disconnect();

  /// Stops the local daemon after it has disconnected the active runtime.
  /// Desktop callers use this only for an explicit application exit.
  Future<void> shutdownDaemon();

  // ─── Subscriptions ─────────────────────────────────────────────────

  Future<List<Subscription>> listSubscriptions();
  Future<Subscription> addSubscription(String name, String url,
      {bool autoRefresh = false, int refreshInterval = 3600});

  /// Attaches a browser-authorized provider source with its provider identity.
  /// This is deliberately distinct from a generic imported subscription URL.
  Future<Subscription> enrollProviderSubscription({
    required String providerId,
    required String providerAccountId,
    required String subscriptionName,
    required String subscriptionUrl,
    String? sessionToken,
    String? directToken,
    String? username,
  });

  Future<Subscription> refreshSubscription(String id);
  Future<void> renameSubscription(String id, String name);
  Future<void> deleteSubscription(String id);

  /// Persists a complete subscription order after desktop drag-and-drop.
  Future<List<Subscription>> reorderSubscriptions(List<String> subscriptionIDs);

  // ─── Servers ───────────────────────────────────────────────────────

  Future<List<Server>> listServers({String? subscriptionID});
  Future<TestResult> testServer(String id);
  Future<List<TestResult>> testAllServers();

  /// Latency probe for a manifest direct route (single server). Only the
  /// Android hosted facade implements it; desktop daemons reject it.
  Future<TestResult> testDirectRoute(String groupID) =>
      Future.error(UnimplementedError());

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
  Future<SpeedTestResult> speedTest({
    String? serverID,
    SpeedProbePolicy? policy,
  });

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

  /// Redeems a one-time code shown by Telegram or the website. When
  /// [subscriptionId] is set, the resulting cabinet is attached only to that
  /// existing source; the source remains a normal URL subscription.
  Future<LinkResult> redeemLinkCode(String code, {String? subscriptionId});

  /// Authenticates a non-Telegram account and installs its personal direct feed.
  Future<void> loginWithEmail(String email, String password);

  /// Payment history, newest first.
  Future<List<PaymentEntry>> getPaymentHistory();

  // ─── Unified account (wallet, access and secure subscription link) ───

  /// Returns null until this device is linked to a Mosaic account.
  Future<UnifiedAccount?> getUnifiedAccount();
  Future<UnifiedAccount> freezeAccount();
  Future<UnifiedAccount> unfreezeAccount();
  Future<List<CheckoutProviderOption>> getCheckoutOptions();
  Future<CheckoutSession> createCheckout({
    required int amountRub,
    required String provider,
  });
  Future<RotatedSubscriptionLink> rotateSubscriptionLink();

  // ─── Provider Manifest ─────────────────────────────────────────────

  /// Returns a provider manifest scoped to one subscription when supplied.
  /// Omit [subscriptionId] only for legacy callers that have no selection yet.
  Future<ProviderManifest> getProviderManifest({String? subscriptionId});

  // ─── Pool / Group Selection ────────────────────────────────────────

  Future<Map<String, NodeHealth>> getGroupHealth(String groupId);
  Future<Server> selectNodeFromGroup(String groupId);

  // ─── Events (SSE) ─────────────────────────────────────────────────

  Stream<(String, Map<String, dynamic>)> events();
}
