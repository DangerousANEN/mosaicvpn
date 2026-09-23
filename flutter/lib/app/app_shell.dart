import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/atlas_theme.dart';
import '../core/platform/app_platform.dart';
import '../core/api/daemon_api_base.dart';
import '../core/api/android_hosted_daemon_api.dart';
import '../core/models/subscription.dart';
import '../core/providers/vpn_providers.dart';
import '../core/i18n/app_strings.dart';
import '../core/services/android_mosaic_account_service.dart';
import '../core/services/android_vpn_service.dart';
import '../core/services/desktop_instance_lock.dart';
import '../core/services/elevation_service.dart';
import '../core/services/mosaic_enrollment_exchange.dart';
import '../core/services/tray_service.dart';
import '../core/services/smart_group_selector.dart';
import '../core/services/smart_group_runtime_controller.dart';
import '../core/services/local_rest_api.dart';
import '../core/services/ui_preferences_service.dart';
import '../shared/widgets/mosaic_tray_quick_panel.dart';
import '../features/dashboard/connection_dashboard.dart';
import '../features/connections/connections_screen.dart';
import '../features/routing/routing_screen.dart';
import '../features/egresses/egresses_screen.dart';
import '../features/stats/stats_screen.dart';
import '../features/speedtest/speedtest_screen.dart';
import '../features/cores/cores_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/logs/logs_screen.dart';
import '../features/account/accounts_screen.dart';
import '../features/account/unified_account_panel.dart'
    show unifiedAccountProvider;
import '../features/groups/groups_screen.dart';
import '../features/more/more_screen.dart';
import '../core/services/app_update_service.dart';

