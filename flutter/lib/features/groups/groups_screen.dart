import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';
import '../subscriptions/subscriptions_screen.dart';

/// Backward-compatible alias used by auxiliary route screens and tests. It is
/// the Android-aware provider and never makes a daemon-only request on mobile.
final groupsManifestProvider = mosaicManifestProvider;

/// Retained only for older test overrides. The user-facing routes inventory no
/// longer loads or renders private per-node health information.
final groupNodeHealthProvider =
    FutureProvider.family<Map<String, NodeHealth>, String>(
        (ref, groupId) async {
  return const <String, NodeHealth>{};
});

enum _RouteSort { type, name, ping, traffic }

class _RouteRow {
  const _RouteRow({
    required this.id,
    required this.type,
    required this.name,
    required this.ping,
    required this.traffic,
    required this.isGroup,
    required this.icon,
  });

  final String id;
  final String type;
  final String name;
  final int? ping;
  final String traffic;
  final bool isGroup;
  final IconData icon;
}

/// A single route inventory. A user first chooses a subscription/source and
/// then sees only the user-facing routes belonging to it. MosaicVPN physical
/// pool nodes never cross this UI boundary: its source exposes provider smart
/// groups only, while other services can expose their own imported nodes.
class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  String? _selectedSubscriptionId;
  String? _connectingId;
  _RouteSort _sort = _RouteSort.name;
  bool _ascending = true;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final manifestAsync = ref.watch(mosaicManifestProvider);
    final subscriptions =
        ref.watch(subscriptionsProvider).valueOrNull ?? const <Subscription>[];
    final servers = ref.watch(serversProvider).valueOrNull ?? const <Server>[];
    final status = ref.watch(vpnStatusProvider).valueOrNull;

    if (manifestAsync.isLoading && subscriptions.isEmpty) {
      return Scaffold(
        backgroundColor: colors.bgBase,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final manifest = manifestAsync.valueOrNull;
    final sources = _sourcesFor(manifest, subscriptions);
    final selectedSource = sources.firstWhere(
      (source) => source.id == _selectedSubscriptionId,
      orElse: () => sources.isNotEmpty ? sources.first : Subscription(),
    );
    final rows = _rowsFor(
      manifest: manifest,
      source: selectedSource,
      servers: servers,
    )..sort(_compareRows);

    if (sources.isNotEmpty && selectedSource.id != _selectedSubscriptionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _selectedSubscriptionId = selectedSource.id);
        }
      });
    }

    return Scaffold(
      backgroundColor: colors.bgBase,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: EdgeInsets.fromLTRB(
              constraints.maxWidth >= 760 ? 32 : 16,
              24,
              constraints.maxWidth >= 760 ? 32 : 16,
              32,
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(onAddSource: _showAddSource, onRefresh: _refresh),
                      const SizedBox(height: 18),
                      if (sources.isNotEmpty) ...[
                        Text(
                          'Подписки',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: colors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 10),
                        _SourceTabs(
                          sources: sources,
                          selectedId: selectedSource.id,
                          onSelected: _selectSource,
                        ),
                        const SizedBox(height: 18),
                      ],
                      _SourceSummary(
                        source: selectedSource,
                        isMosaic: selectedSource.id == 'mosaic-direct',
                      ),
                      const SizedBox(height: 14),
                      if (manifestAsync.hasError &&
                          selectedSource.id == 'mosaic-direct')
                        _InlineNotice(
                          icon: Icons.sync_problem_outlined,
                          text:
                              'Маршруты MosaicVPN временно недоступны. Потяните экран вниз, чтобы повторить попытку.',
                        ),
                      if (rows.isEmpty)
                        _EmptyRoutes(
                          hasSource: selectedSource.id.isNotEmpty,
                          onAddSource: _showAddSource,
                        )
                      else
                        _RouteTable(
                          rows: rows,
                          activeId: status?.isConnected == true
                              ? status?.server?.id
                              : null,
                          connectingId: _connectingId,
                          sort: _sort,
                          ascending: _ascending,
                          onSort: _applySort,
                          onSortMenu: _showSortMenu,
                          onConnect: _connect,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Subscription> _sourcesFor(
    ProviderManifest? manifest,
    List<Subscription> subscriptions,
  ) {
    final hasMosaic =
        subscriptions.any((source) => source.id == 'mosaic-direct');
    return <Subscription>[
      if (!hasMosaic && (manifest?.groups.isNotEmpty ?? false))
        Subscription(id: 'mosaic-direct', name: 'MosaicVPN'),
      ...subscriptions,
    ];
  }

  List<_RouteRow> _rowsFor({
    required ProviderManifest? manifest,
    required Subscription source,
    required List<Server> servers,
  }) {
    if (source.id == 'mosaic-direct') {
      return (manifest?.groups ?? const <ManifestGroup>[])
          .where((group) =>
              group.category == 'smart' || group.category == 'whitelist')
          .map(
            (group) => _RouteRow(
              id: group.id,
              type: 'Группа',
              name: _groupTitle(group),
              ping: null,
              traffic: 'Авто',
              isGroup: true,
              icon: _groupIcon(group.icon),
            ),
          )
          .toList();
    }

    // The daemon API itself filters mosaic-direct physical nodes. This UI
    // applies the same rule as defence in depth for any future provider change.
    return servers
        .where((server) =>
            server.subscriptionID == source.id &&
            server.subscriptionID != 'mosaic-direct')
        .map(
          (server) => _RouteRow(
            id: server.id,
            type: server.protocol.displayName,
            name: server.name.isEmpty ? 'Безымянный сервер' : server.name,
            ping: server.hasLatency ? server.lastTestMS : null,
            traffic: '—',
            isGroup: false,
            icon: Icons.dns_outlined,
          ),
        )
        .toList();
  }

  int _compareRows(_RouteRow left, _RouteRow right) {
    int result;
    switch (_sort) {
      case _RouteSort.type:
        result = left.type.toLowerCase().compareTo(right.type.toLowerCase());
      case _RouteSort.name:
        result = left.name.toLowerCase().compareTo(right.name.toLowerCase());
      case _RouteSort.ping:
        result = (left.ping ?? 1 << 30).compareTo(right.ping ?? 1 << 30);
      case _RouteSort.traffic:
        result = left.traffic.compareTo(right.traffic);
    }
    if (result == 0) result = left.name.compareTo(right.name);
    return _ascending ? result : -result;
  }

  Future<void> _refresh() async {
    ref.invalidate(mosaicManifestProvider);
    ref.invalidate(subscriptionsProvider);
    ref.invalidate(serversProvider);
    ref.invalidate(vpnStatusProvider);
    try {
      await ref.read(mosaicManifestProvider.future);
    } catch (_) {
      // The screen renders a safe retry state; raw transport errors stay out of UI.
    }
  }

  void _selectSource(String sourceId) {
    if (sourceId == _selectedSubscriptionId) return;
    setState(() => _selectedSubscriptionId = sourceId);
  }

  void _applySort(_RouteSort sort) {
    setState(() {
      if (_sort == sort) {
        _ascending = !_ascending;
      } else {
        _sort = sort;
        _ascending = sort != _RouteSort.ping;
      }
    });
  }

  Future<void> _showSortMenu(Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_RouteSort>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
            value: _RouteSort.type, child: Text('Сортировать по типу')),
        PopupMenuItem(
            value: _RouteSort.name, child: Text('Сортировать по названию')),
        PopupMenuItem(
            value: _RouteSort.ping, child: Text('Сортировать по пингу')),
        PopupMenuItem(
            value: _RouteSort.traffic, child: Text('Сортировать по трафику')),
      ],
    );
    if (selected != null && mounted) _applySort(selected);
  }

  Future<void> _connect(_RouteRow row) async {
    setState(() => _connectingId = row.id);
    try {
      final api = ref.read(daemonApiProvider);
      if (row.isGroup) {
        await api.connectGroup(row.id);
      } else {
        await api.connect(row.id);
      }
      ref.invalidate(vpnStatusProvider);
      if (mounted) {
        _showMessage(
            'Подключение установлено.', ThemeColors.of(context).success);
      }
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Не удалось подключиться. Обновите маршрут и повторите попытку.',
          ThemeColors.of(context).danger,
        );
      }
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  void _showAddSource() {
    showDialog<void>(
      context: context,
      builder: (_) => const AddSubscriptionFeedDialog(),
    );
  }

  void _showMessage(String message, Color background) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: background),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onAddSource, required this.onRefresh});

  final VoidCallback onAddSource;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Профили и маршруты',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: colors.textPrimary,
                      fontFamily: AtlasTheme.serifFamily,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Выберите подписку, затем маршрут. MosaicVPN раскрывает только безопасные группы — внутренний пул остаётся приватным.',
                style: TextStyle(color: colors.textSecondary, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: () => onRefresh(),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Обновить'),
        ),
        FilledButton.icon(
          onPressed: onAddSource,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Добавить источник'),
        ),
      ],
    );
  }
}

