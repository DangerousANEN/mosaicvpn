import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/atlas_theme.dart';

import '../../core/providers/vpn_providers.dart';
import '../../core/providers/routing_presets_provider.dart';

/// Contextual dashboard tips. Each tip fires at most once per install (tracked
/// in SharedPreferences) and can be dismissed. Aimed at non-technical users:
/// one sentence of context plus a single obvious action button.
class DashboardTips extends ConsumerStatefulWidget {
  const DashboardTips({super.key});

  @override
  ConsumerState<DashboardTips> createState() => _DashboardTipsState();
}

class _DashboardTipsState extends ConsumerState<DashboardTips> {
  static const _kDismissedKey = 'mosaic.dismissed_tips.v1';
  List<String>? _dismissed;

  Future<Set<String>> _loadDismissed() async {
    if (_dismissed != null) return _dismissed!.toSet();
    final storage = await SharedPreferences.getInstance();
    _dismissed = storage.getStringList(_kDismissedKey) ?? [];
    return _dismissed!.toSet();
  }

  Future<void> _dismiss(String id) async {
    final storage = await SharedPreferences.getInstance();
    final dismissed = await _loadDismissed();
    dismissed.add(id);
    _dismissed = dismissed.toList();
    await storage.setStringList(_kDismissedKey, _dismissed!);
    if (mounted) setState(() {});
  }

  /// Evaluates which tip deserves attention right now, in priority order.
  Future<_Tip?> _pickTip() async {
    final dismissed = await _loadDismissed();
    String routingMode = 'rule';
    var hasBypass = false;
    try {
      final prefs =
          await ref.read(daemonApiProvider).getPrefs();
      routingMode = prefs.routingMode;
      hasBypass = prefs.bypassProcesses.isNotEmpty;
    } catch (_) {
      return null; // preferences unavailable — stay quiet
    }

    // Tip 1: banking apps + VPN conflict — the single most common RF complaint.
    if (!dismissed.contains('rf-banks') && !hasBypass) {
      return const _Tip(
        id: 'rf-banks',
        icon: Icons.account_balance,
        title: 'Устали выключать VPN ради банка?',
        body: 'Банковские приложения могут блокировать вход с зарубежного IP. '
            'Включите режим, при котором банки и Госуслуги ходят напрямую, '
            'а всё остальное — через VPN.',
        actionLabel: 'Банки в обход VPN',
        presetId: 'preset-rf-banks',
      );
    }
    // Tip 2: suggest the media preset for battery-conscious users on global mode.
    if (!dismissed.contains('rf-media') &&
        routingMode == 'global' &&
        !hasBypass) {
      return const _Tip(
        id: 'rf-media',
        icon: Icons.play_circle_outline,
        title: 'VPN тратит батарею?',
        body: 'Можно пускать через VPN только соцсети и YouTube, а остальное '
            'оставить напрямую. Экономит заряд и не мешает банкам.',
        actionLabel: 'Только соцсети через VPN',
        presetId: 'preset-rf-media',
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return FutureBuilder<_Tip?>(
      future: _pickTip(),
      builder: (context, snapshot) {
        final tip = snapshot.data;
        if (tip == null) return const SizedBox.shrink();
        return Card(
          color: c.bgCard,
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(tip.icon, size: 20, color: c.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tip.title,
                        style: TextStyle(
                          fontFamily: AtlasTheme.serifFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _dismiss(tip.id),
                      icon: Icon(Icons.close, size: 18, color: c.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  tip.body,
                  style: TextStyle(
                      fontSize: 12.5, height: 1.35, color: c.textSecondary),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        final presets =
                            await ref.read(routingPresetsProvider.future);
                        final preset = presets
                            .where((p) => p.id == tip.presetId)
                            .toList(growable: false);
                        if (preset.isNotEmpty) {
                          await applyRoutingPreset(ref, preset.first);
                        }
                        await _dismiss(tip.id);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Готово! Переподключитесь, чтобы применилось.')),
                          );
                        }
                      } catch (_) {
                        // silent — the tip stays for another day
                      }
                    },
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(tip.actionLabel),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Tip {
  final String id;
  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final String presetId;

  const _Tip({
    required this.id,
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.presetId,
  });
}