/// Root shell with bottom navigation (and sidebar on desktop/wide screens) and tab caching via IndexedStack.
///
/// IndexedStack keeps alive all tab pages so switching is instant.
/// Each page also uses AutomaticKeepAliveClientMixin for state preservation.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver, WindowListener {
  int _currentIndex = 0;
  bool _autoConnectTriggered = false;
  bool _quitting = false;
  bool _trayQuickPanelVisible = false;
  final Set<String> _completedEnrollmentCallbacks = <String>{};
  final List<Uri> _enrollmentQueue = <Uri>[];
  bool _isProcessingEnrollmentQueue = false;
  StreamSubscription<Uri>? _enrollmentCallbackSubscription;
  StreamSubscription<Uri>? _desktopEnrollmentCallbackSubscription;
  final SmartGroupSelector _smartGroupSelector = SmartGroupSelector();

  // Only build a tab after the user opens it. This prevents hidden technical
  // screens from starting network polls or timers on first launch, while the
  // visited tabs remain alive for instant back-and-forth navigation.
  final Set<int> _visitedMobileTabs = {0};
  final Set<int> _visitedWideTabs = {0};

  /// Primary navigation labels are resolved from the active locale at build time.
  List<_NavDestination> _mainDestinations(BuildContext context) {
    final s = AppStrings.of(context);
    return [
      _NavDestination(
          icon: Icons.shield_outlined,
          activeIcon: Icons.shield,
          label: s.t('connection')),
      _NavDestination(
          icon: Icons.public_outlined,
          activeIcon: Icons.public,
          label: s.t('routes')),
      _NavDestination(
          icon: Icons.people_outline,
          activeIcon: Icons.people,
          label: s.t('accounts')),
      _NavDestination(
          icon: Icons.more_horiz_outlined,
          activeIcon: Icons.more_horiz,
          label: s.t('more')),
    ];
  }

  static double _computeOptimalNavFontSize({
    required List<String> labels,
    required double slotWidth,
    required TextScaler textScaler,
    double maxFontSize = 11.0,
    double minFontSize = 7.5,
  }) {
    for (double fs = maxFontSize; fs >= minFontSize; fs -= 0.5) {
      bool allFit = true;
      for (final label in labels) {
        final scaledFs = textScaler.scale(fs);
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              fontSize: scaledFs,
              letterSpacing: fs <= 8.5 ? -0.3 : (fs <= 9.5 ? -0.2 : 0.0),
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        if (tp.width > slotWidth) {
          allFit = false;
          break;
        }
      }
      if (allFit) return fs;
    }
    return minFontSize;
  }

  /// Full list of desktop/sidebar destinations resolved from the active locale.
  List<_NavDestination> _destinations(BuildContext context) {
    final s = AppStrings.of(context);
    return [
      _NavDestination(
          icon: Icons.dashboard_outlined,
          activeIcon: Icons.dashboard,
          label: s.t('connection')),
      _NavDestination(
          icon: Icons.public_outlined,
          activeIcon: Icons.public,
          label: s.t('routes')),
      _NavDestination(
          icon: Icons.people_outline,
          activeIcon: Icons.people,
          label: s.t('accounts')),
      _NavDestination(
          icon: Icons.hub_outlined,
          activeIcon: Icons.hub,
          label: s.t('routing')),
      _NavDestination(
          icon: Icons.account_tree_outlined,
          activeIcon: Icons.account_tree,
          label: s.t('egresses')),
      _NavDestination(
          icon: Icons.visibility_outlined,
          activeIcon: Icons.visibility,
          label: s.t('activity')),
      _NavDestination(
          icon: Icons.bar_chart_outlined,
          activeIcon: Icons.bar_chart,
          label: s.t('stats')),
      _NavDestination(
          icon: Icons.speed_outlined,
          activeIcon: Icons.speed,
          label: s.t('speed')),
      _NavDestination(
          icon: Icons.memory_outlined,
          activeIcon: Icons.memory,
          label: s.t('cores')),
      _NavDestination(
          icon: Icons.receipt_long_outlined,
          activeIcon: Icons.receipt_long,
          label: s.t('logs')),
      _NavDestination(
          icon: Icons.settings_outlined,
          activeIcon: Icons.settings,
          label: s.t('settings')),
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AppPlatform.isDesktop) {
      windowManager.addListener(this);
      TrayService.instance.configure(
        minimizeToTray: true,
        onConnect: _connectFromTray,
        onDisconnect: _disconnectFromTray,
        onOpenRoutes: _openRoutesFromTray,
        onQuickPanel: _showTrayQuickPanel,
        onQuit: _quitApplication,
      );
      // app_links delivers both the startup URI and later Windows/Linux
      // protocol launches.
    }
    _desktopEnrollmentCallbackSubscription =
        AppLinks().uriLinkStream.listen(_enqueueEnrollment);
    AppLinks().getInitialLink().then((uri) {
      if (uri != null) _enqueueEnrollment(uri);
    });
    if (AppPlatform.isAndroid) {
      _enrollmentCallbackSubscription =
          AndroidVpnService.instance.enrollmentCallbacks.listen(_enqueueEnrollment);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pollAndroidEnrollmentCallbacks();
      if (mounted) {
        AppUpdateService.instance.checkAndShowPrompt(context);
      }
      // Start the local REST API for scripted VPN control (desktop only).
      // On Android the VPN service runs in a separate process, so the REST
      // API would not reach the daemon; scripts use adb or intents instead.
      if (AppPlatform.isDesktop) {
        final api = ref.read(daemonApiProvider);
        LocalRestApi.instance.start(api: api);
      }
    });
  }

  @override
  void dispose() {
    SmartGroupRuntimeController.instance.stop();
    unawaited(LocalRestApi.instance.stop());
    _enrollmentCallbackSubscription?.cancel();
    _desktopEnrollmentCallbackSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (AppPlatform.isDesktop) {
      windowManager.removeListener(this);
      unawaited(TrayService.instance.dispose());
    }
    super.dispose();
  }

  /// Intercept window close — hide to tray instead of quitting
  /// when minimizeToTray is enabled.
  @override
  void onWindowClose() async {
    if (TrayService.instance.shouldInterceptClose) {
      await TrayService.instance.hideToTray();
    } else {
      await _quitApplication();
    }
  }

  /// Enqueues a deep link enrollment URI, ignoring duplicates to prevent
  /// burning one-time exchange codes on repeated cold/warm deliveries.
  void _enqueueEnrollment(Uri callback) {
    if (!MosaicEnrollmentExchange.isSupportedCallback(callback)) return;
    final callbackKey = MosaicEnrollmentExchange.callbackDeliveryKey(callback);
    if (callbackKey != null &&
        _completedEnrollmentCallbacks.contains(callbackKey)) {
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      if (mounted) setState(() => _currentIndex = 1);
      return;
    }
    // Prevent duplicate entries in the pending queue
    final isAlreadyQueued = _enrollmentQueue.any((pending) {
      final key = MosaicEnrollmentExchange.callbackDeliveryKey(pending);
      return (key != null && key == callbackKey) || pending == callback;
    });
    if (!isAlreadyQueued) {
      _enrollmentQueue.add(callback);
    }
    _drainEnrollmentQueue();
  }

  Future<void> _pollAndroidEnrollmentCallbacks() async {
    if (!AppPlatform.isAndroid) return;
    try {
      while (true) {
        final callback =
            await AndroidVpnService.instance.consumeEnrollmentCallback();
        if (callback == null) break;
        _enqueueEnrollment(callback);
      }
    } catch (_) {}
  }

  /// Warms Smart Group probe caches for all groups of the active Mosaic
  /// subscription (throttled inside prewarmGroups). Called on app resume so
  /// a connect right after opening the app is served from fresh probes.
  Future<void> _prewarmFromShell() async {
    try {
      final api = ref.read(daemonApiProvider);
      final subs =
          await ref.read(subscriptionsProvider.future).catchError((_) => <Subscription>[]);
      Subscription? mosaicSub;
      for (final sub in subs) {
        final uri = Uri.tryParse(sub.url);
        if (uri != null && uri.host.toLowerCase() == 'sub.zxc1x1.ru') {
          mosaicSub = sub;
          break;
        }
      }
      final manifest = await api.getProviderManifest(
        subscriptionId: mosaicSub?.id,
      );
      if (!mounted) return;
      unawaited(
        SmartGroupRuntimeController.instance.prewarmGroups(
          api: api,
          selector: _smartGroupSelector,
          groups: manifest.groups,
        ),
      );
    } catch (_) {
      // No manifest / daemon unreachable: prewarm is a pure optimization.
    }
  }

  Future<void> _drainEnrollmentQueue() async {
    if (_isProcessingEnrollmentQueue) return;
    _isProcessingEnrollmentQueue = true;
    try {
      while (_enrollmentQueue.isNotEmpty) {
        final callback = _enrollmentQueue.removeAt(0);
        await _processSingleEnrollment(callback);
      }
    } finally {
      _isProcessingEnrollmentQueue = false;
    }
  }

  Future<void> _processSingleEnrollment(Uri callback) async {
    final callbackKey = MosaicEnrollmentExchange.callbackDeliveryKey(callback);
    if (callbackKey != null &&
        _completedEnrollmentCallbacks.contains(callbackKey)) {
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      if (mounted) setState(() => _currentIndex = 1);
      return;
    }

    try {
      // 1. Redeem one-time code and persist account credentials
      final enrollment = await AndroidMosaicAccountService.instance
          .completeEnrollmentCallback(callback);

      final providerId = enrollment.providerId?.trim().isNotEmpty == true
          ? enrollment.providerId!.trim()
          : 'mosaicvpn';
      final providerAccountId =
          enrollment.providerAccountId?.trim().isNotEmpty == true
              ? enrollment.providerAccountId!.trim()
              : 'mosaicvpn-default';
      final subscriptionUrl = enrollment.subscriptionUrl?.trim().isNotEmpty ==
              true
          ? enrollment.subscriptionUrl!.trim()
          : 'https://sub.zxc1x1.ru/${Uri.encodeComponent(enrollment.directToken)}';

      // 2. Durable save: persist subscription into the active daemon / local store
      final api = AppPlatform.isAndroid
          ? AndroidHostedDaemonApi.instance
          : ref.read(daemonApiProvider);
      final subscription = await api.enrollProviderSubscription(
        providerId: providerId,
        providerAccountId: providerAccountId,
        subscriptionName: enrollment.subscriptionName?.trim().isNotEmpty == true
            ? enrollment.subscriptionName!.trim()
            : 'MosaicVPN',
        subscriptionUrl: subscriptionUrl,
        sessionToken: enrollment.sessionToken,
        directToken: enrollment.directToken,
        username: enrollment.username,
      );

      // 3. Mark callback delivery completed to protect against burn-before-durable-save
      if (callbackKey != null) {
        _completedEnrollmentCallbacks.add(callbackKey);
      }

      if (!mounted) return;
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      setState(() => _currentIndex = 1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppPlatform.isDesktop
                ? 'MosaicVPN добавлен: ${subscription.serverCount} маршрутов и кабинет подключены.'
                : 'Подписка «${subscription.name}» добавлена в приложение.',
          ),
        ),
      );
    } catch (error) {
      if (callbackKey != null) {
        _completedEnrollmentCallbacks.add(callbackKey);
      }
      if (!mounted) return;
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      final errStr = error.toString();
      // If code was already redeemed on server, gracefully navigate instead of crashing
      if (errStr.contains('409') || errStr.contains('used')) {
        setState(() => _currentIndex = 1);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errStr.replaceFirst('Bad state: ', '')),
        ),
      );
    }
  }

  /// Called when the app returns from a browser deep link.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pollAndroidEnrollmentCallbacks();
      // Resume quality monitoring probes when the app comes to the foreground.
      SmartGroupRuntimeController.instance.resume();
      // Re-warm probe caches after returning to the app (throttled to
      // one pass per 15 min inside prewarmGroups): the user is about to
      // interact, and caches older than the TTL would mean a cold connect.
      _prewarmFromShell();
    } else if (state == AppLifecycleState.paused ||
               state == AppLifecycleState.inactive) {
      // Pause quality monitoring probes to save battery when the app leaves.
      SmartGroupRuntimeController.instance.pause();
    }
  }

  /// Primary pages are deliberately limited to the common everyday tasks.
  List<Widget> get _mainPages => [
        const _KeepAlive(child: ConnectionDashboard()),
        const _KeepAlive(child: GroupsScreen()),
        const _KeepAlive(child: AccountsScreen()),
        const _KeepAlive(child: MoreScreen()),
      ];

  /// Full pages list for wide screen sidebar navigation (>900px)
  List<Widget> get _allPages => [
        const _KeepAlive(child: ConnectionDashboard()),
        const _KeepAlive(child: GroupsScreen()),
        const _KeepAlive(child: AccountsScreen()),
        const _KeepAlive(child: RoutingScreen()),
        const _KeepAlive(child: EgressesScreen()),
        const _KeepAlive(child: ConnectionsScreen()),
        const _KeepAlive(child: StatsScreen()),
        const _KeepAlive(child: SpeedTestScreen()),
        const _KeepAlive(child: CoresScreen()),
        const _KeepAlive(child: LogsScreen()),
        const _KeepAlive(child: SettingsScreen()),
      ];

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    final trayStatus = ref.watch(vpnStatusProvider).valueOrNull;
    final closeToTray =
        ref.watch(prefsProvider).valueOrNull?.minimizeToTray ?? true;
    if (AppPlatform.isDesktop) {
      TrayService.instance.configure(
        minimizeToTray: closeToTray,
        labels: TrayLabels(
          localeCode: Localizations.localeOf(context).languageCode,
          connected: s.t('tray_connected'),
          disconnected: s.t('tray_disconnected'),
          openApp: s.t('tray_open_app'),
          connect: s.t('connect_action'),
          disconnect: s.t('disconnect_action'),
          chooseRoute: s.t('tray_choose_route'),
          minimize: s.t('tray_minimize'),
          quit: s.t('tray_quit'),
        ),
      );
      TrayService.instance.setConnectionState(
        trayStatus?.state == 'connected',
        connecting: trayStatus?.state == 'connecting',
        routeLabel: trayStatus?.server?.name ?? '',
      );
    }
    final mq = MediaQuery.of(context);
    // Use the shortest side so a phone in landscape (wide but short)
    // still gets the mobile layout.  A typical 6" phone in landscape
    // is ~360dp tall — well below 600.  Tablets start around 800dp
    // on the shortest side and deserve the desktop layout.
    final shortest = mq.size.shortestSide;
    final isWide = shortest > 600;

    // Auto-connect on first frame (q3)
    if (!_autoConnectTriggered) {
      _autoConnectTriggered = true;
      _tryAutoConnect(showLegacySetupPrompt: false);
    }

    // Clamp active index for the current layout mode
    final activeIndex = isWide
        ? _currentIndex.clamp(0, _allPages.length - 1)
        : _currentIndex.clamp(0, _mainPages.length - 1);

    final pages = isWide ? _allPages : _mainPages;
    final destinations = _destinations(context);
    final visitedTabs = isWide ? _visitedWideTabs : _visitedMobileTabs;
    visitedTabs.add(activeIndex);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            setState(() => _currentIndex = 0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            setState(() => _currentIndex = 1),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
            setState(() => _currentIndex = 2),
        const SingleActivator(LogicalKeyboardKey.digit4, control: true): () =>
            setState(() => _currentIndex = 3),
        const SingleActivator(LogicalKeyboardKey.digit5, control: true): () =>
            setState(() => _currentIndex = 4),
        if (isWide) ...{
          const SingleActivator(LogicalKeyboardKey.digit6, control: true): () =>
              setState(() => _currentIndex = 5),
          const SingleActivator(LogicalKeyboardKey.digit7, control: true): () =>
              setState(() => _currentIndex = 6),
          const SingleActivator(LogicalKeyboardKey.digit8, control: true): () =>
              setState(() => _currentIndex = 7),
          const SingleActivator(LogicalKeyboardKey.digit9, control: true): () =>
              setState(() => _currentIndex = 8),
        },
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Scaffold(
              body: isWide
                  ? Row(
                      children: [
                        // ── Sidebar on wide screens (>900px) ──
                        Container(
                          width: 72,
                          decoration: BoxDecoration(
                            color: c.bgInk,
                            border: Border(
                              right: BorderSide(color: c.borderInk, width: 1),
                            ),
                          ),
                          child: SafeArea(
                            child: Column(
                              children: [
                                const SizedBox(height: 12),
                                // Logo / app icon
                                Tooltip(
                                  message: 'MosaicVPN',
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: c.isDark
                                          ? AtlasTheme.darkBgElevated
                                          : AtlasTheme.bgCard,
                                      borderRadius: BorderRadius.circular(
                                          AtlasTheme.radiusSm),
                                      border: Border.all(
                                        color: c.isDark
                                            ? AtlasTheme.accent
                                                .withValues(alpha: .48)
                                            : c.border,
                                      ),
                                      boxShadow: c.isDark
                                          ? [
                                              BoxShadow(
                                                color: Colors.black
                                                    .withValues(alpha: .28),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Image.asset(
                                      'assets/icon_adaptive.png',
                                      width: 30,
                                      height: 30,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                // Full Sidebar Navigation icons
                                Expanded(
                                  child: () {
                                    final prefs =
                                        ref.watch(prefsProvider).valueOrNull;
                                    final isAdvanced =
                                        prefs?.advancedMode ?? false;
                                    final visibleIndices = isAdvanced
                                        ? List.generate(
                                            destinations.length, (i) => i)
                                        : const [0, 1, 2, 5, 6, 10];

                                    return ListView.builder(
                                      itemCount: visibleIndices.length,
                                      itemBuilder: (context, idx) {
                                        final i = visibleIndices[idx];
                                        final dest = destinations[i];
                                        final isSelected = i == activeIndex;
                                        return _SideIcon(
                                          icon: isSelected
                                              ? dest.activeIcon
                                              : dest.icon,
                                          label: dest.label,
                                          isSelected: isSelected,
                                          onTap: () =>
                                              setState(() => _currentIndex = i),
                                        );
                                      },
                                    );
                                  }(),
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        ),
                        // ── Main content area ──
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(
                                child: _LazyTabStack(
                                  pages: pages,
                                  currentIndex: activeIndex,
                                  visitedTabs: visitedTabs,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : SafeArea(
                      top: true,
                      bottom: false,
                      child: Column(
                        children: [
                          Expanded(
                            child: _LazyTabStack(
                              pages: pages,
                              currentIndex: activeIndex,
                              visitedTabs: visitedTabs,
                            ),
                          ),
                        ],
                      ),
                    ),
              bottomNavigationBar: isWide
                  ? null
                  : Builder(
                      builder: (context) {
                        final destinations = _mainDestinations(context);
                        final screenWidth = MediaQuery.sizeOf(context).width;
                        final slotWidth = screenWidth / destinations.length;
                        final incomingScaler = MediaQuery.textScalerOf(context);
                        final clampedScaler =
                            incomingScaler.clamp(maxScaleFactor: 1.15);
                        final optimalFontSize = _computeOptimalNavFontSize(
                          labels: destinations.map((d) => d.label).toList(),
                          slotWidth: slotWidth - 2.0,
                          textScaler: clampedScaler,
                        );
                        final letterSpacing = optimalFontSize <= 8.5
                            ? -0.3
                            : (optimalFontSize <= 9.5 ? -0.2 : 0.0);
                        final labelStyle = TextStyle(
                          fontSize: optimalFontSize,
                          letterSpacing: letterSpacing,
                          fontWeight: FontWeight.w500,
                        );

                        return Container(
                          decoration: BoxDecoration(
                            color: c.bgInk,
                            border: Border(
                              top: BorderSide(color: c.borderInk, width: 1),
                            ),
                          ),
                          child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              textScaler: clampedScaler,
                            ),
                            child: BottomNavigationBar(
                              currentIndex: activeIndex,
                              onTap: (index) =>
                                  setState(() => _currentIndex = index),
                              type: BottomNavigationBarType.fixed,
                              backgroundColor: Colors.transparent,
                              elevation: 0,
                              selectedItemColor: AtlasTheme.accent,
                              unselectedItemColor: c.textMuted,
                              selectedFontSize: optimalFontSize,
                              unselectedFontSize: optimalFontSize,
                              selectedLabelStyle: labelStyle.copyWith(
                                  fontWeight: FontWeight.w600),
                              unselectedLabelStyle: labelStyle,
                              items: destinations
                                  .map(
                                    (dest) => BottomNavigationBarItem(
                                      icon: Icon(dest.icon),
                                      activeIcon: Icon(dest.activeIcon),
                                      label: dest.label,
                                      tooltip: dest.label,
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (AppPlatform.isDesktop && _trayQuickPanelVisible)
              Positioned.fill(
                child: Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _dismissTrayQuickPanel,
                      child:
                          Container(color: Colors.black.withValues(alpha: .32)),
                    ),
                    Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 58, right: 20),
                        child: MosaicTrayQuickPanel(
                          connected: trayStatus?.state == 'connected',
                          routeLabel: trayStatus?.server?.name ?? '',
                          onConnect: _connectFromTray,
                          onDisconnect: _disconnectFromTray,
                          onChooseRoute: _openRoutesFromTray,
                          onOpenApp: _dismissTrayQuickPanel,
                          onQuit: _quitApplication,
                          onDismiss: _dismissTrayQuickPanel,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTrayQuickPanel() async {
    await TrayService.instance.showWindow();
    if (mounted) setState(() => _trayQuickPanelVisible = true);
  }

  void _dismissTrayQuickPanel() {
    if (mounted) setState(() => _trayQuickPanelVisible = false);
  }

  Future<void> _connectFromTray() async {
    try {
      final api = ref.read(daemonApiProvider);
      final status = await api.getStatus();
      if (status.state == 'connected' || status.state == 'connecting') return;

      final subscriptions = await api.listSubscriptions();
      Subscription? mosaicSubscription;
      for (final subscription in subscriptions) {
        final uri = Uri.tryParse(subscription.url.trim());
        if (uri != null &&
            uri.isScheme('https') &&
            uri.host.toLowerCase() == 'sub.zxc1x1.ru' &&
            uri.pathSegments.isNotEmpty) {
          mosaicSubscription = subscription;
          break;
        }
      }
      final manifest = await api.getProviderManifest(
        subscriptionId: mosaicSubscription?.id,
      );
      // Probe-cache warmup for ALL groups (not just the one connecting):
      // fills the selector cache in the background so the next group switch
      // or a fresh connect is served from warm probes instead of a cold sweep.
      unawaited(
        SmartGroupRuntimeController.instance.prewarmGroups(
          api: api,
          selector: _smartGroupSelector,
          groups: manifest.groups,
        ),
      );
      final firstEnabledGroup =
          manifest.groups.where((group) => !group.disabled);
      if (firstEnabledGroup.isNotEmpty) {
        final group = firstEnabledGroup.first;
        final selection = await _smartGroupSelector.connect(api, group);
        SmartGroupRuntimeController.instance.start(
          api: api,
          selector: _smartGroupSelector,
          group: group,
          candidateId: selection.candidateId,
        );
      } else {
        final servers = await api.listServers();
        if (servers.isEmpty) {
          if (mounted) _showNoServersDialog();
          return;
        }
        await api.connect(servers.first.id);
      }
      ref.invalidate(vpnStatusProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Не удалось подключиться. Обновите маршрут и повторите попытку.'),
          ),
        );
      }
    }
  }

  Future<void> _disconnectFromTray() async {
    SmartGroupRuntimeController.instance.stop();
    try {
      await ref.read(daemonApiProvider).disconnect();
      ref.invalidate(vpnStatusProvider);
      if (mounted) {
        _dismissTrayQuickPanel();
      }
    } catch (error) {
      if (mounted) {
        final errText = error.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось отключиться: $errText'),
          ),
        );
      }
    }
  }

  Future<void> _openRoutesFromTray() async {
    if (!mounted) return;
    setState(() => _currentIndex = 1);
  }

  Future<void> _quitApplication() async {
    if (_quitting) return;
    SmartGroupRuntimeController.instance.stop();
    _quitting = true;
    try {
      // This asks mosaicd to disconnect the active runtime first. Its own
      // lifecycle then stops the sing-box child and releases the lockfile.
      await ref
          .read(daemonApiProvider)
          .shutdownDaemon()
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // A stale/missing daemon must not trap the user in the window. The
      // launcher only owns the process it started; daemon shutdown remains
      // best-effort when the lockfile is already gone.
    } finally {
      if (AppPlatform.isDesktop) {
        await TrayService.instance.dispose();
        await DesktopInstanceLock.instance.release();
        await TrayService.instance.closeWindowWithoutIntercept();
      }
    }
  }

  void _tryAutoConnect({required bool showLegacySetupPrompt}) {
    // Defer to next frame to let providers initialize
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final api = ref.read(daemonApiProvider);

        // An elevated relaunch (--connect-on-start) resumes the interrupted
        // TUN connection regardless of the autoConnect preference: the user
        // explicitly asked for this tunnel moments before the restart.
        final resumeAfterElevation =
            ElevationService.instance.shouldConnectOnStart;

        // Early exit: if auto-connect is off, skip server list fetches entirely.
        final prefs = await api.getPrefs();
        if (!mounted) return;
        if (!prefs.autoConnect && !resumeAfterElevation) return;

        final status = await api.getStatus();
        if (!mounted) return;
        if (status.state != 'disconnected') return;

        final uiPrefs = UiPreferencesService();
        final lastSavedRouteId = await uiPrefs.readLastConnectedRouteId();
        final lastSavedSubId = await uiPrefs.readLastConnectedSubscriptionId();
        if (lastSavedSubId != null && lastSavedSubId.isNotEmpty) {
          ref.read(selectedSubscriptionIdProvider.notifier).set(lastSavedSubId);
        }

        // Try reconnecting to the last active server/route, or prompt to add one.
        if (status.server != null) {
          await _connectTargetRoute(api, status.server!.id);
          if (!mounted) return;
          ref.invalidate(vpnStatusProvider);
        } else if (lastSavedRouteId != null && lastSavedRouteId.isNotEmpty) {
          ref.read(selectedRouteIdProvider.notifier).set(lastSavedRouteId);
          await _connectTargetRoute(api, lastSavedRouteId);
          if (!mounted) return;
          ref.invalidate(vpnStatusProvider);
        } else {
          final lastID = prefs.lastServerID;
          if (lastID.isNotEmpty) {
            ref.read(selectedRouteIdProvider.notifier).set(lastID);
            await _connectTargetRoute(api, lastID);
            if (!mounted) return;
            ref.invalidate(vpnStatusProvider);
          } else if (showLegacySetupPrompt) {
            // The desktop technical workspace may still guide legacy users to
            // import an existing subscription. Mobile uses smart groups and
            // never exposes the physical-server setup dialog.
            final servers = await api.listServers();
            if (!mounted) return;
            final subs = await api.listSubscriptions();
            if (!mounted) return;
            if (servers.isEmpty && subs.isEmpty) {
              _showNoServersDialog();
            }
          }
        }
      } catch (e) {
        debugPrint('auto-connect failed: $e');
      }
    });
  }

  Future<void> _connectTargetRoute(DaemonApiBase api, String routeId) async {
    // Route IDs are typed by the manifest. Never retry a failed group as a
    // physical server: that hides the original diagnostic and produces a
    // second, misleading error.
    if (routeId.startsWith('mosaic:') ||
        routeId.startsWith('provider:') ||
        routeId == 'direct' ||
        routeId == 'min-latency' ||
        routeId == 'stable' ||
        routeId == 'max-speed' ||
        routeId == 'germany' ||
        routeId == 'usa' ||
        routeId == 'netherlands' ||
        routeId == 'france' ||
        routeId == 'canada' ||
        routeId.startsWith('auto-')) {
      await api.connectGroup(routeId);
    } else {
      await api.connect(routeId);
    }
  }

  void _showNoServersDialog() {
    final c = ThemeColors.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        icon: Icon(Icons.wifi_off, size: 32, color: c.textMuted),
        title: const Text(
          'No Servers Found',
          style: TextStyle(fontFamily: AtlasTheme.serifFamily),
        ),
        content: Text(
          'You have no VPN servers yet. Add a subscription feed to import servers and get started.',
          style: TextStyle(fontSize: 13, color: c.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Later'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              // Open the unified Profiles & Routes workspace.
              setState(() => _currentIndex = 1);
              // Trigger add-subscription dialog
              ref.read(addSubscriptionTriggerProvider.notifier).state = true;
            },
            icon: const Icon(Icons.add_link, size: 16),
            label: const Text('Add Subscription'),
          ),
        ],
      ),
    );
  }
}

/// A tab stack that creates technical screens only after the user needs them.
///
/// Unlike IndexedStack, it does not eagerly build every child (and therefore
/// does not start polling in hidden pages). Offstage keeps already visited tabs
/// mounted so forms, scroll position and in-progress operations are preserved.
class _LazyTabStack extends StatelessWidget {
  final List<Widget> pages;
  final int currentIndex;
  final Set<int> visitedTabs;

  const _LazyTabStack({
    required this.pages,
    required this.currentIndex,
    required this.visitedTabs,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var index = 0; index < pages.length; index++)
          if (visitedTabs.contains(index))
            Offstage(
              key: ValueKey('mosaic-tab-$index'),
              offstage: index != currentIndex,
              child: TickerMode(
                enabled: index == currentIndex,
                child: pages[index],
              ),
            ),
      ],
    );
  }
}

/// Wraps a page with AutomaticKeepAlive to preserve state across tab switches.
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Sidebar icon button with tooltip.
class _SideIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SideIcon({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AtlasTheme.accent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
            border: Border.all(
              color: isSelected
                  ? AtlasTheme.accent.withValues(alpha: 0.3)
                  : Colors.transparent,
            ),
          ),
          child: Icon(
            icon,
            size: 22,
            color: isSelected ? AtlasTheme.accent : c.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Navigation destination metadata.
class _NavDestination {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}
