import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';

/// Fetches the provider manifest for mixed display.
final mixedManifestProvider = FutureProvider<ProviderManifest>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getProviderManifest();
});

/// Fetches health for a specific group.
final mixedGroupHealthProvider =
    FutureProvider.family<Map<String, NodeHealth>, String>(
        (ref, groupId) async {
  final api = ref.watch(daemonApiProvider);
  return api.getGroupHealth(groupId);
});

/// Mixed subscriptions screen: shows manifest groups AND individual servers
/// in a single unified list. Groups show auto-select from pool, individual
/// servers connect directly.
class MixedSubscriptionsScreen extends ConsumerStatefulWidget {
  const MixedSubscriptionsScreen({super.key});

  @override
  ConsumerState<MixedSubscriptionsScreen> createState() =>
      _MixedSubscriptionsScreenState();
}

class _MixedSubscriptionsScreenState
    extends ConsumerState<MixedSubscriptionsScreen> {
  String? _connectingId;
  final _expandedGroups = <String>{};

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final manifestAsync = ref.watch(mixedManifestProvider);
    final serversAsync = ref.watch(serversProvider);
    final status = ref.watch(vpnStatusProvider).valueOrNull;
    final activeId = status?.server?.id;

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
                Text('Unable to load subscriptions',
                    style: tt.bodyMedium
                        ?.copyWith(color: AtlasTheme.textSecondary)),
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
          final servers = serversAsync.valueOrNull ?? [];

          // Build unified list of items
          final items = <_ListItem>[];

          // Section: Manifest Groups (pools with auto-select)
          if (manifest.groups.isNotEmpty) {
            items.add(_SectionHeader('Groups (Auto-select)'));
            for (final group in manifest.groups) {
              items.add(_GroupItem(group: group));
            }
          }

          // Section: Individual Servers (direct connect)
          if (servers.isNotEmpty) {
            items.add(_SectionHeader('Individual Servers'));
            for (final server in servers) {
              items.add(_ServerItem(server: server));
            }
          }

          if (items.isEmpty) {
            return Center(
              child: Text('No subscriptions available',
                  style: tt.bodyMedium
                      ?.copyWith(color: AtlasTheme.textMuted)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              if (item is _SectionHeader) {
                return _SectionHeaderWidget(label: item.label);
              }
              if (item is _GroupItem) {
                return _MixedGroupCard(
                  group: item.group,
                  isExpanded: _expandedGroups.contains(item.group.id),
                  isConnecting: _connectingId == 'group:${item.group.id}',
                  isActive: activeId != null &&
                      _isGroupActive(ref, item.group.id, activeId),
                  onToggle: () => setState(() {
                    if (_expandedGroups.contains(item.group.id)) {
                      _expandedGroups.remove(item.group.id);
                    } else {
                      _expandedGroups.add(item.group.id);
                    }
                  }),
                  onConnect: () => _connectGroup(item.group.id),
                );
              }
              if (item is _ServerItem) {
                return _MixedServerCard(
                  server: item.server,
                  isActive: activeId == item.server.id,
                  isConnecting: _connectingId == 'server:${item.server.id}',
                  onConnect: () => _connectServer(item.server.id),
                );
              }
              return const SizedBox.shrink();
            },
          );
        },
      ),
    );
  }

  bool _isGroupActive(WidgetRef ref, String groupId, String activeId) {
    // Check if active server belongs to this group
    final servers = ref.read(serversProvider).valueOrNull ?? [];
    for (final s in servers) {
      if (s.id == activeId && s.groupId == groupId) return true;
    }
    return false;
  }

  Future<void> _connectGroup(String groupId) async {
    final id = 'group:$groupId';
    setState(() => _connectingId = id);
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
      _showError('Connection failed: $e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _connectServer(String serverId) async {
    final id = 'server:$serverId';
    setState(() => _connectingId = id);
    try {
      final api = ref.read(daemonApiProvider);
      await api.connect(serverId);
    } catch (e) {
      _showError('Connection failed: $e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AtlasTheme.error),
      );
    }
  }
}

// ─── Item type hierarchy for the unified list ──────────────────────────

sealed class _ListItem {}

class _SectionHeader extends _ListItem {
  final String label;
  _SectionHeader(this.label);
}

class _GroupItem extends _ListItem {
  final ManifestGroup group;
  _GroupItem({required this.group});
}

class _ServerItem extends _ListItem {
  final Server server;
  _ServerItem({required this.server});
}

// ─── Widgets ─────────────────────────────────────────────────────────────

