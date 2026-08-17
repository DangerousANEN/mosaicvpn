import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';

import '../models/models.dart';
import '../utils/city_coords.dart';
import 'daemon_api_base.dart';

/// Mock implementation of the daemon API that returns fake data.
/// This allows the Flutter UI to be tested without the Go daemon running.
///
/// To switch back to the real daemon, change `daemonApiProvider` in
/// `vpn_providers.dart` to use `DaemonApi` instead of `MockDaemonApi`.
class MockDaemonApi implements DaemonApiBase {
  @override
  Future<void> shutdownDaemon() async {
    await disconnect();
  }

  // ─── In-memory state ──────────────────────────────────────────────
  final List<Subscription> _subscriptions = [];
  final List<Server> _servers = [];
  VpnStatus _status = VpnStatus(agentConnected: true);
  final List<Rule> _rules = [];
  final List<Profile> _profiles = [];
  final List<RouteProfile> _routeProfiles = [];
  final List<Connection> _connections = [];
  TrafficStats _stats = TrafficStats();
  Preferences _prefs = Preferences();
  DNSConfig _dns = const DNSConfig();
  WARPConfig _warp = WARPConfig();
  final List<Egress> _egresses = [];
  final List<ServerGroup> _groups = [];
  BillingProfile _billingProfile = BillingProfile(
    linked: true,
    telegramId: 123456789,
    username: 'mock_user',
    shortUuid: 'a1b2c3d4',
    status: 'active',
    tag: 'squad_alpha',
    squadName: 'squad_alpha',
    email: 'user@example.com',
    trafficLimitBytes: 100 * 1024 * 1024 * 1024,
    usedTrafficBytes: 15 * 1024 * 1024 * 1024,
    expireAt: DateTime.now().add(const Duration(days: 30)),
    daysLeft: 30,
    description: 'Mock MosaicVPN billing profile',
  );
  final Map<int, TopupStatusResponse> _mockTopups = {};
  int _nextInvoiceId = 1001;
  final _rand = Random(42);

  MockDaemonApi() {
    // Seed the implicit "Ungrouped" group so the UI can always render it.
    _groups.add(ServerGroup.ungrouped());
    _seedData();
  }

  void _seedData() {
    // No default subscriptions or servers initially (q10/user choice - empty start)

    // ── Default status ──
    _status = VpnStatus(
      agentConnected: true,
      state: 'disconnected',
      tunnelMode: 'tun',
    );

    // ── Routing rules ──
    _rules.addAll([
      const Rule(
          id: 'rule-1',
          name: 'Block Ads',
          action: RuleAction.block,
          match: RuleMatch(domainSuffix: [
            'doubleclick.net',
            'googlesyndication.com',
            'googleadservices.com'
          ]),
          priority: 10),
      const Rule(
          id: 'rule-2',
          name: 'Direct Local',
          action: RuleAction.direct,
          match: RuleMatch(
              ipCIDR: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']),
          priority: 20),
      const Rule(
          id: 'rule-3',
          name: 'Proxy RU Sites',
          action: RuleAction.proxy,
          match: RuleMatch(geosite: ['ru']),
          priority: 30),
    ]);

    // ── Profiles ──
    _profiles.addAll([
      Profile(
          id: 'prof-1',
          name: 'Default',
          icon: '🛡',
          color: '#6366F1',
          tunnelMode: 'tun',
          killSwitch: true,
          autoConnect: true,
          createdAt: DateTime.now().subtract(const Duration(days: 30)),
          updatedAt: DateTime.now().subtract(const Duration(days: 5))),
      Profile(
          id: 'prof-2',
          name: 'Stealth',
          icon: '🥷',
          color: '#10B981',
          tunnelMode: 'proxy',
          killSwitch: false,
          autoConnect: false,
          createdAt: DateTime.now().subtract(const Duration(days: 15)),
          updatedAt: DateTime.now().subtract(const Duration(days: 2))),
    ]);

    // ── Route profiles ──
    _routeProfiles.addAll([
      RouteProfile(
          id: 'rp-1',
          name: 'Bypass RU',
          description: 'Direct route for Russian sites',
          ruleIDs: ['rule-2', 'rule-3'],
          createdAt: DateTime.now().subtract(const Duration(days: 20)),
          updatedAt: DateTime.now().subtract(const Duration(days: 10))),
    ]);

    // ── Connections (simulated active flows) ──
    _connections.addAll([
      Connection(
          id: 'conn-1',
          network: 'tcp',
          outbound: 'proxy',
          domain: 'youtube.com',
          ip: '142.250.0.1',
          port: 443,
          sourceIP: '127.0.0.1',
          sourcePort: 50023,
          process: 'chrome.exe',
          upload: 145000,
          download: 2400000,
          startAt: DateTime.now().subtract(const Duration(minutes: 5)),
          chain: 'proxy → vless',
          rule: 'Proxy RU Sites'),
      Connection(
          id: 'conn-2',
          network: 'tcp',
          outbound: 'direct',
          domain: 'localhost',
          ip: '127.0.0.1',
          port: 5432,
          sourceIP: '127.0.0.1',
          sourcePort: 50024,
          process: 'psql.exe',
          upload: 1200,
          download: 8500,
          startAt: DateTime.now().subtract(const Duration(minutes: 12)),
          chain: 'direct',
          rule: 'Direct Local'),
      Connection(
          id: 'conn-3',
          network: 'tcp',
          outbound: 'block',
          domain: 'ads.doubleclick.net',
          ip: '142.250.0.2',
          port: 443,
          sourceIP: '127.0.0.1',
          sourcePort: 50025,
          process: 'chrome.exe',
          upload: 0,
          download: 0,
          startAt: DateTime.now().subtract(const Duration(minutes: 3)),
          chain: 'block',
          rule: 'Block Ads'),
    ]);

    // ── Stats ──
    _stats = TrafficStats(
      totalUpload: 145000000,
      totalDownload: 2400000000,
      uploadSpeed: 250000,
      downloadSpeed: 3200000,
      activeConnections: 3,
      uptime: const Duration(hours: 1, minutes: 23),
      since: DateTime.now().subtract(const Duration(hours: 1, minutes: 23)),
    );

    // ── Egresses (proxy listeners) ──
    _egresses.addAll([
      const Egress(
        id: 'egr-1',
        name: 'Default',
        type: 'mixed',
        listen: '127.0.0.1',
        port: 2080,
        serverID: 'de-fra-01',
        serverName: 'Frankfurt',
        active: true,
        connections: 5,
        upload: 145000,
        download: 2400000,
      ),
      const Egress(
        id: 'egr-2',
        name: 'Gaming',
        type: 'socks',
        listen: '127.0.0.1',
        port: 2081,
        serverID: 'jp-tyo-01',
        serverName: 'Tokyo',
        active: true,
        connections: 2,
        upload: 12000,
        download: 89000,
      ),
      const Egress(
        id: 'egr-3',
        name: 'Streaming',
        type: 'http',
        listen: '127.0.0.1',
        port: 2082,
        serverID: 'us-nyc-01',
        serverName: 'New York',
        active: false,
        connections: 0,
        upload: 0,
        download: 0,
      ),
    ]);
  }

  // ─── Helpers ─────────────────────────────────────────────────────
  /// Test doubles return asynchronously without scheduling timers. This keeps
  /// widget-test teardown deterministic while preserving the Future-based API.
  Future<T> _delay<T>(T value) => Future<T>.value(value);

  Future<void> _delayVoid() => Future<void>.value();

  // ─── Status & Connection ──────────────────────────────────────────

  @override
  Future<VpnStatus> getStatus() {
    // Sync prefs → status so dashboard reflects settings changes live
    _status = _status.copyWith(
      tunnelMode: _prefs.tunnelMode,
      killSwitch: _prefs.killSwitch,
      allowLAN: _prefs.allowLAN,
    );
    return _delay(_status);
  }

  @override
  Future<void> connect(String serverID) async {
    await _delayVoid();
    final server = _servers.firstWhere(
      (s) => s.id == serverID,
      orElse: () => Server(id: serverID, name: serverID),
    );
    // Persist last server ID for auto-reconnect (q3)
    _prefs = _prefs.copyWith(lastServerID: serverID);
    _status = VpnStatus(
      agentConnected: true,
      state: 'connected',
      tunnelMode: _prefs.tunnelMode,
      killSwitch: _prefs.killSwitch,
      allowLAN: _prefs.allowLAN,
      server: server,
      latencyMS: server.lastTestMS,
      bytesIn: 0,
      bytesOut: 0,
      connectedSince: DateTime.now(),
    );
  }

  @override
  Future<void> connectGroup(String groupID) async {
    // Legacy group connect remains available for older screens. New clients
    // request a bounded opaque candidate shard and select locally.
    await connect('group:$groupID');
  }

  @override
  Future<SmartGroupCandidateShard> getCandidateShard(
      String groupID, String installationID) async {
    await _delayVoid();
    return SmartGroupCandidateShard(
      groupId: groupID,
      version: 'mock-$groupID',
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      candidateIds: List<String>.generate(
          8, (index) => 'candidate:$groupID:$installationID:$index'),
    );
  }

  @override
  Future<SmartGroupProbeResult> probeGroupCandidate(
      String groupID, String candidateID) async {
    await _delayVoid();
    final seed = candidateID.codeUnits.fold<int>(0, (sum, code) => sum + code);
    final latency = 24 + (seed % 110);
    final loss = seed % 13 == 0 ? 33.3 : 0.0;
    return SmartGroupProbeResult(
      groupId: groupID,
      candidateId: candidateID,
      successful: loss < 100,
      samples: 3,
      successes: loss > 0 ? 2 : 3,
      lossPercent: loss,
      medianLatencyMs: latency,
      p95LatencyMs: latency + (seed % 20),
      jitterMs: seed % 20,
      checkedAt: DateTime.now(),
      probeKind: 'mock_transport',
    );
  }

  @override
  Future<void> connectGroupCandidate(String groupID, String candidateID) async {
    // Candidate IDs remain opaque to the UI. The mock tracks the selected
    // group rather than turning a physical candidate into a visible route.
    await connect('group:$groupID');
  }

  @override
  Future<void> disconnect() async {
    await _delayVoid();
    _status = VpnStatus(
      agentConnected: true,
      state: 'disconnected',
      tunnelMode: _prefs.tunnelMode,
      killSwitch: _prefs.killSwitch,
      allowLAN: _prefs.allowLAN,
    );
  }

  // ─── Subscriptions ───────────────────────────────────────────────

  @override
  Future<List<Subscription>> listSubscriptions() => _delay(
        <Subscription>[..._subscriptions],
      );

  @override
  Future<Subscription> addSubscription(String name, String url,
      {bool autoRefresh = false, int refreshInterval = 3600}) async {
    final id = 'sub-${_subscriptions.length + 1}-${_rand.nextInt(9999)}';
    final sub = Subscription(
      id: id,
      name: name,
      url: url,
      autoRefresh: autoRefresh,
      refreshIntervalSeconds: refreshInterval,
      serverCount: 0,
      lastFetched: DateTime.now(),
    );
    _subscriptions.add(sub);
    await _parseAndMergeSubscription(sub);
    return _subscriptions.firstWhere((s) => s.id == id);
  }

  @override
  Future<Subscription> refreshSubscription(String id) async {
    final idx = _subscriptions.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      final sub = Subscription(
        id: id,
        name: _subscriptions[idx].name,
        url: _subscriptions[idx].url,
        autoRefresh: _subscriptions[idx].autoRefresh,
        refreshIntervalSeconds: _subscriptions[idx].refreshIntervalSeconds,
        serverCount: _subscriptions[idx].serverCount,
        lastFetched: DateTime.now(),
      );
      _subscriptions[idx] = sub;
      await _parseAndMergeSubscription(sub);
      return _subscriptions[idx];
    }
    throw Exception('Subscription not found');
  }

