import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/atlas_theme.dart';
import '../core/platform/app_platform.dart';
import '../core/providers/vpn_providers.dart';
import '../core/models/models.dart';
import '../core/services/tray_service.dart';
import '../shared/widgets/atlas_widgets.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/servers/servers_screen.dart';
import '../features/profiles/profiles_screen.dart';
import '../features/subscriptions/subscriptions_screen.dart';
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

  /// Main 5 bottom navigation destinations
  final _mainDestinations = const <_NavDestination>[
    _NavDestination(
        icon: Icons.dashboard_outlined,
        activeIcon: Icons.dashboard,
        label: 'Dashboard'),
    _NavDestination(
        icon: Icons.bolt_outlined, activeIcon: Icons.bolt, label: 'Groups'),
    _NavDestination(
        icon: Icons.subscriptions_outlined,
        activeIcon: Icons.subscriptions,
        label: 'Subscriptions'),
    _NavDestination(
        icon: Icons.account_balance_wallet_outlined,
        activeIcon: Icons.account_balance_wallet,
        label: 'Billing'),
    _NavDestination(
        icon: Icons.more_horiz_outlined,
        activeIcon: Icons.more_horiz,
        label: 'More'),
  ];

  /// Full list of destinations for desktop/sidebar navigation (>900px)
  final _destinations = const <_NavDestination>[
    _NavDestination(
        icon: Icons.dashboard_outlined,
        activeIcon: Icons.dashboard,
        label: 'Dashboard'),
    _NavDestination(
        icon: Icons.dns_outlined, activeIcon: Icons.dns, label: 'Stations'),
    _NavDestination(
        icon: Icons.book_outlined, activeIcon: Icons.book, label: 'Profiles'),
    _NavDestination(
        icon: Icons.subscriptions_outlined,
        activeIcon: Icons.subscriptions,
        label: 'Subscriptions'),
    _NavDestination(
        icon: Icons.account_balance_wallet_outlined,
        activeIcon: Icons.account_balance_wallet,
        label: 'Billing'),
    _NavDestination(
        icon: Icons.bolt_outlined, activeIcon: Icons.bolt, label: 'Groups'),
    _NavDestination(
        icon: Icons.person_outline,
        activeIcon: Icons.person,
        label: 'Account'),
    _NavDestination(
        icon: Icons.verified_outlined,
        activeIcon: Icons.verified,
        label: 'Provider'),
    _NavDestination(
        icon: Icons.hub_outlined, activeIcon: Icons.hub, label: 'Routes'),
    _NavDestination(
        icon: Icons.account_tree_outlined,
        activeIcon: Icons.account_tree,
        label: 'Egresses'),
    _NavDestination(
        icon: Icons.visibility_outlined,
        activeIcon: Icons.visibility,
        label: 'Activity'),
    _NavDestination(
        icon: Icons.bar_chart_outlined,
        activeIcon: Icons.bar_chart,
        label: 'Stats'),
    _NavDestination(
        icon: Icons.speed_outlined,
        activeIcon: Icons.speed,
        label: 'Speed Test'),
    _NavDestination(
        icon: Icons.memory_outlined, activeIcon: Icons.memory, label: 'Cores'),
    _NavDestination(
        icon: Icons.receipt_long_outlined,
        activeIcon: Icons.receipt_long,
        label: 'Logs'),
    _NavDestination(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AppPlatform.isDesktop) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (AppPlatform.isDesktop) {
      windowManager.removeListener(this);
      TrayService.instance.dispose();
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
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  /// Called when the app window is minimized.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Lifecycle hooks for tray/minimize handled in main.dart
  }

  /// 5 Main tab pages cached with _KeepAlive
  List<Widget> get _mainPages => [
        const _KeepAlive(child: DashboardScreen()),
        const _KeepAlive(child: GroupsScreen()),
        const _KeepAlive(child: SubscriptionsScreen()),
        const _KeepAlive(child: BillingScreen()),
        const _KeepAlive(child: MoreScreen()),
      ];

  /// Full pages list for wide screen sidebar navigation (>900px)
  List<Widget> get _allPages => [
        const _KeepAlive(child: DashboardScreen()),
        const _KeepAlive(child: ServersScreen()),
        const _KeepAlive(child: ProfilesScreen()),
        const _KeepAlive(child: SubscriptionsScreen()),
        const _KeepAlive(child: BillingScreen()),
        const _KeepAlive(child: GroupsScreen()),
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
    final width = MediaQuery.of(context).size.width;
    final isWide = width > 900;

    // Auto-connect on first frame (q3)
    if (!_autoConnectTriggered) {
      _autoConnectTriggered = true;
      _tryAutoConnect();
    }

    // Clamp active index for the current layout mode
    final activeIndex = isWide
        ? _currentIndex.clamp(0, _allPages.length - 1)
        : _currentIndex.clamp(0, _mainPages.length - 1);

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
                              message: 'MosaicBox',
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                      AtlasTheme.radiusSm),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                      AtlasTheme.radiusSm),
                                  child: Image.asset(
                                    'assets/icon.png',
                                    width: 36,
                                    height: 36,
                                    fit: BoxFit.cover,
                                  ),
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
                                        _destinations.length, (i) => i)
                                    : const [0, 1, 3, 5, 6, 11, 14];

                                return ListView.builder(
                                  itemCount: visibleIndices.length,
                                  itemBuilder: (context, idx) {
                                    final i = visibleIndices[idx];
                                    final dest = _destinations[i];
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
                            onNavigate: (i) => setState(() => _currentIndex = i),
                          ),
                          Expanded(
                            child: IndexedStack(
                              index: activeIndex,
                              children: _allPages,
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
                      child: IndexedStack(
                        index: activeIndex,
                        children: _mainPages,
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
                    items: _mainDestinations
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

  void _tryAutoConnect() {
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
          } else {
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
              // Switch to Subscriptions tab
              setState(() => _currentIndex = 2);
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
                        label: 'Disconnect',
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
                            label: 'Quick Connect',
                            compact: compact,
                            onPressed: () => onNavigate(1),
                          )
                        : const SizedBox.shrink(),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),

              const SizedBox(width: 8),

              // ── Settings shortcut ──
              IconButton(
                icon: const Icon(Icons.settings, size: 18),
                tooltip: 'Settings',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(8),
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
          ? 'Connected · ${status.server!.name}'
          : 'Connected',
      'connecting' => 'Connecting…',
      'disconnected' => 'Disconnected',
      'error' => 'Error',
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
          ? 'Kill Switch ON — network blocked when VPN drops'
          : 'Kill Switch OFF — enable to block traffic on VPN disconnect',
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
                'Kill Switch',
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
