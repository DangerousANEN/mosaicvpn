import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';

/// Fetches the provider manifest with all groups.
final manifestProvider = FutureProvider<ProviderManifest>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getProviderManifest();
});

/// Fetches health for a specific group (keyed by group ID).
final groupHealthProvider =
    FutureProvider.family<Map<String, NodeHealth>, String>(
        (ref, groupId) async {
  final api = ref.watch(daemonApiProvider);
  return api.getGroupHealth(groupId);
});

/// Screen that displays manifest groups with auto-select from pool.
class ManifestGroupsScreen extends ConsumerStatefulWidget {
  const ManifestGroupsScreen({super.key});

  @override
  ConsumerState<ManifestGroupsScreen> createState() =>
      _ManifestGroupsScreenState();
}

class _ManifestGroupsScreenState extends ConsumerState<ManifestGroupsScreen> {
  final _expandedGroups = <String>{};
  String? _connectingGroupId;

  @override
  Widget build(BuildContext context) {
    final manifestAsync = ref.watch(manifestProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AtlasTheme.bgBase,
      body: manifestAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off, size: 48, color: AtlasTheme.textMuted),
                const SizedBox(height: 12),
                Text('No manifest available',
                    style: tt.bodyMedium
                        ?.copyWith(color: AtlasTheme.textSecondary, fontSize: 16)),
                const SizedBox(height: 4),
                Text('$err',
                    style: tt.bodySmall
                        ?.copyWith(color: AtlasTheme.textMuted),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
        data: (manifest) {
          if (manifest.groups.isEmpty) {
            return Center(
              child: Text('No groups in manifest',
                  style: tt.bodyMedium
                      ?.copyWith(color: AtlasTheme.textMuted)),
            );
          }
          final children = <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                manifest.providerName.isNotEmpty
                    ? manifest.providerName
                    : 'VPN Groups',
                style: tt.headlineSmall
                    ?.copyWith(fontFamily: AtlasTheme.serifFamily, fontSize: 22),
              ),
            ),
          ];
          for (final group in manifest.groups) {
            children.add(_GroupCard(
              group: group,
              isExpanded: _expandedGroups.contains(group.id),
              isConnecting: _connectingGroupId == group.id,
              onToggle: () => _toggleGroup(group.id),
              onConnect: () => _connectToGroup(group.id),
            ));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            children: children,
          );
        },
      ),
    );
  }

  void _toggleGroup(String groupId) {
    setState(() {
      if (_expandedGroups.contains(groupId)) {
        _expandedGroups.remove(groupId);
      } else {
        _expandedGroups.add(groupId);
      }
    });
  }

  Future<void> _connectToGroup(String groupId) async {
    setState(() => _connectingGroupId = groupId);
    try {
      final api = ref.read(daemonApiProvider);
      final server = await api.selectNodeFromGroup(groupId);
      await api.connect(server.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected via $groupId → ${server.name}'),
            backgroundColor: AtlasTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: AtlasTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _connectingGroupId = null);
    }
  }
}

class _GroupCard extends ConsumerWidget {
  final ManifestGroup group;
  final bool isExpanded;
  final bool isConnecting;
  final VoidCallback onToggle;
  final VoidCallback onConnect;

