import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/providers/routing_presets_provider.dart';
import '../../core/models/models.dart';
import '../../core/models/routing_preset.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';

/// Routing screen — manage routing rules.
class RoutingScreen extends ConsumerWidget {
  const RoutingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final rulesAsync = ref.watch(rulesProvider);
    final prefs = ref.watch(prefsProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Routing Rules & Mode',
            subtitle: 'Direct traffic through proxy, direct, or block',
            action: ElevatedButton.icon(
              onPressed: () => _showAddDialog(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Rule'),
            ),
          ),
          const SizedBox(height: 12),

          // Routing Mode bar (Single Source of Truth)
          Row(
            children: [
              Text(
                'Active Mode:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'global', label: Text('Global (All VPN)')),
                  ButtonSegment(value: 'rule', label: Text('Rule-based')),
                  ButtonSegment(value: 'direct', label: Text('Direct (Bypass)')),
                ],
                selected: {prefs?.routingMode ?? 'rule'},
                onSelectionChanged: (s) async {
                  final current = prefs ?? Preferences();
                  final updated = current.copyWith(routingMode: s.first);
                  try {
                    await ref.read(daemonApiProvider).setPrefs(updated.toJson());
                    ref.invalidate(prefsProvider);
                  } catch (e) {
                    debugPrint('routing mode switch failed: $e');
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _RoutingPresetsSection(ref: ref),
          const SizedBox(height: 16),
          Expanded(
            child: rulesAsync.when(
              data: (rules) {
                if (rules.isEmpty) {
                  return _emptyState(context, ref);
                }
                return ReorderableListView.builder(
                  itemCount: rules.length,
                  onReorderItem: (oldIdx, newIdx) async {
                    final reordered = [...rules];
                    final item = reordered.removeAt(oldIdx);
                    reordered.insert(newIdx, item);
                    final api = ref.read(daemonApiProvider);
                    try {
                      await api.reorderRules(
                          reordered.map((r) => r.id).toList());
                      ref.invalidate(rulesProvider);
                    } catch (e) {
                      debugPrint('reorderRules failed: $e');
                      ref.invalidate(rulesProvider);
                    }
                  },
                  itemBuilder: (context, i) => _RuleTile(
                    key: ValueKey(rules[i].id),
                    rule: rules[i],
                    ref: ref,
                  ),
                );
              },
              loading: () => ListView.builder(
                  itemCount: 4,
                  itemBuilder: (_, __) =>
                      const Card(child: SkeletonServerRow())),
              error: (_, __) => _emptyState(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.alt_route, size: 48, color: c.textMuted),
          const SizedBox(height: 16),
          Text(
            'No routing rules.',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 18,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add rules to control how traffic is routed.',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => _showAddDialog(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('Add Rule'),
          ),
        ],
      ),
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final nameCtrl = TextEditingController();
    final action = ValueNotifier<RuleAction>(RuleAction.proxy);
    final domainSuffixCtrl = TextEditingController();
    final ipCIDRCtrl = TextEditingController();
    final processCtrl = TextEditingController();
    final geoSiteCtrl = TextEditingController();

    // Dispose all controllers+notifiers after the dialog closes — regardless
    // of whether the user tapped Add, Cancel, or used the back gesture.
    // Without this, every "Add Rule" dialog leaks 5 TextEditingControllers +
    // 1 ValueNotifier.
    void disposeAll() {
      nameCtrl.dispose();
      action.dispose();
      domainSuffixCtrl.dispose();
      ipCIDRCtrl.dispose();
      processCtrl.dispose();
      geoSiteCtrl.dispose();
    }

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
        ),
        title: const Text(
          'Add Routing Rule',
          style: TextStyle(fontFamily: AtlasTheme.serifFamily),
        ),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Rule Name'),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<RuleAction>(
                  valueListenable: action,
                  builder: (_, v, __) => SegmentedButton<RuleAction>(
                    segments: const [
                      ButtonSegment(
                          value: RuleAction.proxy, label: Text('Proxy')),
                      ButtonSegment(
                          value: RuleAction.direct, label: Text('Direct')),
                      ButtonSegment(
                          value: RuleAction.block, label: Text('Block')),
                    ],
                    selected: {v},
                    onSelectionChanged: (s) => action.value = s.first,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: domainSuffixCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Domain Suffix (comma-separated)',
                    hintText: 'example.com, google.com',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ipCIDRCtrl,
                  decoration: const InputDecoration(
                    labelText: 'IP CIDR (comma-separated)',
                    hintText: '192.168.0.0/16, 10.0.0.0/8',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: processCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Process (comma-separated)',
                    hintText: 'chrome.exe, firefox.exe',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: geoSiteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'GeoSite (comma-separated)',
                    hintText: 'category-ads, ru',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.isEmpty) return;
              final api = ref.read(daemonApiProvider);

              final match = <String, dynamic>{};
              if (domainSuffixCtrl.text.isNotEmpty) {
                match['domain_suffix'] = domainSuffixCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .toList();
              }
              if (ipCIDRCtrl.text.isNotEmpty) {
                match['ip_cidr'] =
                    ipCIDRCtrl.text.split(',').map((s) => s.trim()).toList();
              }
              if (processCtrl.text.isNotEmpty) {
                match['process'] =
                    processCtrl.text.split(',').map((s) => s.trim()).toList();
              }
              if (geoSiteCtrl.text.isNotEmpty) {
                match['geosite'] =
                    geoSiteCtrl.text.split(',').map((s) => s.trim()).toList();
              }

              try {
                await api.addRule({
                  'name': nameCtrl.text,
                  'action': action.value.value,
                  'match': match,
                  'enabled': true,
                });
                ref.invalidate(rulesProvider);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                debugPrint('addRule failed: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: SelectableText('Add rule failed: $e',
                          style: const TextStyle(fontFamily: 'monospace')),
                      action: SnackBarAction(
                        label: 'Copy',
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: e.toString())),
                      ),
                    ),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ).whenComplete(disposeAll);
  }
}

class _RuleTile extends StatelessWidget {
  final Rule rule;
  final WidgetRef ref;

