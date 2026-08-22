import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';

/// Provider manifest backing the groups screen.
final groupsManifestProvider = FutureProvider<ProviderManifest>((ref) async {
  final api = ref.watch(daemonApiProvider);
  return api.getProviderManifest();
});

/// Per-group node health, fetched lazily when a card is expanded.
final groupNodeHealthProvider =
    FutureProvider.family<Map<String, NodeHealth>, String>((ref, groupId) async {
  final api = ref.watch(daemonApiProvider);
  return api.getGroupHealth(groupId);
});

/// Card sizing, per GROUP_SYSTEM_SPEC section 8.2. A card stretched across a
/// desktop window is unreadable, so it caps at 520px; past 900px there is room
/// for two columns rather than dead margin.
const _maxCardWidth = 520.0;
const _twoColumnBreakpoint = 900.0;
const _columnGap = 16.0;

/// GroupsScreen replaces ManifestGroupsScreen and MixedSubscriptionsScreen.
///
/// Both screens listed the same manifest groups with different affordances,
/// so a user connecting from one saw different state than the other. This
/// merges them: groups auto-select a node from their pool, individual servers
/// connect directly, and both live in one list.
class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  /// Tracks the in-flight connect target, namespaced so a group and a server
  /// sharing an id cannot both show a spinner.
  String? _connectingId;
  final _expandedGroups = <String>{};

  @override
  Widget build(BuildContext context) {
    final manifestAsync = ref.watch(groupsManifestProvider);
    final serversAsync = ref.watch(serversProvider);
    final status = ref.watch(vpnStatusProvider).valueOrNull;
    final activeId = status?.server?.id;

    return Scaffold(
      backgroundColor: AtlasTheme.bgBase,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(groupsManifestProvider);
          ref.invalidate(serversProvider);
          await ref.read(groupsManifestProvider.future);
        },
        child: manifestAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => _ErrorState(error: err),
          data: (manifest) => _buildBody(
            manifest: manifest,
            servers: serversAsync.valueOrNull ?? const [],
            activeId: activeId,
          ),
        ),
      ),
    );
  }

  Widget _buildBody({
    required ProviderManifest manifest,
    required List<Server> servers,
    required String? activeId,
  }) {
    final tt = Theme.of(context).textTheme;

    if (manifest.groups.isEmpty && servers.isEmpty) {
      return const _EmptyState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= _twoColumnBreakpoint;
        final sections = <Widget>[];

        if (manifest.providerName.isNotEmpty) {
          sections.add(Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              manifest.providerName,
              style: tt.headlineSmall?.copyWith(
                fontFamily: AtlasTheme.serifFamily,
                fontSize: 22,
              ),
            ),
          ));
        }

        if (manifest.groups.isNotEmpty) {
          sections.add(const _SectionHeader('Группы · автоподбор'));
          final cards = [
            for (final group in manifest.groups)
              _GroupCard(
                group: group,
                isExpanded: _expandedGroups.contains(group.id),
                isConnecting: _connectingId == 'group:${group.id}',
                isActive: _isGroupActive(group.id, activeId, servers),
                onToggle: () => _toggleGroup(group.id),
                onConnect: () => _connectGroup(group.id),
              ),
          ];
          sections.addAll(_layoutCards(cards, twoColumns));
        }

        if (servers.isNotEmpty) {
          sections.add(const _SectionHeader('Отдельные серверы'));
          final cards = [
            for (final server in servers)
              _ServerCard(
                server: server,
                isActive: activeId == server.id,
                isConnecting: _connectingId == 'server:${server.id}',
                onConnect: () => _connectServer(server.id),
              ),
          ];
          sections.addAll(_layoutCards(cards, twoColumns));
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: twoColumns
                      ? _maxCardWidth * 2 + _columnGap
                      : _maxCardWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: sections,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Arranges cards in one or two columns, capping each at _maxCardWidth.
  List<Widget> _layoutCards(List<Widget> cards, bool twoColumns) {
    if (!twoColumns) {
      return [
        for (final card in cards)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxCardWidth),
            child: card,
          ),
      ];
    }

    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += 2) {
      final left = cards[i];
      final right = i + 1 < cards.length ? cards[i + 1] : null;
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxCardWidth),
              child: left,
            ),
          ),
          const SizedBox(width: _columnGap),
          Expanded(
            child: right == null
                ? const SizedBox.shrink()
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxCardWidth),
                    child: right,
                  ),
          ),
        ],
      ));
    }
    return rows;
  }

  bool _isGroupActive(
      String groupId, String? activeId, List<Server> servers) {
    if (activeId == null) return false;
    for (final s in servers) {
      if (s.id == activeId && s.groupId == groupId) return true;
    }
    return false;
  }

  void _toggleGroup(String groupId) {
    setState(() {
      if (!_expandedGroups.remove(groupId)) {
        _expandedGroups.add(groupId);
      }
    });
  }

  Future<void> _connectGroup(String groupId) async {
    setState(() => _connectingId = 'group:$groupId');
    try {
      final api = ref.read(daemonApiProvider);
      late final dynamic server;
      try {
        server = await api.selectNodeFromGroup(groupId);
      } catch (e) {
        _showMessage('В группе нет доступных серверов: $e', AtlasTheme.error);
        return;
      }
      await api.connect(server.id);
      _showMessage('Подключено через $groupId → ${server.name}', AtlasTheme.success);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout) {
        _showMessage('Демон не запущен или не отвечает', AtlasTheme.error);
      } else {
        _showMessage('Не удалось подключиться: ${e.message}', AtlasTheme.error);
      }
    } catch (e) {
      _showMessage('Не удалось подключиться: $e', AtlasTheme.error);
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _connectServer(String serverId) async {
    setState(() => _connectingId = 'server:$serverId');
    try {
      await ref.read(daemonApiProvider).connect(serverId);
    } catch (e) {
      _showMessage('Не удалось подключиться: $e', AtlasTheme.error);
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  void _showMessage(String msg, Color background) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: background),
    );
  }
}