class _SourceTabs extends StatelessWidget {
  const _SourceTabs({
    required this.sources,
    required this.selectedId,
    required this.onSelected,
  });

  final List<Subscription> sources;
  final String selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: sources
            .map(
              (source) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  avatar: Icon(
                    source.id == 'mosaic-direct'
                        ? Icons.verified_user_outlined
                        : Icons.rss_feed_outlined,
                    size: 17,
                    color: source.id == selectedId
                        ? AtlasTheme.accent
                        : colors.textMuted,
                  ),
                  label: Text(source.name.isEmpty
                      ? 'Безымянный источник'
                      : source.name),
                  selected: source.id == selectedId,
                  onSelected: (_) => onSelected(source.id),
                  selectedColor: AtlasTheme.accent.withValues(alpha: .16),
                  labelStyle: TextStyle(
                    color: source.id == selectedId
                        ? AtlasTheme.accent
                        : colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SourceSummary extends StatelessWidget {
  const _SourceSummary({required this.source, required this.isMosaic});

  final Subscription source;
  final bool isMosaic;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final title = source.name.isEmpty ? 'Источник маршрутов' : source.name;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.bgCard,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AtlasTheme.accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isMosaic ? Icons.shield_outlined : Icons.layers_outlined,
              color: AtlasTheme.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 3),
                Text(
                  isMosaic
                      ? 'Выберите группу. Подходящий физический узел выбирается внутри защищённого пула.'
                      : 'Импортированные маршруты этого источника доступны только вам.',
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.warning.withValues(alpha: .30)),
      ),
      child: Row(children: [
        Icon(icon, color: colors.warning),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text, style: TextStyle(color: colors.textPrimary))),
      ]),
    );
  }
}