  const _GroupCard({
    required this.group,
    required this.isExpanded,
    required this.isConnecting,
    required this.onToggle,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    // Always watch, but only display when expanded.
    final healthAsync = ref.watch(groupHealthProvider(group.id));

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AtlasTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AtlasTheme.border),
        ),
        child: Column(
          children: [
            // Header row
            InkWell(
              onTap: onToggle,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    _GroupIcon(icon: group.icon, category: group.category),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(group.title,
                              style: tt.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              )),
                          if (group.badge.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(group.badge,
                                style: tt.bodySmall?.copyWith(
                                    color: AtlasTheme.accent, fontSize: 11)),
                          ],
                        ],
                      ),
                    ),
                    if (!isExpanded)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(group.strategyLabel,
                            style: tt.bodySmall?.copyWith(
                                color: AtlasTheme.textMuted, fontSize: 11)),
                      ),
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: AtlasTheme.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            // Expanded health details
            if (isExpanded)
              Container(
                decoration: const BoxDecoration(
                  border:
                      Border(top: BorderSide(color: AtlasTheme.borderLight)),
                ),
                child: () {
                  final av = healthAsync;
                  return av.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    error: (err, stack) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('No health data',
                          style: tt.bodySmall
                              ?.copyWith(color: AtlasTheme.textMuted)),
                    ),
                    data: (healthMap) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        children: _buildHealthChildren(tt, healthMap),
                      ),
                    ),
                  );
                }(),
              ),
            // Connect button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isConnecting ? null : onConnect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AtlasTheme.accent,
                    foregroundColor: AtlasTheme.textOnInk,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  icon: isConnecting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AtlasTheme.textOnInk))
                      : const Icon(Icons.bolt, size: 16),
                  label: Text(isConnecting ? 'Connecting...' : 'Connect',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHealthChildren(
      TextTheme tt, Map<String, NodeHealth> healthMap) {
    final children = <Widget>[
      Row(
        children: [
          Icon(Icons.memory, size: 14, color: AtlasTheme.textMuted),
          const SizedBox(width: 6),
          Text(group.strategyLabel,
              style: tt.bodySmall?.copyWith(fontSize: 12)),
          const Spacer(),
          Text('${group.nodes.length} nodes',
              style: tt.bodySmall?.copyWith(fontSize: 11)),
        ],
      ),
      const SizedBox(height: 8),
    ];
    if (healthMap.isEmpty) {
      children.add(Text('No nodes resolved yet',
          style: tt.bodySmall?.copyWith(color: AtlasTheme.textMuted)));
    } else {
      for (final entry in healthMap.entries) {
        children.add(_NodeHealthRow(
          nodeId: entry.key,
          health: entry.value,
        ));
      }
    }
    return children;
  }
}

class _NodeHealthRow extends StatelessWidget {
  final String nodeId;
  final NodeHealth health;

  const _NodeHealthRow({required this.nodeId, required this.health});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: health.alive
                  ? AtlasTheme.success
                  : health.isUnknown
                      ? AtlasTheme.textMuted
                      : AtlasTheme.error,
            ),
          ),
          const SizedBox(width: 8),
          Text(nodeId, style: tt.bodySmall?.copyWith(fontSize: 12)),
          const Spacer(),
          if (health.alive)
            Text('${health.latencyMs}ms',
                style: tt.bodySmall?.copyWith(
                    color: AtlasTheme.success, fontSize: 12))
          else if (health.error != null)
            Text(health.error!,
                style: tt.bodySmall
                    ?.copyWith(color: AtlasTheme.error, fontSize: 11)),
        ],
      ),
    );
  }
}

class _GroupIcon extends StatelessWidget {
  final String icon;
  final String category;

  const _GroupIcon({required this.icon, this.category = ''});

  @override
  Widget build(BuildContext context) {
    IconData ic;
    Color color;

    switch (icon) {
      case 'lightning':
        ic = Icons.bolt;
        color = AtlasTheme.warning;
      case 'shield':
        ic = Icons.shield;
        color = AtlasTheme.success;
      case 'flag_de':
      case 'flag_nl':
      case 'flag_us':
      case 'flag_ru':
      case 'flag_gb':
      case 'flag_fr':
      case 'flag_ca':
        ic = Icons.flag;
        color = AtlasTheme.accent;
      default:
        switch (category) {
          case 'whitelist':
            ic = Icons.shield;
            color = AtlasTheme.success;
          case 'smart':
            ic = Icons.bolt;
            color = AtlasTheme.warning;
          default:
            ic = Icons.dns;
            color = AtlasTheme.textSecondary;
        }
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(ic, size: 18, color: color),
    );
  }
}
