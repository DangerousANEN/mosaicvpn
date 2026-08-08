import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';
import '../servers/servers_screen.dart';
import '../profiles/profiles_screen.dart';
import '../provider_profile/provider_profile_screen.dart';
import '../routing/routing_screen.dart';
import '../egresses/egresses_screen.dart';
import '../connections/connections_screen.dart';
import '../stats/stats_screen.dart';
import '../speedtest/speedtest_screen.dart';
import '../cores/cores_screen.dart';
import '../logs/logs_screen.dart';
import '../settings/settings_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);

    final items = <_MoreItem>[
      _MoreItem(
        title: 'Stations',
        subtitle: 'VPN servers and nodes',
        icon: Icons.dns_outlined,
        builder: (_) => const ServersScreen(),
      ),
      _MoreItem(
        title: 'Profiles',
        subtitle: 'Named configurations and presets',
        icon: Icons.book_outlined,
        builder: (_) => const ProfilesScreen(),
      ),
      _MoreItem(
        title: 'Provider',
        subtitle: 'Provider manifest and account profile',
        icon: Icons.verified_outlined,
        builder: (_) => const ProviderProfileScreen(),
      ),
      _MoreItem(
        title: 'Routes',
        subtitle: 'Routing rules and split tunneling',
        icon: Icons.hub_outlined,
        builder: (_) => const RoutingScreen(),
      ),
      _MoreItem(
        title: 'Egresses',
        subtitle: 'Outbound network chains and nodes',
        icon: Icons.account_tree_outlined,
        builder: (_) => const EgressesScreen(),
      ),
      _MoreItem(
        title: 'Activity',
        subtitle: 'Active connections and bandwidth',
        icon: Icons.visibility_outlined,
        builder: (_) => const ConnectionsScreen(),
      ),
      _MoreItem(
        title: 'Stats',
        subtitle: 'Traffic statistics and graphs',
        icon: Icons.bar_chart_outlined,
        builder: (_) => const StatsScreen(),
      ),
      _MoreItem(
        title: 'Speed Test',
        subtitle: 'Latency and throughput benchmarks',
        icon: Icons.speed_outlined,
        builder: (_) => const SpeedTestScreen(),
      ),
      _MoreItem(
        title: 'Cores',
        subtitle: 'Core engines and executable management',
        icon: Icons.memory_outlined,
        builder: (_) => const CoresScreen(),
      ),
      _MoreItem(
        title: 'Logs',
        subtitle: 'System events and daemon logs',
        icon: Icons.receipt_long_outlined,
        builder: (_) => const LogsScreen(),
      ),
      _MoreItem(
        title: 'Settings',
        subtitle: 'App preferences and core configuration',
        icon: Icons.settings_outlined,
        builder: (_) => const SettingsScreen(),
      ),
    ];

    return Scaffold(
      backgroundColor: c.bgBase,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  'More Tools & Settings',
                  style: TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: c.textPrimary,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = items[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Material(
                        color: c.bgCard,
                        borderRadius:
                            BorderRadius.circular(AtlasTheme.radiusMd),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AtlasTheme.radiusMd),
                            side: BorderSide(color: c.border, width: 1),
                          ),
                          leading: Icon(item.icon, color: AtlasTheme.accent),
                          title: Text(
                            item.title,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            item.subtitle,
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: c.textMuted,
                          ),
                          onTap: () {
                            final target = item.builder(context);
                            Widget page = target;
                            // Ensure pushed screen has Scaffold + AppBar if needed
                            if (target is! Scaffold) {
                              page = Scaffold(
                                backgroundColor: c.bgBase,
                                appBar: AppBar(
                                  backgroundColor: c.bgCard,
                                  title: Text(
                                    item.title,
                                    style: TextStyle(color: c.textPrimary),
                                  ),
                                  iconTheme: IconThemeData(color: c.textPrimary),
                                ),
                                body: target,
                              );
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => page),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  childCount: items.length,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;

  const _MoreItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });
}
