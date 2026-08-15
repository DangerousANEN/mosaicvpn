import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/atlas_theme.dart';
import '../core/platform/app_platform.dart';
import '../core/providers/vpn_providers.dart';
import '../core/i18n/app_strings.dart';
import '../core/models/models.dart';
import '../core/services/tray_service.dart';
import '../shared/widgets/atlas_widgets.dart';
import '../features/dashboard/connection_dashboard.dart';
import '../features/connections/connections_screen.dart';
import '../features/routing/routing_screen.dart';
import '../features/egresses/egresses_screen.dart';
import '../features/stats/stats_screen.dart';
import '../features/speedtest/speedtest_screen.dart';
import '../features/cores/cores_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/logs/logs_screen.dart';
import '../features/billing/billing_screen.dart';
import '../features/account/account_screen.dart';
import '../features/groups/groups_screen.dart';
import '../features/provider_profile/provider_profile_screen.dart';
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
          icon: Icons.person_outline,
          activeIcon: Icons.person,
          label: s.t('account')),
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
          icon: Icons.account_balance_wallet_outlined,
          activeIcon: Icons.account_balance_wallet,
          label: s.t('balance')),
      _NavDestination(
          icon: Icons.person_outline,
          activeIcon: Icons.person,
          label: s.t('account')),
      _NavDestination(
          icon: Icons.verified_outlined,
          activeIcon: Icons.verified,
          label: s.t('provider')),
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
        onQuit: _quitApplication,
      );
    }
  }

  @override
  void dispose() {
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

  /// Called when the app window is minimized.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Lifecycle hooks for tray/minimize handled in main.dart
  }

  /// Primary pages are deliberately limited to the common everyday tasks.
  List<Widget> get _mainPages => [
        const _KeepAlive(child: ConnectionDashboard()),
        const _KeepAlive(child: GroupsScreen()),
        const _KeepAlive(child: AccountScreen()),
        const _KeepAlive(child: MoreScreen()),
      ];

  /// Full pages list for wide screen sidebar navigation (>900px)
  List<Widget> get _allPages => [
        const _KeepAlive(child: ConnectionDashboard()),
        const _KeepAlive(child: GroupsScreen()),
        const _KeepAlive(child: BillingScreen()),
        const _KeepAlive(child: AccountScreen()),
        const _KeepAlive(child: ProviderProfileScreen()),
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
    final trayStatus = ref.watch(vpnStatusProvider).valueOrNull;
    final closeToTray =
        ref.watch(prefsProvider).valueOrNull?.minimizeToTray ?? true;
    if (AppPlatform.isDesktop) {
      TrayService.instance.configure(minimizeToTray: closeToTray);
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
        child: Scaffold(
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
                                final isAdvanced = prefs?.advancedMode ?? false;
                                final visibleIndices = isAdvanced
                                    ? List.generate(
                                        destinations.length, (i) => i)
                                    : const [0, 1, 3, 5, 6, 11, 12];

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
                          _QuickStatusBar(
                            currentIndex: activeIndex,
                            onNavigate: (i) =>
                                setState(() => _currentIndex = i),
                          ),
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
              : Column(
                  children: [
                    _QuickStatusBar(
                      currentIndex: activeIndex,
                      onNavigate: (i) => setState(() => _currentIndex = i),
                    ),
                    Expanded(
                      child: _LazyTabStack(
                        pages: pages,
                        currentIndex: activeIndex,
                        visitedTabs: visitedTabs,
                      ),
                    ),
                  ],
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
      ),
    );
  }

  Future<void> _connectFromTray() async {
    try {
      final api = ref.read(daemonApiProvider);
      final status = await api.getStatus();
      if (status.state == 'connected' || status.state == 'connecting') return;

      final manifest = await api.getProviderManifest();
      if (manifest.groups.isNotEmpty) {
        await api.connectGroup(manifest.groups.first.id);
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
        await TrayService.instance.closeWindowWithoutIntercept();
      }
    }
  }

  void _tryAutoConnect({required bool showLegacySetupPrompt}) {
    // Defer to next frame to let providers initialize
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final api = ref.read(daemonApiProvider);

        // Early exit: if auto-connect is off, skip server list fetches entirely.
        final prefs = await api.getPrefs();
        if (!mounted) return;
        if (!prefs.autoConnect) return;

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

/// Quick status bar at the top showing VPN status, kill switch toggle, and quick actions.
class _QuickStatusBar extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onNavigate;

  const _QuickStatusBar({required this.currentIndex, required this.onNavigate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final statusAsync = ref.watch(vpnStatusProvider);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.bgCard,
        border: Border(
          bottom: BorderSide(color: c.border, width: 1),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a 360px phone the status pill, kill switch, a labelled action
          // button and the settings icon do not fit side by side -- the row
          // overflowed by ~260px. Below this width the action button drops its
          // text label and keeps the icon.
          final compact = constraints.maxWidth < 480;

          return Row(
            children: [
              // ── VPN Status indicator ──
              Flexible(
                child: statusAsync.when(
                  data: (status) => _StatusPill(status: status),
                  loading: () => const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (_, __) =>
                      Text('—', style: TextStyle(color: c.textMuted)),
                ),
              ),

              const SizedBox(width: 16),

              // ── Kill switch quick toggle (q2) ──
              statusAsync.when(
                data: (status) => _KillSwitchToggle(status: status),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),

              const Spacer(),

              // ── Quick disconnect/connect button ──
              statusAsync.when(
                data: (status) => status.state == 'connected'
                    ? _QuickAction(
                        icon: Icons.power_settings_new,
                        label: 'Отключить',
                        compact: compact,
                        onPressed: () async {
                          try {
                            await ref.read(daemonApiProvider).disconnect();
                          } catch (e) {
                            debugPrint('disconnect failed: $e');
                          }
                          ref.invalidate(vpnStatusProvider);
                        },
                      )
                    : status.state == 'disconnected'
                        ? _QuickAction(
                            icon: Icons.bolt,
                            label: 'Подключиться',
                            compact: compact,
                            onPressed: () => onNavigate(0),
                          )
                        : const SizedBox.shrink(),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Quick-bar action that sheds its text label when horizontal space is tight.
class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool compact;
  final VoidCallback onPressed;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.compact,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(
        icon: Icon(icon, size: 18),
        tooltip: label,
        onPressed: onPressed,
        constraints: const BoxConstraints(),
        padding: const EdgeInsets.all(8),
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

/// Compact VPN status pill for the quick bar.
class _StatusPill extends StatelessWidget {
  final VpnStatus status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final isConnected = status.state == 'connected';
    final isConnecting = status.state == 'connecting';
    final color = isConnected
        ? AtlasTheme.success
        : isConnecting
            ? AtlasTheme.warning
            : c.textMuted;

    final label = switch (status.state) {
      'connected' => status.server != null
          ? 'Подключено · ${status.server!.name}'
          : 'Подключено',
      'connecting' => 'Подключаемся…',
      'disconnected' => 'Не подключено',
      'error' => 'Ошибка',
      _ => status.state,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pulsing indicator
        StatusDot(color: color, size: isConnecting ? 8 : 7),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AtlasTheme.sansFamily,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isConnected ? c.textPrimary : c.textMuted,
            ),
          ),
        ),
        if (isConnected && status.latencyMS > 0) ...[
          const SizedBox(width: 6),
          LatencyBadge(latencyMS: status.latencyMS),
        ],
      ],
    );
  }
}

/// Kill switch quick toggle for the quick bar (q2).
class _KillSwitchToggle extends ConsumerStatefulWidget {
  final VpnStatus status;
  const _KillSwitchToggle({required this.status});

  @override
  ConsumerState<_KillSwitchToggle> createState() => _KillSwitchToggleState();
}

class _KillSwitchToggleState extends ConsumerState<_KillSwitchToggle> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final ks = widget.status.killSwitch;
    return Tooltip(
      message: ks
          ? 'Защита сети включена: трафик блокируется при разрыве VPN'
          : 'Защита сети выключена: включите её, чтобы блокировать трафик при разрыве VPN',
      child: InkWell(
        onTap: _loading
            ? null
            : () async {
                setState(() => _loading = true);
                try {
                  await ref
                      .read(daemonApiProvider)
                      .setPrefs({'kill_switch': !ks});
                  ref.invalidate(vpnStatusProvider);
                  ref.invalidate(prefsProvider);
                } finally {
                  if (mounted) setState(() => _loading = false);
                }
              },
        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: ks ? AtlasTheme.errorDim : c.bgHover,
            borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
            border: Border.all(
              color: ks ? AtlasTheme.error.withValues(alpha: 0.3) : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _loading
                    ? Icons.hourglass_top
                    : (ks ? Icons.shield : Icons.shield_outlined),
                size: 14,
                color: ks ? AtlasTheme.error : c.textMuted,
              ),
              const SizedBox(width: 4),
              Text(
                'Защита',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: ks ? AtlasTheme.error : c.textMuted,
                ),
              ),
            ],
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
