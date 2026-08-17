import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';
import '../subscriptions/subscriptions_screen.dart';
import '../servers/add_server_dialog.dart';

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
  List<String>? _pendingSubscriptionOrder;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final manifestAsync = ref.watch(mosaicManifestProvider);
    final subscriptions =
        ref.watch(subscriptionsProvider).valueOrNull ?? const <Subscription>[];
    final servers = ref.watch(serversProvider).valueOrNull ?? const <Server>[];
    final localGroups = ref.watch(localServerGroupsProvider).valueOrNull ??
        const <ServerGroup>[];
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
      localGroups: localGroups,
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
                          onReorder: _reorderSubscriptions,
                          onEdit: _editSubscription,
                          onDelete: _deleteSubscription,
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
    final direct = subscriptions
        .where((source) => source.id == 'mosaic-direct')
        .cast<Subscription?>()
        .firstWhere(
          (source) => source != null,
          orElse: () => (manifest?.groups.isNotEmpty ?? false)
              ? Subscription(id: 'mosaic-direct', name: 'MosaicVPN')
              : null,
        );
    final regular = subscriptions
        .where((source) => source.id != 'mosaic-direct')
        .toList(growable: true);

    final pendingOrder = _pendingSubscriptionOrder;
    if (pendingOrder != null) {
      final byID = {for (final source in regular) source.id: source};
      final ordered = <Subscription>[];
      for (final id in pendingOrder) {
        final source = byID.remove(id);
        if (source != null) ordered.add(source);
      }
      // Preserve feeds that appeared after drag began (for example after a
      // background import) instead of silently hiding them.
      ordered.addAll(byID.values);
      regular
        ..clear()
        ..addAll(ordered);
    }

    return <Subscription>[
      if (direct != null) direct,
      ...regular,
    ];
  }

  List<_RouteRow> _rowsFor({
    required ProviderManifest? manifest,
    required Subscription source,
    required List<Server> servers,
    required List<ServerGroup> localGroups,
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
    final rows = <_RouteRow>[];
    if (source.id == 'local-default') {
      rows.addAll(
        localGroups.map(
          (group) => _RouteRow(
            id: group.id,
            type: 'Группа',
            name: group.name.isEmpty ? 'Безымянный сборник' : group.name,
            ping: null,
            traffic: 'Авто',
            isGroup: true,
            icon: Icons.folder_copy_outlined,
          ),
        ),
      );
    }
    rows.addAll(
      servers
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
          ),
    );
    return rows;
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
    ref.invalidate(localServerGroupsProvider);
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

  Future<void> _reorderSubscriptions(List<String> orderedIDs) async {
    setState(() => _pendingSubscriptionOrder = orderedIDs);
    final stored =
        ref.read(subscriptionsProvider).valueOrNull ?? const <Subscription>[];
    // MosaicVPN's official source is visually pinned and cannot be dragged,
    // but it can still be a persisted subscription after account linking. The
    // backend requires every stored ID in an atomic reorder request.
    final backendOrder = [
      if (stored.any((source) => source.id == 'mosaic-direct')) 'mosaic-direct',
      ...orderedIDs,
    ];
    try {
      await ref.read(daemonApiProvider).reorderSubscriptions(backendOrder);
      ref.invalidate(subscriptionsProvider);
    } catch (_) {
      if (mounted) {
        setState(() => _pendingSubscriptionOrder = null);
        _showMessage(
          'Не удалось сохранить порядок подписок. Повторите попытку.',
          ThemeColors.of(context).danger,
        );
      }
    }
  }

  Future<void> _editSubscription(Subscription source) async {
    final controller = TextEditingController(text: source.name);
    final updatedName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Переименовать подписку'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Название',
            hintText: 'Например, Личный сервер',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    final name = updatedName?.trim();
    if (name == null || name.isEmpty || name == source.name) return;

    try {
      await ref.read(daemonApiProvider).renameSubscription(source.id, name);
      ref.invalidate(subscriptionsProvider);
    } catch (_) {
      if (mounted) {
        _showMessage('Не удалось переименовать подписку.',
            ThemeColors.of(context).danger);
      }
    }
  }

  Future<void> _deleteSubscription(Subscription source) async {
    final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Удалить подписку?'),
            content: Text(
              '«${source.name.isEmpty ? 'Безымянный источник' : source.name}» и все маршруты из неё будут удалены с этого устройства. Это действие нельзя отменить.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: ThemeColors.of(context).danger),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Удалить'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved) return;

    try {
      await ref.read(daemonApiProvider).deleteSubscription(source.id);
      if (!mounted) return;
      setState(() {
        if (_selectedSubscriptionId == source.id) {
          _selectedSubscriptionId = null;
        }
        _pendingSubscriptionOrder = null;
      });
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(serversProvider);
      _showMessage('Подписка удалена.', ThemeColors.of(context).success);
    } catch (_) {
      if (mounted) {
        _showMessage('Не удалось удалить подписку. Повторите попытку.',
            ThemeColors.of(context).danger);
      }
    }
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
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('Создать локальный сборник'),
              subtitle: const Text('Объединяйте добавленные вручную серверы'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _createLocalGroup();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_to_queue_outlined),
              title: const Text('Добавить профиль'),
              subtitle: const Text('Вручную, из буфера обмена, QR или файла'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _addLocalProfiles();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: const Text('Добавить удалённую подписку'),
              subtitle:
                  const Text('Импортировать URL подписки совместимого сервиса'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showDialog<void>(
                  context: context,
                  builder: (_) => const AddSubscriptionFeedDialog(),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _createLocalGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Новый локальный сборник'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Название сборника',
            hintText: 'Например, Работа или Личные серверы',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;

    try {
      await ref.read(daemonApiProvider).createGroup(trimmed);
      ref.invalidate(localServerGroupsProvider);
      ref.invalidate(subscriptionsProvider);
      if (mounted) {
        _showMessage('Сборник «$trimmed» создан. Добавьте в него профиль.',
            ThemeColors.of(context).success);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('Не удалось создать локальный сборник.',
            ThemeColors.of(context).danger);
      }
    }
  }

  Future<void> _addLocalProfiles() async {
    final profiles = await showAddServerDialog(context);
    if (profiles == null || profiles.isEmpty || !mounted) return;

    final api = ref.read(daemonApiProvider);
    List<ServerGroup> groups;
    try {
      groups = await api.listGroups();
    } catch (_) {
      groups = const <ServerGroup>[];
    }
    if (!mounted) return;
    final targetGroupID = await _selectLocalGroup(groups);
    if (!mounted || targetGroupID == null) return;

    try {
      for (final profile in profiles) {
        await api.addServer(profile.copyWith(tag: targetGroupID));
      }
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(serversProvider);
      ref.invalidate(localServerGroupsProvider);
      if (mounted) {
        _showMessage(
          profiles.length == 1
              ? 'Профиль добавлен.'
              : 'Добавлено профилей: ${profiles.length}.',
          ThemeColors.of(context).success,
        );
      }
    } catch (_) {
      if (mounted) {
        _showMessage(
            'Не удалось добавить профиль. Проверьте параметры и повторите попытку.',
            ThemeColors.of(context).danger);
      }
    }
  }

  Future<String?> _selectLocalGroup(List<ServerGroup> groups) async {
    var selected = '';
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Добавить в сборник'),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(labelText: 'Сборник'),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Без группы — добавить как отдельный сервер'),
              ),
              ...groups.map(
                (group) => DropdownMenuItem(
                  value: group.id,
                  child: Text(group.name),
                ),
              ),
            ],
            onChanged: (value) => setDialogState(() => selected = value ?? ''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(selected),
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
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

enum _SourceTabAction { edit, delete }

class _SourceTabs extends StatefulWidget {
  const _SourceTabs({
    required this.sources,
    required this.selectedId,
    required this.onSelected,
    required this.onReorder,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Subscription> sources;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Future<void> Function(List<String> orderedIDs) onReorder;
  final Future<void> Function(Subscription source) onEdit;
  final Future<void> Function(Subscription source) onDelete;

  @override
  State<_SourceTabs> createState() => _SourceTabsState();
}

class _SourceTabsState extends State<_SourceTabs> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollTabs(double delta) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target.toDouble(),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showContextMenu(
    Subscription source,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_SourceTabAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: _SourceTabAction.edit,
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('Переименовать'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: _SourceTabAction.delete,
          child: ListTile(
            leading: Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text('Удалить'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SourceTabAction.edit:
        await widget.onEdit(source);
      case _SourceTabAction.delete:
        await widget.onDelete(source);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final direct = widget.sources
        .where((source) => source.id == 'mosaic-direct')
        .cast<Subscription?>()
        .firstWhere((source) => source != null, orElse: () => null);
    final regular = widget.sources
        .where((source) => source.id != 'mosaic-direct')
        .toList(growable: false);

    return SizedBox(
      height: 46,
      child: Row(
        children: [
          _TabArrow(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Показать предыдущие подписки',
            enabled: regular.isNotEmpty,
            onPressed: () => _scrollTabs(-260),
          ),
          if (direct != null) ...[
            const SizedBox(width: 4),
            _SourceTab(
              source: direct,
              selected: direct.id == widget.selectedId,
              onSelected: () => widget.onSelected(direct.id),
              immutable: true,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: regular.isEmpty
                ? const SizedBox.shrink()
                : ReorderableListView.builder(
                    key: const PageStorageKey('subscription-tabs'),
                    scrollDirection: Axis.horizontal,
                    scrollController: _scrollController,
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.only(right: 4),
                    itemCount: regular.length,
                    onReorderItem: (oldIndex, newIndex) async {
                      if (newIndex == oldIndex) return;
                      final reordered = [...regular];
                      final moved = reordered.removeAt(oldIndex);
                      reordered.insert(newIndex, moved);
                      await widget.onReorder(
                        reordered.map((source) => source.id).toList(),
                      );
                    },
                    itemBuilder: (context, index) {
                      final source = regular[index];
                      return Padding(
                        key: ValueKey('subscription-tab-${source.id}'),
                        padding: const EdgeInsets.only(right: 8),
                        child: Listener(
                          onPointerDown: (event) {
                            if (event.buttons == kSecondaryMouseButton) {
                              _showContextMenu(source, event.position);
                            }
                          },
                          child: _SourceTab(
                            source: source,
                            selected: source.id == widget.selectedId,
                            onSelected: () => widget.onSelected(source.id),
                            dragHandle: ReorderableDragStartListener(
                              index: index,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 18,
                                color: colors.textMuted,
                              ),
                            ),
                            onMenu: (position) =>
                                _showContextMenu(source, position),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          _TabArrow(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Показать следующие подписки',
            enabled: regular.isNotEmpty,
            onPressed: () => _scrollTabs(260),
          ),
        ],
      ),
    );
  }
}

class _TabArrow extends StatelessWidget {
  const _TabArrow({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon),
        color: colors.textPrimary,
        disabledColor: colors.textMuted.withValues(alpha: .35),
        splashRadius: 18,
      ),
    );
  }
}

class _SourceTab extends StatelessWidget {
  const _SourceTab({
    required this.source,
    required this.selected,
    required this.onSelected,
    this.immutable = false,
    this.dragHandle,
    this.onMenu,
  });

  final Subscription source;
  final bool selected;
  final VoidCallback onSelected;
  final bool immutable;
  final Widget? dragHandle;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final title = source.name.isEmpty ? 'Безымянный источник' : source.name;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 132, maxWidth: 250),
          child: Ink(
            height: 42,
            padding: EdgeInsets.only(
              left: dragHandle == null ? 12 : 7,
              right: 6,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? AtlasTheme.accent.withValues(alpha: .16)
                  : colors.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AtlasTheme.accent.withValues(alpha: .55)
                    : colors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dragHandle != null) ...[
                  dragHandle!,
                  const SizedBox(width: 3),
                ],
                Icon(
                  immutable
                      ? Icons.verified_user_outlined
                      : Icons.rss_feed_outlined,
                  size: 17,
                  color: selected ? AtlasTheme.accent : colors.textMuted,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? AtlasTheme.accent : colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onMenu != null)
                  IconButton(
                    tooltip: 'Управление подпиской',
                    constraints:
                        const BoxConstraints.tightFor(width: 30, height: 30),
                    padding: EdgeInsets.zero,
                    splashRadius: 16,
                    icon: Icon(Icons.more_horiz_rounded,
                        size: 18, color: colors.textMuted),
                    onPressed: () {
                      final renderBox = context.findRenderObject() as RenderBox;
                      onMenu!(renderBox
                          .localToGlobal(renderBox.size.center(Offset.zero)));
                    },
                  ),
              ],
            ),
          ),
        ),
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
