import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/atlas_theme.dart';

/// The first screen of MosaicVPN: one calm connection decision, with smart
/// groups rather than an overwhelming inventory of physical nodes.
class ConnectionDashboard extends ConsumerStatefulWidget {
  const ConnectionDashboard({super.key});

  @override
  ConsumerState<ConnectionDashboard> createState() =>
      _ConnectionDashboardState();
}

class _ConnectionDashboardState extends ConsumerState<ConnectionDashboard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();
  String? _selectedGroupId;
  bool _busy = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final status = ref.watch(vpnStatusProvider).valueOrNull ?? VpnStatus();
    final manifest = ref.watch(mosaicManifestProvider);
    final manifestGroups = manifest.valueOrNull?.groups ?? <ManifestGroup>[];
    final routeGroups = manifestGroups
        .where((group) =>
            group.category == 'smart' || group.category == 'whitelist')
        .toList();
    final groups = routeGroups.isEmpty ? _fallbackGroups : routeGroups;
    final selected = groups.firstWhere(
      (group) => group.id == _selectedGroupId,
      orElse: () => groups.first,
    );
    if (_selectedGroupId == null && groups.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedGroupId == null) {
          setState(() => _selectedGroupId = groups.first.id);
        }
      });
    }

    return Scaffold(
      backgroundColor: c.bgBase,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 760;
            return isDesktop
                ? _buildDesktopLayout(context, c, status, groups, selected)
                : _buildMobileLayout(context, c, status, groups, selected);
          },
        ),
      ),
    );
  }

  Widget _buildMobileLayout(
    BuildContext context,
    ThemeColors c,
    VpnStatus status,
    List<ManifestGroup> groups,
    ManifestGroup selected,
  ) {
    final s = AppStrings.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DashboardHeader(
            onRefresh: () => ref.invalidate(vpnStatusProvider),
          ),
          const SizedBox(height: 18),
          _ConnectionVisual(status: status, animation: _pulse),
          const SizedBox(height: 16),
          _RouteSelector(
            group: selected,
            onTap: () => _pickGroup(context, groups, selected),
          ),
          const SizedBox(height: 12),
          _connectionButton(c, status, selected, expand: true),
          const SizedBox(height: 12),
          _ProtectionRow(status: status),
          const SizedBox(height: 22),
          _SectionTitle(s.t('quick_select')),
          const SizedBox(height: 12),
          _quickGroups(c, groups, selected),
          const SizedBox(height: 18),
          _HowItWorksCard(compact: true),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(
    BuildContext context,
    ThemeColors c,
    VpnStatus status,
    List<ManifestGroup> groups,
    ManifestGroup selected,
  ) {
    final s = AppStrings.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(40, 32, 40, 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DashboardHeader(
                onRefresh: () => ref.invalidate(vpnStatusProvider),
                desktop: true,
              ),
              const SizedBox(height: 26),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 7,
                    child: _DesktopSurface(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _ConnectionVisual(
                              status: status,
                              animation: _pulse,
                              compact: true,
                            ),
                            const SizedBox(height: 22),
                            _connectionButton(c, status, selected),
                            const SizedBox(height: 18),
                            _ProtectionRow(status: status),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 22),
                  SizedBox(
                    width: 332,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _DesktopSurface(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _SectionTitle(s.t('route_picker')),
                                const SizedBox(height: 12),
                                _RouteSelector(
                                  group: selected,
                                  onTap: () =>
                                      _pickGroup(context, groups, selected),
                                ),
                                const SizedBox(height: 18),
                                _SectionTitle(s.t('quick_select'), small: true),
                                const SizedBox(height: 10),
                                _quickGroups(c, groups, selected,
                                    vertical: true),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _HowItWorksCard(),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionButton(
    ThemeColors c,
    VpnStatus status,
    ManifestGroup selected, {
    bool expand = false,
  }) {
    final button = SizedBox(
      height: 54,
      width: expand ? null : 238,
      child: FilledButton.icon(
        onPressed: _busy ? null : () => _toggle(status, selected),
        style: FilledButton.styleFrom(
          backgroundColor: status.isConnected ? c.danger : AtlasTheme.accent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        ),
        icon: Icon(
            status.isConnected ? Icons.stop_rounded : Icons.shield_outlined),
        label: Text(
          _busy
              ? AppStrings.of(context).t('searching_route')
              : status.isConnected
                  ? AppStrings.of(context).t('disconnect_action')
                  : AppStrings.of(context).t('connect_action'),
        ),
      ),
    );
    return expand ? button : Align(alignment: Alignment.center, child: button);
  }

  Widget _quickGroups(
    ThemeColors c,
    List<ManifestGroup> groups,
    ManifestGroup selected, {
    bool vertical = false,
  }) {
    final chips = groups.take(vertical ? 6 : 5).map((group) {
      final active = group.id == selected.id;
      return ChoiceChip(
        label: Text(_localizedGroupTitle(context, group),
            overflow: TextOverflow.ellipsis),
        selected: active,
        onSelected: (_) => setState(() => _selectedGroupId = group.id),
        selectedColor: AtlasTheme.accent.withValues(alpha: .18),
        labelStyle: TextStyle(
          color: active ? AtlasTheme.accent : c.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      );
    }).toList();
    if (!vertical) {
      return Wrap(spacing: 8, runSpacing: 8, children: chips);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: groups.take(6).map((group) {
        final active = group.id == selected.id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Material(
            color: active ? AtlasTheme.accent.withValues(alpha: .13) : c.bgBase,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: () => setState(() => _selectedGroupId = group.id),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: active
                        ? AtlasTheme.accent.withValues(alpha: .42)
                        : c.border,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      active
                          ? Icons.check_circle_rounded
                          : Icons.route_outlined,
                      size: 17,
                      color: active ? AtlasTheme.accent : c.textMuted,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        _localizedGroupTitle(context, group),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? AtlasTheme.accent : c.textPrimary,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _toggle(VpnStatus status, ManifestGroup selected) async {
    final api = ref.read(daemonApiProvider);
    try {
      setState(() => _busy = true);
      if (status.isConnected || status.isConnecting) {
        await api.disconnect();
      } else {
        final node = await api.selectNodeFromGroup(selected.id);
        await api.connect(node.id);
      }
      ref.invalidate(vpnStatusProvider);
    } catch (_) {
      if (mounted) {
        _notice(
          AppStrings.of(context).t('connection_failed'),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickGroup(BuildContext context, List<ManifestGroup> groups,
      ManifestGroup current) async {
    final selected = await showModalBottomSheet<ManifestGroup>(
      context: context,
      builder: (context) => SafeArea(
          child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppStrings.of(context).t('route_picker'),
                  style: TextStyle(
                      fontFamily: AtlasTheme.serifFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 23,
                      color: ThemeColors.of(context).textPrimary)),
              const SizedBox(height: 6),
              Text(AppStrings.of(context).t('route_picker_hint'),
                  style: TextStyle(
                      color: ThemeColors.of(context).textSecondary,
                      fontSize: 12)),
              const SizedBox(height: 10),
              ...groups.map((group) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _groupIcon(group.icon),
                    title: Text(_localizedGroupTitle(context, group)),
                    subtitle: Text(_localizedGroupDescription(context, group)),
                    trailing: group.id == current.id
                        ? const Icon(Icons.check_circle,
                            color: AtlasTheme.accent)
                        : const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, group),
                  )),
            ]),
      )),
    );
    if (selected != null && mounted) {
      setState(() => _selectedGroupId = selected.id);
    }
  }

  void _notice(String value, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value),
          backgroundColor: error ? ThemeColors.of(context).danger : null));
}

class _DashboardHeader extends StatelessWidget {
  final VoidCallback onRefresh;
  final bool desktop;

  const _DashboardHeader({required this.onRefresh, this.desktop = false});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return Row(
      children: [
        Container(
          width: desktop ? 44 : 38,
          height: desktop ? 44 : 38,
          decoration: BoxDecoration(
            color: AtlasTheme.accent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.explore_outlined, color: AtlasTheme.onAccent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MosaicVPN',
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: desktop ? 26 : 23,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                desktop ? s.t('manage_route') : s.t('protected_route'),
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Обновить состояние',
          onPressed: onRefresh,
          icon: Icon(Icons.refresh_rounded, color: c.textSecondary),
        ),
      ],
    );
  }
}

class _DesktopSurface extends StatelessWidget {
  final Widget child;
  const _DesktopSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c.border.withValues(alpha: .8)),
        boxShadow: [
          BoxShadow(
            color: c.bgInk.withValues(alpha: .035),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String value;
  final bool small;
  const _SectionTitle(this.value, {this.small = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: TextStyle(
        color: ThemeColors.of(context).textPrimary,
        fontWeight: FontWeight.w700,
        fontSize: small ? 14 : 16,
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  final bool compact;
  const _HowItWorksCard({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bgElevated.withValues(alpha: compact ? .52 : .72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border.withValues(alpha: .75)),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AtlasTheme.accent.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.auto_awesome_outlined,
                  size: 17, color: AtlasTheme.accent),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(s.t('how_it_works'), small: true),
                  const SizedBox(height: 5),
                  Text(
                    s.t('route_works'),
                    style: TextStyle(
                        color: c.textSecondary, fontSize: 12, height: 1.42),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionVisual extends StatelessWidget {
  final VpnStatus status;
  final Animation<double> animation;
  final bool compact;
  const _ConnectionVisual({
    required this.status,
    required this.animation,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    final connected = status.isConnected;
    final connecting = status.isConnecting;
    final tint = connected
        ? c.success
        : connecting
            ? AtlasTheme.accent
            : c.textMuted;
    final title = connected
        ? s.t('connected')
        : connecting
            ? s.t('status_connecting')
            : s.t('status_disconnected');
    final subtitle = connected
        ? '${status.server?.name ?? s.t('minimum_ping')}${status.latencyMS > 0 ? ' · ${status.latencyMS} ms' : ''}'
        : connecting
            ? s.t('route_picker_hint')
            : '${s.t('route_picker')} — ${s.t('connect_action')}';
    return Container(
      height: compact ? 244 : 292,
      decoration: BoxDecoration(
          color: c.bgCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: tint.withValues(alpha: .32))),
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Positioned.fill(
              child: CustomPaint(
                  painter: _RoutePulsePainter(
                      progress: animation.value,
                      color: tint,
                      active: connected || connecting))),
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
                width: compact ? 72 : 82,
                height: compact ? 72 : 82,
                decoration: BoxDecoration(
                    color: tint.withValues(alpha: .14),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: tint.withValues(alpha: .7), width: 2)),
                child: Icon(
                    connected
                        ? Icons.lock_outline_rounded
                        : connecting
                            ? Icons.route_outlined
                            : Icons.power_settings_new_rounded,
                    color: tint,
                    size: compact ? 33 : 38)),
            SizedBox(height: compact ? 12 : 15),
            Text(title,
                style: TextStyle(
                    color: c.textPrimary,
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: compact ? 19 : 20,
                    fontWeight: FontWeight.w700),
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(subtitle,
                    style: TextStyle(color: c.textSecondary, fontSize: 12),
                    textAlign: TextAlign.center)),
          ]),
        ]),
      ),
    );
  }
}

class _RoutePulsePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool active;
  _RoutePulsePainter(
      {required this.progress, required this.color, required this.active});
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1;
      final radius = 38 + phase * math.min(size.width, size.height) * .38;
      final alpha = active ? (1 - phase) * .20 : .08;
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color.withValues(alpha: alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3);
    }
    final pathPaint = Paint()
      ..color = color.withValues(alpha: active ? .42 : .16)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(24, size.height * .72)
      ..quadraticBezierTo(size.width * .46, size.height * .13, size.width - 26,
          size.height * .31);
    canvas.drawPath(path, pathPaint);
    final point = path
        .computeMetrics()
        .first
        .extractPath(0, path.computeMetrics().first.length * progress)
        .getBounds()
        .bottomRight;
    canvas.drawCircle(point, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _RoutePulsePainter old) =>
      old.progress != progress || old.color != color || old.active != active;
}

class _RouteSelector extends StatelessWidget {
  final ManifestGroup group;
  final VoidCallback onTap;
  const _RouteSelector({required this.group, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return Material(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                _groupIcon(group.icon),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(
                          '${s.t('routes')}: ${_localizedGroupTitle(context, group)}',
                          style: TextStyle(
                              color: c.textPrimary,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                          group.description.isEmpty
                              ? s.t('route_picker_hint')
                              : _localizedGroupDescription(context, group),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.textMuted, fontSize: 12)),
                    ])),
                const Icon(Icons.expand_more_rounded),
              ])),
        ));
  }
}