class _EmptyRoutes extends StatelessWidget {
  const _EmptyRoutes({required this.hasSource, required this.onAddSource});

  final bool hasSource;
  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
      decoration: BoxDecoration(
        color: colors.bgCard,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(children: [
        Icon(Icons.route_outlined, color: colors.textMuted, size: 44),
        const SizedBox(height: 12),
        Text(
          hasSource
              ? 'В этой подписке пока нет маршрутов'
              : 'Нет подключённых источников',
          textAlign: TextAlign.center,
          style:
              TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          hasSource
              ? 'Обновите источник или выберите другую подписку.'
              : 'Добавьте совместимый профиль, чтобы увидеть его маршруты.',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textSecondary),
        ),
        const SizedBox(height: 16),
        if (!hasSource)
          FilledButton.icon(
            onPressed: onAddSource,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Добавить источник'),
          ),
      ]),
    );
  }
}

class _RouteTable extends StatelessWidget {
  const _RouteTable({
    required this.rows,
    required this.activeId,
    required this.connectingId,
    required this.sort,
    required this.ascending,
    required this.onSort,
    required this.onSortMenu,
    required this.onConnect,
  });

  final List<_RouteRow> rows;
  final String? activeId;
  final String? connectingId;
  final _RouteSort sort;
  final bool ascending;
  final ValueChanged<_RouteSort> onSort;
  final Future<void> Function(Offset) onSortMenu;
  final ValueChanged<_RouteRow> onConnect;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.bgCard,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(colors.bgElevated),
            dataRowMinHeight: 62,
            dataRowMaxHeight: 68,
            sortColumnIndex: _columnFor(sort),
            sortAscending: ascending,
            columns: [
              _column(context, 'Тип', _RouteSort.type),
              _column(context, 'Название', _RouteSort.name),
              _column(context, 'Пинг', _RouteSort.ping, numeric: true),
              _column(context, 'Трафик', _RouteSort.traffic, numeric: true),
            ],
            rows: rows.map((row) {
              final isConnected =
                  activeId == row.id || activeId == 'group:${row.id}';
              final isConnecting = connectingId == row.id;
              return DataRow(
                selected: isConnected,
                onSelectChanged: isConnecting ? null : (_) => onConnect(row),
                cells: [
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(row.icon,
                        size: 18,
                        color:
                            row.isGroup ? AtlasTheme.accent : colors.textMuted),
                    const SizedBox(width: 8),
                    Text(row.type,
                        style: TextStyle(color: colors.textSecondary)),
                  ])),
                  DataCell(SizedBox(
                    width: 310,
                    child: Row(children: [
                      Expanded(
                        child: Text(row.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            )),
                      ),
                      if (isConnecting)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else if (isConnected)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(Icons.check_circle_rounded,
                              color: AtlasTheme.success, size: 18),
                        ),
                    ]),
                  )),
                  DataCell(Text(row.ping == null ? 'Авто' : '${row.ping} мс',
                      style: TextStyle(color: colors.textPrimary))),
                  DataCell(Text(row.traffic,
                      style: TextStyle(color: colors.textPrimary))),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  DataColumn _column(BuildContext context, String label, _RouteSort field,
      {bool numeric = false}) {
    final colors = ThemeColors.of(context);
    return DataColumn(
      numeric: numeric,
      onSort: (_, __) => onSort(field),
      label: Listener(
        onPointerDown: (event) {
          if (event.buttons == kSecondaryMouseButton) {
            onSortMenu(event.position);
          }
        },
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  color: colors.textPrimary, fontWeight: FontWeight.w700)),
          const SizedBox(width: 3),
          if (sort == field)
            Icon(
                ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 14,
                color: AtlasTheme.accent),
        ]),
      ),
    );
  }

  int _columnFor(_RouteSort value) => switch (value) {
        _RouteSort.type => 0,
        _RouteSort.name => 1,
        _RouteSort.ping => 2,
        _RouteSort.traffic => 3,
      };
}

String _groupTitle(ManifestGroup group) {
  return switch (group.id) {
    'rg-all' => 'Минимальный пинг',
    'auto-stable' => 'Стабильное соединение',
    'auto-speed' => 'Максимальная скорость',
    'auto-whitelist' || 'auto-allowlist' => 'Доступ через allowlist',
    _ => group.title,
  };
}

IconData _groupIcon(String icon) {
  return switch (icon) {
    'lightning' => Icons.bolt_rounded,
    'speed' => Icons.speed_rounded,
    'shield' => Icons.shield_outlined,
    'flag_de' || 'flag_ca' || 'flag_us' => Icons.flag_outlined,
    _ => Icons.route_outlined,
  };
}
