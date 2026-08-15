import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/i18n/app_strings.dart';
import '../account/account_screen.dart';
import '../profiles/profiles_screen.dart';
import '../routing/routing_screen.dart';
import '../connections/connections_screen.dart';
import '../stats/stats_screen.dart';
import '../speedtest/speedtest_screen.dart';
import '../logs/logs_screen.dart';
import '../settings/settings_screen.dart';
import '../groups/groups_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);

    final items = <_MoreItem>[
      _MoreItem(
        title: s.t('account'),
        subtitle: 'Subscription, traffic and payments',
        icon: Icons.person_outline,
        builder: (_) => const AccountScreen(),
      ),
      _MoreItem(
        title: s.t('routes'),
        subtitle: 'Subscriptions, smart groups and your own nodes',
        icon: Icons.route_outlined,
        builder: (_) => const GroupsScreen(),
      ),
      _MoreItem(
        title: s.t('profiles'),
        subtitle: 'Named configurations and presets',
        icon: Icons.book_outlined,
        builder: (_) => const ProfilesScreen(),
      ),
      _MoreItem(
        title: s.t('routing'),
        subtitle: 'Routing rules and split tunneling',
        icon: Icons.hub_outlined,
        builder: (_) => const RoutingScreen(),
      ),
      _MoreItem(
        title: s.t('activity'),
        subtitle: 'Active connections and bandwidth',
        icon: Icons.visibility_outlined,
        builder: (_) => const ConnectionsScreen(),
      ),
      _MoreItem(
        title: s.t('stats'),
        subtitle: 'Traffic statistics and graphs',
        icon: Icons.bar_chart_outlined,
        builder: (_) => const StatsScreen(),
      ),
      _MoreItem(
        title: s.t('speed'),
        subtitle: 'Latency and throughput benchmarks',
        icon: Icons.speed_outlined,
        builder: (_) => const SpeedTestScreen(),
      ),
      _MoreItem(
        title: s.t('logs'),
        subtitle: 'System events and daemon logs',
        icon: Icons.receipt_long_outlined,
        builder: (_) => const LogsScreen(),
      ),
      _MoreItem(
        title: s.t('settings'),
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
                  s.t('more'),
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
                                  iconTheme:
                                      IconThemeData(color: c.textPrimary),
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