// ─── Shared pieces ────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rss_feed, size: 48, color: AtlasTheme.textMuted),
            const SizedBox(height: 12),
            Text('Нет доступных групп и серверов',
                style: tt.bodyMedium?.copyWith(color: AtlasTheme.textSecondary)),
            const SizedBox(height: 4),
            Text('Добавьте подписку, чтобы импортировать конфигурации.',
                style: tt.bodySmall?.copyWith(color: AtlasTheme.textMuted),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final Object error;
  const _ErrorState({required this.error});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: AtlasTheme.textMuted),
            const SizedBox(height: 12),
            Text('Не удалось загрузить группы',
                style: tt.bodyMedium?.copyWith(color: AtlasTheme.textSecondary)),
            const SizedBox(height: 4),
            // The raw error is kept: a generic message gives the user nothing
            // to act on and nothing to report.
            Text('$error',
                style: tt.bodySmall?.copyWith(color: AtlasTheme.textMuted),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// ─── Group card ───────────────────────────────────────────────────────────

class _GroupCard extends ConsumerWidget {
  final ManifestGroup group;
  final bool isExpanded;
  final bool isConnecting;
  final bool isActive;
  final VoidCallback onToggle;
  final VoidCallback onConnect;

  const _GroupCard({
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
                    Icon(Icons.bolt,
                        size: 18,
                        color:
                            isActive ? AtlasTheme.success : AtlasTheme.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        group.title,
                        style:
                            tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        // Names wrap rather than truncating to a few glyphs.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (isActive)
                      const _Badge(label: 'АКТИВНА', color: AtlasTheme.success)
                    else
                      Flexible(
                        child: Text(
                          group.strategyLabel,
                          style: tt.bodySmall?.copyWith(
                              color: AtlasTheme.textMuted, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    Icon(isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: AtlasTheme.textMuted),
                  ],
                ),
              ),
            ),
            if (isExpanded) _HealthPanel(groupId: group.id),
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
                        ? 'Подключено'
                        : (isConnecting ? 'Подключение…' : 'Автоподключение'),
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
}

/// Node health for one group, loaded when the card is expanded.
class _HealthPanel extends ConsumerWidget {
  final String groupId;
  const _HealthPanel({required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final healthAsync = ref.watch(groupNodeHealthProvider(groupId));

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AtlasTheme.borderLight)),
      ),
      child: healthAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
        error: (err, _) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text('Нет данных о состоянии узлов',
              style: tt.bodySmall?.copyWith(color: AtlasTheme.textMuted)),
        ),
        data: (healthMap) {
          if (healthMap.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Узлы ещё не определены',
                  style: tt.bodySmall?.copyWith(color: AtlasTheme.textMuted)),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              children: [
                for (final entry in healthMap.entries)
                  _NodeHealthRow(name: entry.key, health: entry.value),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NodeHealthRow extends StatelessWidget {
  final String name;
  final NodeHealth health;

  const _NodeHealthRow({required this.name, required this.health});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final dotColor = health.alive
        ? AtlasTheme.success
        : health.isUnknown
            ? AtlasTheme.textMuted
            : AtlasTheme.error;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: tt.bodySmall?.copyWith(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (health.alive)
            Text('${health.latencyMs} мс',
                style: tt.bodySmall
                    ?.copyWith(color: AtlasTheme.success, fontSize: 12))
          else if (health.error != null)
            // Constrained so a long error cannot squeeze the node name away.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                health.error!,
                style: tt.bodySmall
                    ?.copyWith(color: AtlasTheme.error, fontSize: 11),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Server card ──────────────────────────────────────────────────────────

class _ServerCard extends StatelessWidget {
  final Server server;
  final bool isActive;
  final bool isConnecting;
  final VoidCallback onConnect;

  const _ServerCard({
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
                Icon(Icons.dns,
                    size: 16,
                    color: isActive
                        ? AtlasTheme.success
                        : AtlasTheme.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        style: tt.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (server.address.isNotEmpty)
                        Text(
                          '${server.address}:${server.port}',
                          style: tt.bodySmall?.copyWith(
                              color: AtlasTheme.textMuted, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isConnecting)
                  const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else if (isActive)
                  const _Badge(label: 'АКТИВЕН', color: AtlasTheme.success)
                else
                  Icon(Icons.chevron_right,
                      size: 18, color: AtlasTheme.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style:
              tt.labelSmall?.copyWith(color: AtlasTheme.textOnInk, fontSize: 9)),
    );
  }
}