  const _RuleTile({super.key, required this.rule, required this.ref});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final actionColor = rule.action == RuleAction.proxy
        ? AtlasTheme.accent
        : rule.action == RuleAction.direct
            ? AtlasTheme.success
            : AtlasTheme.error;

    return AtlasCard(
      child: Row(
        children: [
          // Drag handle
          Icon(Icons.drag_indicator, size: 18, color: c.textMuted),

          // Priority
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.bgElevated,
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
            ),
            child: Center(
              child: Text(
                '${rule.priority}',
                style: TextStyle(
                  fontFamily: AtlasTheme.monoFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Rule info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      rule.name,
                      style: const TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!rule.enabled)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.bgHover,
                          borderRadius:
                              BorderRadius.circular(AtlasTheme.radiusSm),
                        ),
                        child: Text(
                          'OFF',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: c.textMuted,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  rule.match.summary,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: AtlasTheme.monoFamily,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),

          // Action badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: actionColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              border: Border.all(color: actionColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              rule.action.value.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: actionColor,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Delete
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Delete rule',
            onPressed: () async {
              final api = ref.read(daemonApiProvider);
              try {
                await api.deleteRule(rule.id);
                ref.invalidate(rulesProvider);
              } catch (e) {
                debugPrint('deleteRule failed: $e');
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Presets section: one-tap routing profiles (built-in RF set + user-defined),
/// with JSON import/export so users can share their setups.
class _RoutingPresetsSection extends ConsumerWidget {
  const _RoutingPresetsSection({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final presetsAsync = ref.watch(routingPresetsProvider);

    return presetsAsync.when(
      data: (presets) => Card(
        color: c.bgCard,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Пресеты роутинга',
                      style: TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Импорт пресета из файла/текста',
                    icon: const Icon(Icons.file_open, size: 20),
                    onPressed: () => _importPreset(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ...presets.map(
                (preset) => _PresetTile(preset: preset),
              ),
            ],
          ),
        ),
      ),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Future<void> _importPreset(BuildContext context, WidgetRef ref) async {
    final c = ThemeColors.of(context);
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        title: const Text('Импорт пресета'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Вставьте JSON пресета. Формат: {"name": ..., "routingMode": "global|rule|direct", "proxyPackages": [...], "bypassPackages": [...]}'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: '{"name": "Мой пресет", ...}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Импортировать'),
          ),
        ],
      ),
    );
    if (confirmed != true || ctrl.text.trim().isEmpty) return;
    try {
      final preset = RoutingPreset.decode(ctrl.text.trim());
      final custom = RoutingPreset(
        id: 'user-${DateTime.now().millisecondsSinceEpoch}',
        name: preset.name,
        description: preset.description,
        builtIn: false,
        routingMode: preset.routingMode,
        proxyPackages: preset.proxyPackages,
        bypassPackages: preset.bypassPackages,
      );
      final current = await ref.read(routingPresetsProvider.future);
      await saveUserPresets(ref, [...current, custom]);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Пресет «${custom.name}» добавлен')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось разобрать пресет: проверьте JSON')),
        );
      }
    }
  }
}

class _PresetTile extends ConsumerWidget {
  const _PresetTile({required this.preset});

  final RoutingPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        preset.builtIn ? Icons.star_outline : Icons.person_outline,
        size: 22,
        color: c.accent,
      ),
      title: Text(
        preset.name,
        style: TextStyle(fontSize: 14, color: c.textPrimary),
      ),
      subtitle: Text(
        preset.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: c.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Экспорт (скопировать JSON)',
            icon: const Icon(Icons.ios_share, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: preset.encode()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('JSON пресета скопирован')),
                );
              }
            },
          ),
          if (!preset.builtIn)
            IconButton(
              tooltip: 'Удалить пресет',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                final current = await ref.read(routingPresetsProvider.future);
                await saveUserPresets(ref, [
                  for (final p in current) if (p.id != preset.id) p,
                ]);
              },
            ),
          TextButton(
            onPressed: () async {
              try {
                await applyRoutingPreset(ref, preset);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content:
                            Text('Пресет «${preset.name}» применён. Переподключитесь.')),
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Не удалось применить пресет')),
                  );
                }
              }
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
  }
}