  // ─── Real Subscription Parsing in Mock API ───
  Future<void> _parseAndMergeSubscription(Subscription sub) async {
    _servers.removeWhere((s) => s.subscriptionID == sub.id);

    String? content;

    if (sub.url.startsWith('http://') || sub.url.startsWith('https://')) {
      // Fetch from URL
      try {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
        ));
        final response = await dio.get<String>(sub.url);
        content = response.data;
      } catch (e) {
        final idx = _subscriptions.indexWhere((s) => s.id == sub.id);
        if (idx >= 0) {
          _subscriptions[idx] = Subscription(
            id: sub.id,
            name: sub.name,
            url: sub.url,
            autoRefresh: sub.autoRefresh,
            refreshIntervalSeconds: sub.refreshIntervalSeconds,
            serverCount: 0,
            lastFetched: DateTime.now(),
            hasError: true,
            lastError: e.toString(),
          );
        }
        // Fallback below
      }
    } else {
      // Treat URL field as raw subscription content (base64 or plaintext URIs)
      content = sub.url;
    }

    if (content != null && content.isNotEmpty) {
      final parsedServers =
          _parseSubscriptionContent(content, sub.id, sub.name);
      if (parsedServers.isNotEmpty) {
        _servers.addAll(parsedServers);
        final idx = _subscriptions.indexWhere((s) => s.id == sub.id);
        if (idx >= 0) {
          _subscriptions[idx] = Subscription(
            id: sub.id,
            name: sub.name,
            url: sub.url,
            autoRefresh: sub.autoRefresh,
            refreshIntervalSeconds: sub.refreshIntervalSeconds,
            serverCount: parsedServers.length,
            lastFetched: DateTime.now(),
            hasError: false,
            lastError: '',
          );
        }
        return;
      }
    }

    // Fallback: generate some mockup servers if parsing failed entirely
    final cities = [
      ('New York', 'United States', 40.71, -74.01, Protocol.vless),
      ('London', 'United Kingdom', 51.50, -0.12, Protocol.trojan),
      ('Tokyo', 'Japan', 35.68, 139.65, Protocol.vmess),
    ];
    final generated = <Server>[];
    for (final (cityName, country, lat, lon, proto) in cities) {
      generated.add(Server(
        id: '${sub.id}-${cityName.toLowerCase().replaceAll(' ', '-')}',
        name: '${sub.name} - $cityName',
        address: '10.${_rand.nextInt(255)}.${_rand.nextInt(255)}.1',
        port: 443,
        protocol: proto,
        country: country,
        city: cityName,
        lat: lat,
        lon: lon,
        subscriptionID: sub.id,
        lastTestMS: 20 + _rand.nextInt(180),
      ));
    }
    _servers.addAll(generated);
    final idx = _subscriptions.indexWhere((s) => s.id == sub.id);
    if (idx >= 0 && _subscriptions[idx].serverCount == 0) {
      _subscriptions[idx] = Subscription(
        id: sub.id,
        name: sub.name,
        url: sub.url,
        autoRefresh: sub.autoRefresh,
        refreshIntervalSeconds: sub.refreshIntervalSeconds,
        serverCount: generated.length,
        lastFetched: DateTime.now(),
        hasError: _subscriptions[idx].hasError,
        lastError: _subscriptions[idx].lastError,
      );
    }
  }

  List<Server> _parseSubscriptionContent(
      String content, String subID, String subName) {
    final servers = <Server>[];
    String rawText = content.trim();

    // Check if it's base64 and decode
    try {
      final cleaned = rawText.replaceAll(RegExp(r'\s+'), '');
      final decoded = utf8.decode(base64.decode(cleaned));
      rawText = decoded;
    } catch (_) {}

    final lines = rawText.split(RegExp(r'[\r\n]+'));
    int index = 1;
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      try {
        if (line.startsWith('vless://') ||
            line.startsWith('vmess://') ||
            line.startsWith('trojan://') ||
            line.startsWith('ss://')) {
          final uri = Uri.parse(line);
          final protoStr = uri.scheme;
          final proto = Protocol.fromString(protoStr);
          final host = uri.host;
          final port = uri.port != 0 ? uri.port : 443;

          String name = '$subName - Server $index';
          if (uri.fragment.isNotEmpty) {
            try {
              name = Uri.decodeComponent(uri.fragment);
            } catch (_) {
              name = uri.fragment;
            }
          }

          String country = 'Unknown';
          String city = 'Unknown';
          double lat = 0;
          double lon = 0;

          final loc = _detectLocation(name, host);
          if (loc != null) {
            country = loc.country;
            city = loc.city;
            lat = loc.lat;
            lon = loc.lon;
          }

          servers.add(Server(
            id: '$subID-server-$index-${_rand.nextInt(999)}',
            name: name,
            address: host,
            port: port,
            protocol: proto,
            country: country,
            city: city,
            lat: lat,
            lon: lon,
            subscriptionID: subID,
            lastTestMS: 20 + _rand.nextInt(180),
          ));
          index++;
        }
      } catch (_) {}
    }
    return servers;
  }

  _DetectedLoc? _detectLocation(String name, String host) {
    final cleanName = name.toLowerCase();

    final List<String> knownCities = [
      'moscow',
      'saint petersburg',
      'st petersburg',
      'novosibirsk',
      'yekaterinburg',
      'kazan',
      'vladivostok',
      'kiev',
      'kyiv',
      'minsk',
      'almaty',
      'london',
      'paris',
      'amsterdam',
      'frankfurt',
      'berlin',
      'munich',
      'zurich',
      'vienna',
      'warsaw',
      'prague',
      'stockholm',
      'helsinki',
      'oslo',
      'copenhagen',
      'dublin',
      'madrid',
      'barcelona',
      'rome',
      'milan',
      'lisbon',
      'athens',
      'bucharest',
      'istanbul',
      'new york',
      'los angeles',
      'chicago',
      'miami',
      'dallas',
      'seattle',
      'san francisco',
      'toronto',
      'montreal',
      'vancouver',
      'tokyo',
      'osaka',
      'seoul',
      'hong kong',
      'singapore',
      'bangkok',
      'kuala lumpur',
      'jakarta',
      'taipei',
      'shanghai',
      'beijing',
      'shenzhen',
      'guangzhou',
      'mumbai',
      'delhi',
      'bangalore',
      'dubai',
      'tel aviv',
      'sydney',
      'melbourne',
      'sao paulo',
      'buenos aires',
      'santiago',
      'johannesburg',
      'cairo',
      'lagos'
    ];

    for (final city in knownCities) {
      if (cleanName.contains(city)) {
        final latLon = cityToLatLon(city: city);
        if (latLon != null) {
          const cityCountry = <String, String>{
            'moscow': 'Russia',
            'saint petersburg': 'Russia',
            'st petersburg': 'Russia',
            'novosibirsk': 'Russia',
            'yekaterinburg': 'Russia',
            'kazan': 'Russia',
            'vladivostok': 'Russia',
            'kiev': 'Ukraine',
            'kyiv': 'Ukraine',
            'minsk': 'Belarus',
            'almaty': 'Kazakhstan',
            'london': 'United Kingdom',
            'paris': 'France',
            'amsterdam': 'Netherlands',
            'frankfurt': 'Germany',
            'berlin': 'Germany',
            'munich': 'Germany',
            'zurich': 'Switzerland',
            'vienna': 'Austria',
            'warsaw': 'Poland',
            'prague': 'Czech Republic',
            'stockholm': 'Sweden',
            'helsinki': 'Finland',
            'oslo': 'Norway',
            'copenhagen': 'Denmark',
            'dublin': 'Ireland',
            'madrid': 'Spain',
            'barcelona': 'Spain',
            'rome': 'Italy',
            'milan': 'Italy',
            'lisbon': 'Portugal',
            'athens': 'Greece',
            'bucharest': 'Romania',
            'istanbul': 'Turkey',
            'new york': 'United States',
            'los angeles': 'United States',
            'chicago': 'United States',
            'miami': 'United States',
            'dallas': 'United States',
            'seattle': 'United States',
            'san francisco': 'United States',
            'toronto': 'Canada',
            'montreal': 'Canada',
            'vancouver': 'Canada',
            'tokyo': 'Japan',
            'osaka': 'Japan',
            'seoul': 'South Korea',
            'hong kong': 'Hong Kong',
            'singapore': 'Singapore',
            'bangkok': 'Thailand',
            'kuala lumpur': 'Malaysia',
            'jakarta': 'Indonesia',
            'taipei': 'Taiwan',
            'shanghai': 'China',
            'beijing': 'China',
            'shenzhen': 'China',
            'guangzhou': 'China',
            'mumbai': 'India',
            'delhi': 'India',
            'bangalore': 'India',
            'dubai': 'United Arab Emirates',
            'tel aviv': 'Israel',
            'sydney': 'Australia',
            'melbourne': 'Australia',
            'sao paulo': 'Brazil',
            'buenos aires': 'Argentina',
            'santiago': 'Chile',
            'johannesburg': 'South Africa',
            'cairo': 'Egypt',
            'lagos': 'Nigeria',
          };
          final country = cityCountry[city] ?? 'Unknown';

          return _DetectedLoc(
              country, city.toUpperCase(), latLon.lat, latLon.lon);
        }
      }
    }

    final List<String> countryCodes = [
      'ru',
      'us',
      'nl',
      'de',
      'jp',
      'sg',
      'gb',
      'fr',
      'ca',
      'au',
      'br',
      'in',
      'kr',
      'se',
      'ua',
      'fi',
      'pl',
      'cz',
      'no',
      'dk',
      'es',
      'it',
      'tr'
    ];
    for (final code in countryCodes) {
      if (cleanName.contains(RegExp(r'\b' + code + r'\b')) ||
          cleanName.contains(' $code') ||
          cleanName.contains('$code ') ||
          cleanName.contains('-$code') ||
          cleanName.contains('$code-')) {
        final latLon = cityToLatLon(country: code);
        if (latLon != null) {
          const codeCountry = <String, String>{
            'ru': 'Russia',
            'us': 'United States',
            'nl': 'Netherlands',
            'de': 'Germany',
            'jp': 'Japan',
            'sg': 'Singapore',
            'gb': 'United Kingdom',
          };
          final countryName = codeCountry[code] ?? code.toUpperCase();
          return _DetectedLoc(countryName, countryName, latLon.lat, latLon.lon);
        }
      }
    }

    // Fallback: could not detect from name — derive deterministic coords
    // from host string hash so different servers get different locations
    // instead of all landing on Amsterdam.
    final hash = host.hashCode ^ cleanName.hashCode;
    // Spread across the globe: avoid extreme latitudes (>±70°)
    final rLat = ((hash & 0xFFFF) / 0xFFFF - 0.5) * 140; // -70..+70
    final rLon = (((hash >> 16) & 0xFFFF) / 0xFFFF - 0.5) * 360; // -180..+180
    return _DetectedLoc('Unknown', 'Unknown', rLat, rLon);
  }

  @override
  Future<void> renameSubscription(String id, String name) async {
    await _delayVoid();
    final idx = _subscriptions.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      _subscriptions[idx] = Subscription(
        id: id,
        name: name,
        url: _subscriptions[idx].url,
        autoRefresh: _subscriptions[idx].autoRefresh,
        refreshIntervalSeconds: _subscriptions[idx].refreshIntervalSeconds,
        serverCount: _subscriptions[idx].serverCount,
        lastFetched: _subscriptions[idx].lastFetched,
      );
    }
  }

  @override
  Future<void> deleteSubscription(String id) async {
    await _delayVoid();
    _subscriptions.removeWhere((s) => s.id == id);
    _servers.removeWhere((s) => s.subscriptionID == id);
  }

  @override
  Future<List<Subscription>> reorderSubscriptions(
      List<String> subscriptionIDs) async {
    await _delayVoid();
    if (subscriptionIDs.length != _subscriptions.length ||
        subscriptionIDs.toSet().length != subscriptionIDs.length) {
      throw ArgumentError('The complete subscription order is required');
    }
    final byID = {
      for (final subscription in _subscriptions) subscription.id: subscription
    };
    final reordered = <Subscription>[];
    for (final id in subscriptionIDs) {
      final subscription = byID[id];
      if (subscription == null) {
        throw ArgumentError('Unknown subscription: $id');
      }
      reordered.add(subscription);
    }
    _subscriptions
      ..clear()
      ..addAll(reordered);
    return List.unmodifiable(_subscriptions);
  }

  // ─── Servers ──────────────────────────────────────────────────────

  @override
  Future<List<Server>> listServers({String? subscriptionID}) async {
    final servers = subscriptionID != null
        ? _servers.where((s) => s.subscriptionID == subscriptionID).toList()
        : <Server>[..._servers];
    return _delay(servers);
  }

  @override
  Future<TestResult> testServer(String id) async {
    final server = _servers.firstWhere((s) => s.id == id);
    final latency = 15 + _rand.nextInt(185);
    await _delayVoid();
    // Update server latency
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      _servers[idx] = Server(
        id: server.id,
        name: server.name,
        address: server.address,
        port: server.port,
        protocol: server.protocol,
        country: server.country,
        city: server.city,
        lat: server.lat,
        lon: server.lon,
        subscriptionID: server.subscriptionID,
        lastTestMS: latency,
      );
    }
    return TestResult(
        serverID: id, serverName: server.name, latencyMS: latency);
  }

  @override
  Future<void> deleteServer(String id) async {
    await _delayVoid();
    _servers.removeWhere((s) => s.id == id);
  }

  @override
  Future<void> addServer(Server s) async {
    await _delayVoid();
    _servers.add(s);
  }

  // ─── Server Groups ────────────────────────────────────────────────
  @override
  Future<List<ServerGroup>> listGroups() async {
    await _delayVoid();
    // Always ensure Ungrouped is present.
    if (_groups.where((g) => g.id == ServerGroup.ungroupedId).isEmpty) {
      _groups.insert(0, ServerGroup.ungrouped());
    }
    final sorted = [..._groups]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return sorted;
  }

  @override
  Future<ServerGroup> createGroup(String name) async {
    await _delayVoid();
    final id = 'grp-${_groups.length}-${_rand.nextInt(9999)}';
    final g = ServerGroup(
      id: id,
      name: name,
      sortOrder: _groups.length,
      isDefault: false,
    );
    _groups.add(g);
    return g;
  }

  @override
  Future<void> deleteGroup(String id) async {
    await _delayVoid();
    if (id == ServerGroup.ungroupedId) return; // never delete Ungrouped
    // Re-home servers of the deleted group into Ungrouped.
    for (var i = 0; i < _servers.length; i++) {
      if (_servers[i].groupId == id) {
        _servers[i] = _servers[i].copyWith(groupId: ServerGroup.ungroupedId);
      }
    }
    _groups.removeWhere((g) => g.id == id);
  }

  @override
  Future<void> moveToGroup(String serverId, String groupId) async {
    await _delayVoid();
    final idx = _servers.indexWhere((s) => s.id == serverId);
    if (idx >= 0) {
      _servers[idx] = _servers[idx].copyWith(groupId: groupId);
    }
  }

  @override
  Future<List<TestResult>> testAllServers() async {
    final results = <TestResult>[];
    for (final s in _servers) {
      final latency = 15 + _rand.nextInt(185);
      results.add(
          TestResult(serverID: s.id, serverName: s.name, latencyMS: latency));
    }
    await _delayVoid();
    return results;
  }

  // ─── Speed Test ────────────────────────────────────────────────────
  //
  // Simulated bandwidth test. Downloads/uploads are modelled as a random
  // throughput influenced by the server's latency (lower latency → higher
  // achievable bandwidth, with diminishing returns) so the UI feels alive.

  @override
  Future<SpeedTestResult> testSpeed(String serverID,
      {Duration? testFor}) async {
    final server = _servers.firstWhere((s) => s.id == serverID);
    final realDuration = 3.0 + _rand.nextInt(30) / 10.0;

    // Simulate work.
    await Future.delayed(Duration(milliseconds: (realDuration * 1000).round()));

    final latency =
        server.lastTestMS > 0 ? server.lastTestMS : 15 + _rand.nextInt(185);
    // Bandwidth modelled after latency:
    //   - ≤50ms → 80-300 Mbps
    //   - ≤120ms → 30-120 Mbps
    //   - >120ms → 5-40 Mbps
    final baseDown = latency < 50
        ? 80 + _rand.nextInt(220)
        : latency < 120
            ? 30 + _rand.nextInt(90)
            : 5 + _rand.nextInt(35);
    final baseUp = (baseDown * 0.65).toInt() + _rand.nextInt(15);
    final jitter = 1 + _rand.nextInt(latency < 80 ? 8 : 25);

    // Persist speed test results back to the in-memory server record so
    // the UI can show a speed badge next to the latency.
    final downBps = baseDown * 125000;
    final upBps = baseUp * 125000;
    final idx = _servers.indexOf(server);
    _servers[idx] = server.copyWith(
      downSpeed: downBps,
      upSpeed: upBps,
      lastTestMS: latency,
    );

    return SpeedTestResult(
      target: serverID,
      serverName: server.name,
      downloadBps: downBps, // Mbps → bytes/s
      uploadBps: upBps,
      latencyMS: latency,
      jitterMS: jitter,
      durationSeconds: realDuration,
    );
  }

  /// Run a speed test against every server in a group. Returns one
  /// `SpeedTestResult` per server. Tests are sequential (mock) so that the
  /// UI can show a real progress indicator.
  @override
  Future<List<SpeedTestResult>> testSpeedGroup(String groupLabel,
      {Duration? testFor}) async {
    final results = <SpeedTestResult>[];
    // Resolve which servers belong to this group label.
    final targetServers = _servers.where((s) {
      if (s.subscriptionID.isNotEmpty && s.subscriptionID != 'manual') {
        return s.subscriptionID == groupLabel;
      }
      final gid = (s.groupId.isEmpty || s.groupId == ServerGroup.ungroupedId)
          ? ServerGroup.ungroupedId
          : s.groupId;
      return gid == groupLabel || gid.contains(groupLabel);
    }).toList();

    for (final s in targetServers) {
      results.add(await testSpeed(s.id, testFor: const Duration(seconds: 2)));
    }
    return results;
  }

  // ─── Backup / Restore (Phase 2.5) ──────────────────────────────────

  /// Serialises the entire mock state (servers, groups, subscriptions,
  /// preferences, rules) into a JSON string. When `includeSubscriptions`
  /// is false, the `url` field of each subscription is blanked out so the
  /// export does not leak remote feed URLs.
  @override
  Future<String> exportConfig({
    bool includeSubscriptions = true,
    String mode = 'merge', // dummy param for api symmetry
  }) async {
    await _delayVoid();
    final serverJson = _servers.map((s) => s.toJson()).toList();
    final groupJson = _groups.map((g) => g.toJson()).toList();
    final subsJson = _subscriptions.map((sub) {
      final j = sub.toJson();
      if (!includeSubscriptions) j['url'] = '';
      return j;
    }).toList();
    final rulesJson = _rules.map((r) {
      return {
        'id': r.id,
        'name': r.name,
        'action': r.action.value,
        'enabled': r.enabled,
        'priority': r.priority,
      };
    }).toList();
    final prefs = _prefs;
    final bundle = {
      'schema_version': 1,
      'app': 'MosaicBox',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'preferences': prefs.toJson(),
      'servers': serverJson,
      'groups': groupJson,
      'subscriptions': subsJson,
      'rules': rulesJson,
    };
    return const JsonEncoder.withIndent('  ').convert(bundle);
  }

  /// Imports a JSON config string previously produced by [exportConfig].
  /// `mode` = "merge" adds non-conflicting items (keeps existing IDs);
  /// `mode` = "replace" wipes servers/groups/subscriptions/rules before
  /// loading (preferences are always overwritten).
  @override
  Future<void> importConfig(String json, {String mode = 'merge'}) async {
    await _delayVoid();
    final Map<String, dynamic> bundle;
    try {
      bundle = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Invalid backup file: not a JSON object');
    }
    if (bundle['app'] != null && bundle['app'] != 'MosaicBox') {
      throw Exception('Not a MosaicBox backup file');
    }

    // ── Preferences (always replace) ──
    if (bundle['preferences'] is Map<String, dynamic>) {
      _prefs =
          Preferences.fromJson(bundle['preferences'] as Map<String, dynamic>);
    }

    if (mode == 'replace') {
      _servers.clear();
      _groups.clear();
      _subscriptions.clear();
      _rules.clear();
    }

    // ── Groups (deduplicate by id) ──
    final existingGroupIds = _groups.map((g) => g.id).toSet();
    for (final gj in (bundle['groups'] as List? ?? const [])) {
      final g = ServerGroup.fromJson(gj as Map<String, dynamic>);
      if (!existingGroupIds.contains(g.id)) {
        _groups.add(g);
        existingGroupIds.add(g.id);
      }
    }
    // Always ensure "Ungrouped" exists.
    if (!_groups.any((g) => g.id == ServerGroup.ungroupedId)) {
      _groups.insert(0, ServerGroup.ungrouped());
    }

    // ── Subscriptions (deduplicate by id) ──
    final existingSubIds = _subscriptions.map((s) => s.id).toSet();
    for (final sj in (bundle['subscriptions'] as List? ?? const [])) {
      final sub = Subscription.fromJson(sj as Map<String, dynamic>);
      if (!existingSubIds.contains(sub.id)) {
        _subscriptions.add(sub);
        existingSubIds.add(sub.id);
      }
    }

    // ── Servers (deduplicate by id; manual re-import keeps original ids) ──
    final existingServerIds = _servers.map((s) => s.id).toSet();
    for (final sj in (bundle['servers'] as List? ?? const [])) {
      final s = Server.fromJson(sj as Map<String, dynamic>);
      if (!existingServerIds.contains(s.id)) {
        // Assign a fresh id in merge mode if empty or conflicting
        if (s.id.isEmpty) {
          final newId =
              'srv-${DateTime.now().millisecondsSinceEpoch}-${_rand.nextInt(9999)}';
          _servers.add(s.copyWith(id: newId));
        } else {
          _servers.add(s);
        }
        existingServerIds.add(s.id);
      }
    }

    // ── Rules (deduplicate by id) ──
    final existingRuleIds = _rules.map((r) => r.id).toSet();
    for (final rj in (bundle['rules'] as List? ?? const [])) {
      final m = rj as Map<String, dynamic>;
      final rule = Rule(
        id: m['id'] as String? ??
            'rule-${_rules.length}-${_rand.nextInt(9999)}',
        name: m['name'] as String? ?? 'Imported Rule',
        action: RuleAction.fromString(m['action'] as String? ?? 'proxy'),
        match: const RuleMatch(),
        enabled: m['enabled'] as bool? ?? true,
        priority: m['priority'] as int? ?? _rules.length,
      );
      if (!existingRuleIds.contains(rule.id)) {
        _rules.add(rule);
        existingRuleIds.add(rule.id);
      }
    }
  }

  // ─── Routing Rules ────────────────────────────────────────────────

  @override
  Future<List<Rule>> listRules() => _delay(<Rule>[..._rules]);

  @override
  Future<Rule> addRule(Map<String, dynamic> rule) async {
    final r = Rule(
      id: 'rule-${_rules.length + 1}-${_rand.nextInt(9999)}',
      name: rule['name'] ?? 'New Rule',
      action: RuleAction.fromString(rule['action'] ?? 'proxy'),
      enabled: rule['enabled'] ?? true,
      priority: _rules.length,
    );
    await _delayVoid();
    _rules.add(r);
    return r;
  }

  @override
  Future<void> deleteRule(String id) async {
    await _delayVoid();
    _rules.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> reorderRules(List<String> orderedIDs) async {
    await _delayVoid();
    // Re-index priorities
    for (var i = 0; i < orderedIDs.length; i++) {
      final idx = _rules.indexWhere((r) => r.id == orderedIDs[i]);
      if (idx >= 0) {
        _rules[idx] = Rule(
          id: _rules[idx].id,
          name: _rules[idx].name,
          action: _rules[idx].action,
          match: _rules[idx].match,
          enabled: _rules[idx].enabled,
          priority: i,
        );
      }
    }
  }

  // ─── Preferences ─────────────────────────────────────────────────

  @override
  Future<Preferences> getPrefs() => _delay(_prefs);

  @override
  Future<Preferences> setPrefs(Map<String, dynamic> prefs) async {
    _prefs = _prefs.copyWith(
      tunnelMode: prefs['tunnel_mode'] as String?,
      tunStack: prefs['tun_stack'] as String?,
      socksAddr: prefs['socks_addr'] as String?,
      httpAddr: prefs['http_addr'] as String?,
      mixedPort: prefs['mixed_port'] as int?,
      mtu: prefs['mtu'] as int?,
      killSwitch: prefs['kill_switch'] as bool?,
      allowLAN: prefs['allow_lan'] as bool?,
      blockIPv6: prefs['block_ipv6'] as bool?,
      dnsMode: prefs['dns_mode'] as String?,
      dnsProxied: prefs['dns_proxied'] as String?,
      dnsDirect: prefs['dns_direct'] as String?,
      shareLAN: prefs['share_lan'] as bool?,
      shareAddr: prefs['share_addr'] as String?,
      autoStart: prefs['auto_start'] as String?,
      autoConnect: prefs['auto_connect'] as bool?,
      showOnLaunch: prefs['show_on_launch'] as bool?,
      mcpEnabled: prefs['mcp_enabled'] as bool?,
      mcpAddr: prefs['mcp_addr'] as String?,
      mcpPermission: prefs['mcp_permission'] as String?,
      mcpConfirm: prefs['mcp_confirm'] as bool?,
      lastServerID: prefs['last_server_id'] as String?,
      themeMode: prefs['theme_mode'] as String?,
      favoriteServerIDs:
          (prefs['favorite_server_ids'] as List?)?.cast<String>(),
      minimizeToTray: prefs['minimize_to_tray'] as bool?,
      autoConnectEgresses: prefs['auto_connect_egresses'] as bool?,
      testUrl: prefs['test_url'] as String?,
      alwaysRunAsAdmin: prefs['always_run_as_admin'] as bool?,
    );
    await _delayVoid();
    return _prefs;
  }

  // ─── Profiles ─────────────────────────────────────────────────────

  @override
  Future<List<Profile>> listProfiles() => _delay(<Profile>[..._profiles]);

  @override
  Future<Profile> createProfile(Map<String, dynamic> profile) async {
    final p = Profile(
      id: 'prof-${_profiles.length + 1}-${_rand.nextInt(9999)}',
      name: profile['name'] ?? 'New Profile',
      icon: profile['icon'] ?? '🛡',
      color: profile['color'] ?? '#6366F1',
      tunnelMode: profile['tunnel_mode'] ?? 'tun',
      killSwitch: profile['kill_switch'] ?? true,
      autoConnect: profile['auto_connect'] ?? false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _delayVoid();
    _profiles.add(p);
    return p;
  }

  @override
  Future<Profile> updateProfile(String id, Map<String, dynamic> profile) async {
    final idx = _profiles.indexWhere((p) => p.id == id);
    await _delayVoid();
    if (idx >= 0) {
      _profiles[idx] = Profile(
        id: id,
        name: profile['name'] ?? _profiles[idx].name,
        icon: profile['icon'] ?? _profiles[idx].icon,
        color: profile['color'] ?? _profiles[idx].color,
        tunnelMode: profile['tunnel_mode'] ?? _profiles[idx].tunnelMode,
        killSwitch: profile['kill_switch'] ?? _profiles[idx].killSwitch,
        autoConnect: profile['auto_connect'] ?? _profiles[idx].autoConnect,
        createdAt: _profiles[idx].createdAt,
        updatedAt: DateTime.now(),
      );
      return _profiles[idx];
    }
    throw Exception('Profile not found');
  }

  @override
  Future<void> deleteProfile(String id) async {
    await _delayVoid();
    _profiles.removeWhere((p) => p.id == id);
  }

  @override
  Future<void> activateProfile(String id) async {
    await _delayVoid();
    // No-op in mock
  }

  // ─── Route Profiles ──────────────────────────────────────────────

  @override
  Future<List<RouteProfile>> listRouteProfiles() =>
      _delay(<RouteProfile>[..._routeProfiles]);

  @override
  Future<RouteProfile> createRouteProfile(Map<String, dynamic> rp) async {
    final r = RouteProfile(
      id: 'rp-${_routeProfiles.length + 1}-${_rand.nextInt(9999)}',
      name: rp['name'] ?? 'New Route Profile',
      description: rp['description'] ?? '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _delayVoid();
    _routeProfiles.add(r);
    return r;
  }

  @override
  Future<RouteProfile> updateRouteProfile(
      String id, Map<String, dynamic> rp) async {
    final idx = _routeProfiles.indexWhere((r) => r.id == id);
    await _delayVoid();
    if (idx >= 0) {
      _routeProfiles[idx] = RouteProfile(
        id: id,
        name: rp['name'] ?? _routeProfiles[idx].name,
        description: rp['description'] ?? _routeProfiles[idx].description,
        ruleIDs: (rp['rule_ids'] as List?)?.cast<String>() ??
            _routeProfiles[idx].ruleIDs,
        createdAt: _routeProfiles[idx].createdAt,
        updatedAt: DateTime.now(),
      );
      return _routeProfiles[idx];
    }
    throw Exception('Route profile not found');
  }

  @override
  Future<void> deleteRouteProfile(String id) async {
    await _delayVoid();
    _routeProfiles.removeWhere((r) => r.id == id);
  }

  // ─── Connections ──────────────────────────────────────────────────

  @override
  Future<List<Connection>> listConnections() =>
      _delay(<Connection>[..._connections]);

  @override
  Future<void> closeConnection(String id) async {
    await _delayVoid();
    _connections.removeWhere((c) => c.id == id);
  }

  @override
  Future<void> closeAllConnections() async {
    await _delayVoid();
    _connections.clear();
  }

  // ─── Stats ────────────────────────────────────────────────────────

  @override
  Future<TrafficStats> getStats() {
    // Simulate growing traffic
    _stats = TrafficStats(
      totalUpload: _stats.totalUpload + _rand.nextInt(50000),
      totalDownload: _stats.totalDownload + _rand.nextInt(500000),
      uploadSpeed: 100000 + _rand.nextInt(400000),
      downloadSpeed: 1000000 + _rand.nextInt(4000000),
      activeConnections: _connections.length,
      uptime: _stats.uptime,
      since: _stats.since,
    );
    return _delay(_stats);
  }

  @override
  Future<void> resetStats() async {
    await _delayVoid();
    _stats = TrafficStats(
      since: DateTime.now(),
    );
  }

  // ─── DNS ──────────────────────────────────────────────────────────

  @override
  Future<DNSConfig> getDNS() => _delay(_dns);

  @override
  Future<DNSConfig> setDNS(Map<String, dynamic> dns) async {
    _dns = DNSConfig(
      mode: dns['mode'] ?? _dns.mode,
      proxied: dns['proxied'] ?? _dns.proxied,
      direct: dns['direct'] ?? _dns.direct,
      fakeIPRange: dns['fake_ip_range'] ?? _dns.fakeIPRange,
    );
    await _delayVoid();
    return _dns;
  }

  // ─── Tests ────────────────────────────────────────────────────────

  @override
  Future<TestResult> testURL(String url, String serverID) async {
    await _delayVoid();
    return TestResult(
      serverID: serverID,
      serverName: '',
      latencyMS: 20 + _rand.nextInt(180),
    );
  }

  @override
  Future<TestResult> testIP(String serverID) async {
    await _delayVoid();
    return TestResult(
      serverID: serverID,
      serverName: '',
      latencyMS: 15 + _rand.nextInt(185),
    );
  }

  @override
  Future<SpeedTestResult> speedTest({String? serverID}) async {
    await _delayVoid();
    return SpeedTestResult(
      target: serverID ?? 'current',
      serverName: '',
      downloadBps: 5000000 + _rand.nextInt(45000000),
      uploadBps: 1000000 + _rand.nextInt(9000000),
      latencyMS: 20 + _rand.nextInt(80),
      jitterMS: _rand.nextInt(10),
      durationSeconds: 10.0,
    );
  }

  // ─── WARP ─────────────────────────────────────────────────────────

  @override
  Future<WARPConfig> getWARP() => _delay(_warp);

  @override
  Future<WARPConfig> setWARP(Map<String, dynamic> warp) async {
    _warp = WARPConfig(
      enabled: warp['enabled'] ?? _warp.enabled,
      mode: warp['mode'] ?? _warp.mode,
      licenseKey: warp['license_key'] ?? _warp.licenseKey,
      teamToken: warp['team_token'] ?? _warp.teamToken,
      bindAddr: warp['bind_addr'] ?? _warp.bindAddr,
    );
    await _delayVoid();
    return _warp;
  }

  // ─── Import ───────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> importClipboard(String raw) async {
    await _delayVoid();
    return {
      'imported': true,
      'raw': raw,
      'servers_found': 1 + _rand.nextInt(5)
    };
  }

  @override
  Future<Map<String, dynamic>> importLink(String link) async {
    await _delayVoid();
    return {
      'imported': true,
      'link': link,
      'servers_found': 1 + _rand.nextInt(5)
    };
  }

  // ─── Diag ─────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getDiag() async {
    await _delayVoid();
    return {
      'daemon_version': '0.1.0-mock',
      'flutter_platform': 'windows',
      'uptime_seconds': _stats.uptime.inSeconds,
      'status': _status.state,
      'server_count': _servers.length,
      'subscription_count': _subscriptions.length,
    };
  }

  // ─── Egresses ─────────────────────────────────────────────────────

  @override
  Future<List<Egress>> listEgresses() => _delay(<Egress>[..._egresses]);

  @override
  Future<Egress> addEgress(Map<String, dynamic> egress) async {
    final e = Egress(
      id: 'egr-${_egresses.length + 1}-${_rand.nextInt(9999)}',
      name: egress['name'] as String? ?? 'New Egress',
      type: egress['type'] as String? ?? 'mixed',
      listen: egress['listen'] as String? ?? '127.0.0.1',
      port: (egress['port'] as int?) ?? (2080 + _egresses.length),
      serverID: egress['server_id'] as String?,
      serverName: egress['server_name'] as String?,
      active: egress['active'] as bool? ?? false,
      connections: 0,
      upload: 0,
      download: 0,
      autoConnect: egress['auto_connect'] as bool? ?? false,
    );
    await _delayVoid();
    _egresses.add(e);
    return e;
  }

  @override
  Future<Egress> updateEgress(String id, Map<String, dynamic> egress) async {
    final idx = _egresses.indexWhere((e) => e.id == id);
    await _delayVoid();
    if (idx >= 0) {
      _egresses[idx] = _egresses[idx].copyWith(
        name: egress['name'] as String?,
        type: egress['type'] as String?,
        listen: egress['listen'] as String?,
        port: egress['port'] as int?,
        serverID: egress['server_id'] as String?,
        serverName: egress['server_name'] as String?,
        active: egress['active'] as bool?,
        autoConnect: egress['auto_connect'] as bool?,
      );
      return _egresses[idx];
    }
    throw Exception('Egress not found');
  }

  @override
  Future<void> deleteEgress(String id) async {
    await _delayVoid();
    _egresses.removeWhere((e) => e.id == id);
  }

  @override
  Future<void> toggleEgress(String id, bool active) async {
    final idx = _egresses.indexWhere((e) => e.id == id);
    await _delayVoid();
    if (idx >= 0) {
      _egresses[idx] = _egresses[idx].copyWith(active: active);
    }
  }

  // ─── Billing ───────────────────────────────────────────────────────

  @override
  Future<BillingProfile> getBillingProfile() => _delay(_billingProfile);

  @override
  Future<void> linkBillingAccount(int telegramId,
      {String? sessionToken}) async {
    await _delayVoid();
    _billingProfile = BillingProfile(
      linked: true,
      telegramId: telegramId,
      username: 'telegram_$telegramId',
      shortUuid: 'uuid_$telegramId',
      status: 'active',
      tag: 'default_squad',
      squadName: 'default_squad',
      email: 'user_$telegramId@example.com',
      trafficLimitBytes: 100 * 1024 * 1024 * 1024,
      usedTrafficBytes: 0,
      expireAt: DateTime.now().add(const Duration(days: 30)),
      daysLeft: 30,
      description: 'Linked Telegram account',
    );
  }

  @override
  Future<void> unlinkBillingAccount() async {
    await _delayVoid();
    _billingProfile = BillingProfile(linked: false);
  }

  @override
  Future<TopupResponse> createTopup({
    required double amount,
    int? days,
    String? description,
  }) async {
    await _delayVoid();
    final invoiceId = _nextInvoiceId++;
    final response = TopupResponse(
      invoiceId: invoiceId,
      payUrl: 'https://t.me/CryptoBot?start=IV$invoiceId',
      amount: amount.toStringAsFixed(2),
      asset: 'USDT',
    );
    _mockTopups[invoiceId] = TopupStatusResponse(
      invoiceId: invoiceId,
      status: 'paid',
    );
    return response;
  }

  @override
  Future<TopupStatusResponse> getTopupStatus(int invoiceId) async {
    await _delayVoid();
    return _mockTopups[invoiceId] ??
        TopupStatusResponse(
          invoiceId: invoiceId,
          status: 'active',
        );
  }

  // ─── Account cabinet (T-19) ────────────────────────────────────────

  /// Codes the mock accepts. Anything else is rejected like the daemon would,
  /// so the UI's error paths stay exercisable without a backend.
  static const mockValidLinkCode = 'MOCK2345';
  static const mockExpiredLinkCode = 'EXPIRED9';

  bool _mockLinked = false;
  UnifiedAccount? _unifiedAccount;

  UnifiedAccount _demoAccount({String status = 'active'}) => UnifiedAccount(
        accountId: 'mock-account',
        status: status,
        tier: 'standard',
        balanceKopecks: 3200,
        currency: 'RUB',
        trialEndsAt: DateTime.now().add(const Duration(days: 2)),
        shortUuid: 'mock-subscription',
        subscriptionUrl: 'https://sub.zxc1x1.ru/mock-subscription',
        pricePerDayKopecks: 100,
        timezone: 'Europe/Moscow',
        checkoutDiscountPercent: 0,
      );

  @override
  Future<LinkResult> redeemLinkCode(String code) async {
    await _delayVoid();
    final normalized =
        code.toUpperCase().replaceAll('-', '').replaceAll(' ', '');
    if (normalized == mockExpiredLinkCode) {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/account/link'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/account/link'),
          statusCode: 410,
        ),
      );
    }
    if (normalized != mockValidLinkCode) {
      throw DioException(
        requestOptions: RequestOptions(path: '/v1/account/link'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/account/link'),
          statusCode: 404,
        ),
      );
    }
    _mockLinked = true;
    _unifiedAccount = _demoAccount();
    return const LinkResult(
        ok: true, telegramId: 424242, username: 'mock_user');
  }

  @override
  Future<void> loginWithEmail(String email, String password) async {
    await _delayVoid();
    if (!email.contains('@') || password.length < 8) {
      throw DioException(
          requestOptions: RequestOptions(path: '/v1/account/email-login'));
    }
    _mockLinked = true;
    _unifiedAccount = _demoAccount();
  }

  @override
  Future<List<PaymentEntry>> getPaymentHistory() async {
    await _delayVoid();
    if (!_mockLinked) return const [];
    final now = DateTime.now();
    return [
      PaymentEntry(
        id: 'mock-3',
        provider: 'lava',
        amount: 199,
        currency: 'RUB',
        status: 'pending',
        days: 30,
        createdAt: now.subtract(const Duration(minutes: 4)),
      ),
      PaymentEntry(
        id: 'mock-2',
        provider: 'yookassa',
        amount: 349,
        currency: 'RUB',
        status: 'paid',
        days: 30,
        createdAt: now.subtract(const Duration(days: 31)),
        paidAt: now.subtract(const Duration(days: 31)),
      ),
      PaymentEntry(
        id: 'mock-1',
        provider: 'cryptobot',
        amount: 4.2,
        currency: 'USDT',
        status: 'failed',
        createdAt: now.subtract(const Duration(days: 60)),
      ),
    ];
  }

  // ─── Unified account ───────────────────────────────────────────────

  @override
  Future<UnifiedAccount?> getUnifiedAccount() async {
    await _delayVoid();
    return _mockLinked ? (_unifiedAccount ??= _demoAccount()) : null;
  }

  @override
  Future<UnifiedAccount> freezeAccount() async {
    await _delayVoid();
    final current = _unifiedAccount;
    if (!_mockLinked || current == null) {
      throw DioException(
          requestOptions: RequestOptions(path: '/v1/account/freeze'));
    }
    return _unifiedAccount = UnifiedAccount(
      accountId: current.accountId,
      status: 'frozen',
      tier: current.tier,
      balanceKopecks: current.balanceKopecks,
      currency: current.currency,
      trialEndsAt: current.trialEndsAt,
      shortUuid: current.shortUuid,
      subscriptionUrl: current.subscriptionUrl,
      pricePerDayKopecks: current.pricePerDayKopecks,
      timezone: current.timezone,
      checkoutDiscountPercent: current.checkoutDiscountPercent,
    );
  }

  @override
  Future<UnifiedAccount> unfreezeAccount() async {
    await _delayVoid();
    final current = _unifiedAccount;
    if (!_mockLinked || current == null) {
      throw DioException(
          requestOptions: RequestOptions(path: '/v1/account/unfreeze'));
    }
    return _unifiedAccount = UnifiedAccount(
      accountId: current.accountId,
      status: 'active',
      tier: current.tier,
      balanceKopecks: current.balanceKopecks,
      currency: current.currency,
      trialEndsAt: current.trialEndsAt,
      shortUuid: current.shortUuid,
      subscriptionUrl: current.subscriptionUrl,
      pricePerDayKopecks: current.pricePerDayKopecks,
      timezone: current.timezone,
      checkoutDiscountPercent: current.checkoutDiscountPercent,
    );
  }

  @override
  Future<List<CheckoutProviderOption>> getCheckoutOptions() async {
    await _delayVoid();
    return const [
      CheckoutProviderOption(
          id: 'cryptopay',
          title: 'Crypto Pay',
          currency: 'USDT',
          available: true,
          minAmountRub: 10,
          maxAmountRub: 365)
    ];
  }

  @override
  Future<CheckoutSession> createCheckout(
      {required int amountRub, required String provider}) async {
    await _delayVoid();
    if (amountRub < 10 || amountRub > 365) {
      throw DioException(
          requestOptions: RequestOptions(path: '/v1/billing/checkout'));
    }
    return CheckoutSession(
        provider: provider,
        checkoutUrl: Uri.parse('https://pay.crypt.bot/mock-mosaic-invoice'),
        amountRub: amountRub,
        message: 'Оплата будет зачислена автоматически.');
  }

  @override
  Future<RotatedSubscriptionLink> rotateSubscriptionLink() async {
    await _delayVoid();
    if (!_mockLinked) {
      throw DioException(
          requestOptions:
              RequestOptions(path: '/v1/account/subscription-link/rotate'));
    }
    return RotatedSubscriptionLink(
        subscriptionUrl:
            Uri.parse('https://sub.zxc1x1.ru/mock-rotated-subscription'),
        shortUuid: 'mock-rotated-subscription');
  }

  // ─── Provider Manifest ─────────────────────────────────────────────

  @override
  Future<ProviderManifest> getProviderManifest() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return ProviderManifest.fromJson({
      'provider_name': 'MosaicVPN',
      'user_tier': 'free',
      'groups': [
        {
          'id': 'rg-all',
          'title': 'Минимальный пинг',
          'type': 'urltest',
          'user_tier': 'free',
          'badge': 'Оптимально',
          'category': 'smart',
          'icon': 'lightning',
          'description': 'Лучший свежепроверенный узел',
          'ping_interval': 15,
          'max_retries': 3,
          'failover_delay': 2,
        },
        {
          'id': 'auto-stable',
          'title': 'Стабильное соединение',
          'type': 'fallback',
          'user_tier': 'free',
          'badge': 'Надёжно',
          'category': 'smart',
          'icon': 'shield',
          'description': 'Переход на резервный здоровый узел',
          'ping_interval': 15,
          'max_retries': 3,
          'failover_delay': 2,
        },
        {
          'id': 'auto-speed',
          'title': 'Максимальная скорость',
          'type': 'weighted_round_robin',
          'user_tier': 'free',
          'badge': 'Speed',
          'category': 'smart',
          'icon': 'speed',
          'description': 'Приоритет свежего замера скорости',
          'ping_interval': 15,
          'max_retries': 3,
          'failover_delay': 2,
        },
        {
          'id': 'auto-allowlist',
          'title': 'Доступ через allowlist',
          'type': 'fallback',
          'user_tier': 'free',
          'badge': 'Reality',
          'category': 'whitelist',
          'icon': 'shield',
          'description': 'Проверенные Reality-кандидаты',
          'ping_interval': 15,
          'max_retries': 3,
          'failover_delay': 2,
        },
        {
          'id': 'auto-de',
          'title': 'Германия',
          'type': 'urltest',
          'user_tier': 'free',
          'badge': 'EU Fast',
          'category': 'smart',
          'icon': 'flag_de',
          'description': 'Свежепроверенные узлы Германии',
          'ping_interval': 15,
          'max_retries': 3,
          'failover_delay': 2,
        },
        {
          'id': 'auto-ca',
          'title': 'Канада',
          'type': 'urltest',
          'user_tier': 'free',
          'badge': 'NA Fast',
          'category': 'smart',
          'icon': 'flag_ca',
          'description': 'Свежепроверенные узлы Канады',
          'ping_interval': 15,
          'max_retries': 3,
          'failover_delay': 2,
        },
      ],
      'profile': {
        'branding': {
          'logo_url': '',
          'accent_color': '#E6C475',
          'support_url': 'https://t.me/mosaicvpn_support',
          'provider_description': 'MosaicVPN — fast, private, zero-logs VPN.',
        },
        'billing': {
          'type': 'telegram_bot',
          'bot_username': 'mosaicvpn_bot',
          'pricing_model': 'daily',
          'price_per_day': {'1': 49.0, '7': 199.0, '30': 599.0},
          'trial_days': 1,
          'payment_methods': ['SBP'],
        },
        'services': [
          {
            'id': 'support',
            'type': 'link',
            'title': 'Support',
            'icon': 'support_agent',
            'config': {'url': 'https://t.me/mosaicvpn_support'}
          },
        ],
        'widgets': [],
      },
    });
  }

  @override
  Future<Map<String, NodeHealth>> getGroupHealth(String groupId) async {
    await Future.delayed(const Duration(milliseconds: 150));
    return {
      'node-1': const NodeHealth(nodeId: 'node-1', alive: true, latencyMs: 42),
      'node-2': const NodeHealth(nodeId: 'node-2', alive: true, latencyMs: 87),
      'node-3':
          const NodeHealth(nodeId: 'node-3', alive: false, error: 'timeout'),
    };
  }

  @override
  Future<Server> selectNodeFromGroup(String groupId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return Server(
      id: 'node-1',
      name: 'Auto-selected from $groupId',
      address: '5.175.188.152',
      port: 4443,
    );
  }

  // ─── Events (SSE) ─────────────────────────────────────────────────

  int _eventCounter = 0;

  @override
  Stream<(String, Map<String, dynamic>)> events() async* {
    // Initial boot sequence
    yield (
      'log',
      {'level': 'INFO', 'msg': 'daemon: starting mosaic daemon v0.4.2'}
    );
    await Future.delayed(const Duration(milliseconds: 300));
    yield ('log', {'level': 'INFO', 'msg': 'core: sing-box 1.11.3 loaded'});
    await Future.delayed(const Duration(milliseconds: 200));
    yield (
      'log',
      {'level': 'INFO', 'msg': 'core: clash-api listening on 127.0.0.1:9090'}
    );
    await Future.delayed(const Duration(milliseconds: 200));
    yield (
      'log',
      {'level': 'INFO', 'msg': 'config: parsed 3 subscriptions, 15 servers'}
    );
    await Future.delayed(const Duration(milliseconds: 200));
    yield (
      'log',
      {'level': 'INFO', 'msg': 'tun: interface tun0 created, MTU 1420'}
    );
    await Future.delayed(const Duration(milliseconds: 200));
    yield (
      'log',
      {
        'level': 'INFO',
        'msg': 'dns: upstream 1.1.1.1 (proxied), 8.8.8.8 (direct)'
      }
    );
    await Future.delayed(const Duration(milliseconds: 200));
    yield ('log', {'level': 'INFO', 'msg': 'routing: 3 rules loaded'});
    await Future.delayed(const Duration(milliseconds: 200));
    yield ('log', {'level': 'INFO', 'msg': 'daemon: ready, awaiting commands'});
    await Future.delayed(const Duration(milliseconds: 500));

    final logMessages = <(String, String)>[
      ('INFO', 'tun: keepalive ping 1420 bytes → 10.0.0.1'),
      ('DEBUG', 'dns: query youtube.com → 142.250.0.1 (proxied)'),
      ('DEBUG', 'dns: query example.ru → 93.184.0.1 (direct, geosite:ru)'),
      ('INFO', 'connection: tcp 142.250.0.1:443 → de-fra-01 (vless-tls)'),
      ('DEBUG', 'mux: stream 7 opened for youtube.com'),
      ('DEBUG', 'mux: stream 7 closed, 2.4MB downstream'),
      ('WARN', 'latency: us-nyc-02 350ms — above threshold 200ms'),
      ('INFO', 'sub: refreshing Premium VPN (sub-1)'),
      ('INFO', 'sub: Premium VPN refreshed, 7 servers updated'),
      ('DEBUG', 'routing: matched rule "Proxy RU Sites" for vk.com'),
      ('DEBUG', 'routing: matched rule "Direct Local" for 192.168.1.5'),
      ('DEBUG', 'routing: matched rule "Block Ads" for doubleclick.net'),
      ('ERROR', 'connection: tcp timeout to jp-tyo-01, retrying via sg-01'),
      ('INFO', 'reconnect: established new path → sg-01 (trojan-tls)'),
      ('DEBUG', 'stats: ↑247KB/s ↓3.1MB/s active=3'),
      ('INFO', 'egress: listener 0.0.0.0:2080 → de-fra-01 (mixed)'),
      ('DEBUG', 'egress: listener 0.0.0.0:10808 → us-nyc-01 (socks)'),
      (
        'WARN',
        'dns: proxied lookup timeout for graph.facebook.com, fallback to direct'
      ),
      ('INFO', 'health: all 3 subscriptions healthy'),
      ('DEBUG', 'keepalive: tun0 heartbeat OK'),
      ('INFO', 'connection: udp 8.8.8.8:53 → direct (dns)'),
      ('DEBUG', 'mux: stream 12 backlog 3, cycling'),
      ('WARN', 'latency: br-sao-01 420ms — node overloaded'),
      ('INFO', 'sub: refreshing Free Servers (sub-2)'),
      ('INFO', 'sub: Free Servers refreshed, 4 servers updated'),
      ('DEBUG', 'routing: cache miss for instagram.com, evaluating rules'),
      ('ERROR', 'connection: handshake failed to se-sto-01: TLS cert expired'),
      ('WARN', 'health: sub-3 Private Relay — no fresh servers in 24h'),
      ('INFO', 'kernel: net.ipv4.tcp_congestion_control = bbr'),
      ('DEBUG', 'stats: ↑12KB/s ↓45KB/s active=1'),
      ('INFO', 'tun: rekey completed, session rotation'),
      ('DEBUG', 'dns: cache stats — 847 hits, 12 misses (98.6%)'),
      ('INFO', 'egress: listener 0.0.0.0:2081 → uk-lon-01 (http)'),
      ('WARN', 'latency: in-mum-01 310ms — above threshold 200ms'),
      ('DEBUG', 'mux: idle stream 15 recycled'),
      ('INFO', 'health: ping check complete — 13/15 nodes reachable'),
      ('ERROR', 'connection: ECONNRESET from au-syd-01, backing off 30s'),
      ('DEBUG', 'routing: matched rule "Block Ads" for googlesyndication.com'),
      ('INFO', 'sub: auto-refresh scheduled in 47m for sub-1'),
    ];

    while (true) {
      await Future.delayed(const Duration(seconds: 1));
      yield (
        'status',
        {
          'state': _status.state,
          'agent_connected': _status.agentConnected,
          'latency_ms': _status.latencyMS,
          'server_id': _status.server?.id,
        }
      );

      // Emit a log event every other tick
      if (_eventCounter % 2 == 0) {
        final (level, msg) =
            logMessages[_eventCounter ~/ 2 % logMessages.length];
        yield ('log', {'level': level, 'msg': msg});
      }
      _eventCounter++;
    }
  }
}

class _DetectedLoc {
  final String country;
  final String city;
  final double lat;
  final double lon;
  _DetectedLoc(this.country, this.city, this.lat, this.lon);
}