class _SectionHeaderWidget extends StatelessWidget {
  final String label;
  const _SectionHeaderWidget({required this.label});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: tt.labelSmall?.copyWith(
          color: AtlasTheme.textMuted,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MixedGroupCard extends ConsumerWidget {
  final ManifestGroup group;
  final bool isExpanded;
  final bool isConnecting;
  final bool isActive;
  final VoidCallback onToggle;
  final VoidCallback onConnect;

  const _MixedGroupCard({
    required this.group,
    required this.isExpanded,
    required this.isConnecting,
    required this.isActive,
    required this.onToggle,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final healthAsync = ref.watch(mixedGroupHealthProvider(group.id));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? AtlasTheme.successDim : AtlasTheme.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? AtlasTheme.success : AtlasTheme.border,
          ),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: onToggle,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.bolt, size: 18,
                        color: isActive ? AtlasTheme.success : AtlasTheme.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(group.title,
                          style: tt.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    if (isActive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AtlasTheme.success,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('ACTIVE',
                            style: tt.labelSmall?.copyWith(
                                color: AtlasTheme.textOnInk, fontSize: 9)),
                      )
                    else
                      Text(group.strategyLabel,
                          style: tt.bodySmall?.copyWith(
                              color: AtlasTheme.textMuted, fontSize: 11)),
                    Icon(isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: AtlasTheme.textMuted),
                  ],
                ),
              ),
            ),
            if (isExpanded)
              Container(
                decoration: const BoxDecoration(
                  border: Border(
                      top: BorderSide(color: AtlasTheme.borderLight)),
                ),
                child: () {
                  final av = healthAsync;
                  return av.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    ),
                    error: (err, stack) => Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('No health data',
                          style: tt.bodySmall
                              ?.copyWith(color: AtlasTheme.textMuted)),
                    ),
                    data: (healthMap) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Column(
                        children: _buildHealthList(tt, healthMap),
                      ),
                    ),
                  );
                }(),
              ),
            // Connect button
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isConnecting || isActive ? null : onConnect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isActive ? AtlasTheme.success : AtlasTheme.accent,
                    foregroundColor: AtlasTheme.textOnInk,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  icon: isConnecting
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AtlasTheme.textOnInk))
                      : Icon(isActive ? Icons.check : Icons.bolt, size: 14),
                  label: Text(
                    isActive
                        ? 'Connected'
                        : (isConnecting ? 'Connecting...' : 'Auto Connect'),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHealthList(
      TextTheme tt, Map<String, NodeHealth> healthMap) {
    final children = <Widget>[];
    if (healthMap.isEmpty) {
      children.add(Text('No nodes resolved yet',
          style: tt.bodySmall?.copyWith(color: AtlasTheme.textMuted)));
    } else {
      for (final entry in healthMap.entries) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: entry.value.alive
                      ? AtlasTheme.success
                      : entry.value.isUnknown
                          ? AtlasTheme.textMuted
                          : AtlasTheme.error,
                ),
              ),
              const SizedBox(width: 8),
              Text(entry.key,
                  style: tt.bodySmall?.copyWith(fontSize: 12)),
              const Spacer(),
              if (entry.value.alive)
                Text('${entry.value.latencyMs}ms',
                    style: tt.bodySmall?.copyWith(
                        color: AtlasTheme.success, fontSize: 12))
              else if (entry.value.error != null)
                Text(entry.value.error!,
                    style: tt.bodySmall
                        ?.copyWith(color: AtlasTheme.error, fontSize: 11)),
            ],
          ),
        ));
      }
    }
    return children;
  }
}

class _MixedServerCard extends StatelessWidget {
  final Server server;
  final bool isActive;
  final bool isConnecting;
  final VoidCallback onConnect;

  const _MixedServerCard({
    required this.server,
    required this.isActive,
    required this.isConnecting,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? AtlasTheme.successDim : AtlasTheme.bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? AtlasTheme.success : AtlasTheme.border,
          ),
        ),
        child: InkWell(
          onTap: isConnecting ? null : onConnect,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.dns, size: 16,
                    color: isActive ? AtlasTheme.success : AtlasTheme.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(server.name,
                          style: tt.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500)),
                      if (server.address.isNotEmpty)
                        Text('${server.address}:${server.port}',
                            style: tt.bodySmall
                                ?.copyWith(color: AtlasTheme.textMuted, fontSize: 11)),
                    ],
                  ),
                ),
                if (isConnecting)
                  const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AtlasTheme.success,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('ACTIVE',
                        style: tt.labelSmall?.copyWith(
                            color: AtlasTheme.textOnInk, fontSize: 9)),
                  )
                else
                  Icon(Icons.chevron_right, size: 18, color: AtlasTheme.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