class _ProtectionRow extends StatelessWidget {
  final VpnStatus status;
  const _ProtectionRow({required this.status});
  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return Row(children: [
      Icon(
          status.killSwitch ? Icons.verified_user_outlined : Icons.info_outline,
          size: 18,
          color: status.killSwitch ? c.success : c.warning),
      const SizedBox(width: 7),
      Expanded(
          child: Text(
              status.killSwitch
                  ? s.t('leak_protection_on')
                  : s.t('leak_protection_off'),
              style: TextStyle(color: c.textSecondary, fontSize: 12))),
      Text(
          status.tunnelMode == 'tun'
              ? s.t('vpn_mode')
              : s.t('proxy_mode_label'),
          style: TextStyle(color: c.textMuted, fontSize: 11)),
    ]);
  }
}

String _localizedGroupTitle(BuildContext context, ManifestGroup group) {
  final s = AppStrings.of(context);
  return switch (group.id) {
    'rg-all' => s.t('minimum_ping'),
    'auto-stable' => s.t('stable_connection'),
    'auto-speed' => s.t('maximum_speed'),
    'auto-whitelist' => s.t('allowlist_access'),
    'auto-de' => s.t('germany'),
    'auto-ca' => s.t('canada'),
    _ => group.title,
  };
}

String _localizedGroupDescription(BuildContext context, ManifestGroup group) {
  final s = AppStrings.of(context);
  return switch (group.id) {
    'rg-all' => s.t('minimum_ping_description'),
    'auto-stable' => s.t('stable_connection_description'),
    'auto-speed' => s.t('maximum_speed_description'),
    'auto-whitelist' => s.t('allowlist_access_description'),
    'auto-de' => s.t('germany_description'),
    'auto-ca' => s.t('canada_description'),
    _ => group.description.isEmpty ? group.badge : group.description,
  };
}

Widget _groupIcon(String raw) {
  final icon = switch (raw) {
    'lightning' => Icons.bolt_rounded,
    'speed' => Icons.speed_rounded,
    'shield' => Icons.shield_outlined,
    'flag_de' => Icons.flag_outlined,
    'flag_us' => Icons.flag_outlined,
    'flag_ca' => Icons.flag_outlined,
    _ => Icons.public_rounded,
  };
  return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
          color: AtlasTheme.accent.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: AtlasTheme.accent));
}

final List<ManifestGroup> _fallbackGroups = [
  ManifestGroup(
      id: 'rg-all',
      title: 'Минимальный пинг',
      badge: 'Оптимально',
      category: 'smart',
      icon: 'lightning',
      description: 'Самый быстрый отклик'),
  ManifestGroup(
      id: 'auto-de',
      title: 'Германия',
      badge: 'EU Fast',
      category: 'smart',
      icon: 'flag_de',
      description: 'Проверенные узлы Германии'),
  ManifestGroup(
      id: 'auto-speed',
      title: 'Максимальная скорость',
      badge: 'Speed',
      category: 'smart',
      icon: 'speed',
      description: 'Приоритет свежей скорости'),
];
