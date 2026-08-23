import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/atlas_theme.dart';
import '../core/platform/app_platform.dart';
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
  bool _enrollmentCompleting = false;
  final Set<String> _completedDesktopEnrollmentCallbacks = <String>{};
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
      // protocol launches. Android keeps its dedicated native callback slots
      // to prevent an auth callback from colliding with enrollment.
      _desktopEnrollmentCallbackSubscription =
          AppLinks().uriLinkStream.listen(_completeDesktopWebsiteEnrollment);
    }
    if (AppPlatform.isAndroid) {
      _enrollmentCallbackSubscription =
          AndroidVpnService.instance.enrollmentCallbacks.listen((_) {
        _completeWebsiteEnrollment();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _completeWebsiteEnrollment();
    });
  }

  @override
  void dispose() {
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

  /// Completes an explicit browser-to-app enrollment when Android returns via
  /// `mosaicvpn://enroll/callback`. The method is safe on normal launches: no
  /// pending callback simply returns without changing the selected screen.
  Future<void> _completeWebsiteEnrollment() async {
    if (!AppPlatform.isAndroid || _enrollmentCompleting) return;
    final api = ref.read(daemonApiProvider);
    if (api is! AndroidHostedDaemonApi) return;
    try {
      _enrollmentCompleting = true;
      final subscription = await api.completeWebsiteEnrollmentIfPresent();
      if (subscription == null || !mounted) return;
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      setState(() => _currentIndex = 1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Подписка «${subscription.name}» добавлена в приложение.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.toString().replaceFirst('Bad state: ', ''),
          ),
        ),
      );
    } finally {
      _enrollmentCompleting = false;
    }
  }

  /// Receives a desktop callback after the Windows/Linux launcher passes it
  /// into the existing MosaicVPN process. Unlike a manual URL import, this
  /// preserves the provider identity and the secure hosted cabinet session.
  Future<void> _completeDesktopWebsiteEnrollment(Uri callback) async {
    if (!AppPlatform.isDesktop || _enrollmentCompleting) return;
    final callbackKey = MosaicEnrollmentExchange.callbackDeliveryKey(callback);
    if (callbackKey != null &&
        _completedDesktopEnrollmentCallbacks.contains(callbackKey)) {
      // Windows can deliver a protocol invocation more than once to an already
      // running application. The first delivery has already installed the same
      // source; do not re-redeem its one-time browser code and create a 409.
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      if (mounted) setState(() => _currentIndex = 1);
      return;
    }
    try {
      _enrollmentCompleting = true;
      final enrollment = await AndroidMosaicAccountService.instance
          .completeEnrollmentCallback(callback);
      if (callbackKey != null) {
        _completedDesktopEnrollmentCallbacks.add(callbackKey);
      }
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
      final api = ref.read(daemonApiProvider);
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
      if (!mounted) return;
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(unifiedAccountProvider);
      setState(() => _currentIndex = 1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'MosaicVPN добавлен: ${subscription.serverCount} маршрутов и кабинет подключены.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', ''))),
      );
    } finally {
      _enrollmentCompleting = false;
    }
  }

  /// Called when the app returns from a browser deep link.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _completeWebsiteEnrollment();
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
                  : Container(
                      decoration: BoxDecoration(
                        color: c.bgInk,
                        border: Border(
                          top: BorderSide(color: c.borderInk, width: 1),
                        ),
                      ),
                      child: BottomNavigationBar(
                        currentIndex: activeIndex,
                        onTap: (index) => setState(() => _currentIndex = index),
                        type: BottomNavigationBarType.fixed,
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        selectedItemColor: AtlasTheme.accent,
                        unselectedItemColor: c.textMuted,
                        selectedFontSize: 11,
                        unselectedFontSize: 11,
                        items: _mainDestinations(context)
                            .map(
                              (dest) => BottomNavigationBarItem(
                                icon: Icon(dest.icon),
                                activeIcon: Icon(dest.activeIcon),
                                label: dest.label,
                              ),
                            )
                            .toList(),
                      ),
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
      final firstEnabledGroup =
          manifest.groups.where((group) => !group.disabled);
      if (firstEnabledGroup.isNotEmpty) {
        await _smartGroupSelector.connect(api, firstEnabledGroup.first);
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
    try {
      await ref.read(daemonApiProvider).disconnect();
      ref.invalidate(vpnStatusProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось отключиться. Повторите попытку.'),
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

        // Try reconnecting to the last active server, or prompt to add one.
        if (status.server != null) {
          await api.connect(status.server!.id);
          if (!mounted) return;
          ref.invalidate(vpnStatusProvider);
        } else {
          final lastID = prefs.lastServerID;
          if (lastID.isNotEmpty) {
            await api.connect(lastID);
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
              child: pages[index],
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
