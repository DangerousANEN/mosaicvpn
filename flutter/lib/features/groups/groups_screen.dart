import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/models/models.dart';
import '../../core/platform/app_platform.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/services/elevation_prompt.dart';
import '../../core/services/smart_group_latency_test.dart';
import '../../core/services/smart_group_selector.dart';
import '../../core/services/ui_preferences_service.dart';
import '../../core/theme/atlas_theme.dart';
import '../subscriptions/subscriptions_screen.dart';
import '../servers/add_server_dialog.dart';
import 'subscription_cabinet_screen.dart';

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

enum _RouteSort { type, name, ping, traffic, jitter, loss, speed }

enum _RouteColumn {
  type,
  name,
  country,
  ping,
  jitter,
  loss,
  speed,
  traffic,
  action,
}

enum _RouteAction {
  connect,
  disconnect,
  testLatency,
  stopLatencyTest,
  testSpeed,
  delete,
}

class _RouteRow {
  const _RouteRow({
    required this.id,
    required this.type,
    required this.name,
    required this.ping,
    required this.traffic,
    required this.isGroup,
    this.isSmartGroup = false,
    this.jitter,
    this.loss,
    this.speed,
    this.country = '',
    required this.icon,
    this.disabled = false,
    this.disabledReason = '',
    this.canTest = false,
    this.canDelete = false,
  });

  final String id;
  final String type;
  final String name;
  final int? ping;
  final String traffic;

  /// Null means that no measurement has been run yet; the UI must render an
  /// em dash rather than fabricate an automatic/default value.
  final int? jitter;
  final double? loss;
  final int? speed;
  final String country;
  final bool isGroup;
  final bool isSmartGroup;
  final IconData icon;
  final bool disabled;
  final String disabledReason;
  final bool canTest;
  final bool canDelete;
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
  String? _connectingId;
  _RouteSort _sort = _RouteSort.name;
  bool _ascending = true;
  List<String>? _pendingSubscriptionOrder;
  final SmartGroupSelector _smartGroupSelector = SmartGroupSelector();
  SmartGroupLatencyTest? _activeGroupLatencyTest;
  SmartGroupLatencyProgress? _groupLatencyProgress;
  final Map<_RouteColumn, bool> _visibleColumns = {
    _RouteColumn.type: true,
    _RouteColumn.name: true,
    _RouteColumn.country: true,
    _RouteColumn.ping: true,
    _RouteColumn.jitter: false,
    _RouteColumn.loss: false,
    _RouteColumn.speed: false,
    _RouteColumn.traffic: true,
    _RouteColumn.action: true,
  };
  final Map<_RouteColumn, double> _columnWidths = {
    _RouteColumn.type: 144,
    _RouteColumn.name: 330,
    _RouteColumn.country: 128,
    _RouteColumn.ping: 104,
    _RouteColumn.jitter: 112,
    _RouteColumn.loss: 104,
    _RouteColumn.speed: 132,
    _RouteColumn.traffic: 132,
    _RouteColumn.action: 72,
  };

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    // The legacy manifest is used only to make an older Android source visible
    // before its subscription list has refreshed. Route rows themselves always
    // use the selected subscription-scoped manifest below.
    final legacyManifestAsync = ref.watch(mosaicManifestProvider);
    final subscriptions =
        ref.watch(subscriptionsProvider).valueOrNull ?? const <Subscription>[];
    final servers = ref.watch(serversProvider).valueOrNull ?? const <Server>[];
    final localGroups = ref.watch(localServerGroupsProvider).valueOrNull ??
        const <ServerGroup>[];
    final status = ref.watch(vpnStatusProvider).valueOrNull;

    if (legacyManifestAsync.isLoading && subscriptions.isEmpty) {
      return Scaffold(
        backgroundColor: colors.bgBase,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final sources = _sourcesFor(legacyManifestAsync.valueOrNull, subscriptions);
    final sharedSubId = ref.watch(selectedSubscriptionIdProvider);
    final sharedRouteId = ref.watch(selectedRouteIdProvider);
    final selectedSource = sources.firstWhere(
      (source) => source.id == sharedSubId,
      orElse: () => sources.isNotEmpty ? sources.first : Subscription(),
    );
    final selectedManifestAsync = _isMosaicSubscription(selectedSource) &&
            selectedSource.id.isNotEmpty
        ? ref.watch(providerManifestForSubscriptionProvider(selectedSource.id))
        : null;
    final rows = _rowsFor(
      manifest: selectedManifestAsync?.valueOrNull,
      source: selectedSource,
      servers: servers,
      localGroups: localGroups,
    )..sort(_compareRows);

    if (sources.isNotEmpty && selectedSource.id != sharedSubId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(selectedSubscriptionIdProvider.notifier)
              .set(selectedSource.id);
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
                          onRefreshSource: _refreshSubscription,
                          onOpenCabinet: _openSubscriptionCabinet,
                          onEdit: _editSubscription,
                          onDelete: _deleteSubscription,
                          onTestAllRoutes: _testAllRoutesForSource,
                        ),
                        const SizedBox(height: 18),
                      ],
                      _SourceSummary(
                        source: selectedSource,
                        isMosaic: _isMosaicSubscription(selectedSource),
                        onOpenCabinet: selectedSource.id.isEmpty
                            ? null
                            : () => _openSubscriptionCabinet(selectedSource),
                      ),
                      const SizedBox(height: 14),
                      if (selectedManifestAsync?.hasError == true &&
                          _isMosaicSubscription(selectedSource))
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
                              ? (status!.activeGroupId.isNotEmpty
                                  ? status.activeGroupId
                                  : status.server?.id)
                              : null,
                          selectedId: sharedRouteId,
                          connectingId: _connectingId,
                          sort: _sort,
                          ascending: _ascending,
                          onSort: _applySort,
                          onSortMenu: _showSortMenu,
                          visibleColumns: _visibleColumns,
                          columnWidths: _columnWidths,
                          onColumnMenu: _showColumnMenu,
                          onResizeColumn: _resizeColumn,
                          activeLatencyTestGroupId:
                              _activeGroupLatencyTest == null
                                  ? null
                                  : _groupLatencyProgress?.groupId,
                          onStopGroupLatencyTest: _stopGroupLatencyTest,
                          onRouteMenu: _showRouteMenu,
                          onPrimaryAction: _handleRoutePrimaryAction,
                          onConnect: _connect,
                          onTest: _testRoute,
                          onDelete: _deleteRoute,
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

  bool _isMosaicSubscription(Subscription source) {
    // Keep the legacy ID hidden while v0.3.23 migration rewrites it into an
    // ordinary URL source. New sources are identified solely by their URL.
    if (source.id == 'mosaic-direct') return true;
    final uri = Uri.tryParse(source.url.trim());
    return uri != null &&
        uri.isScheme('https') &&
        uri.host.toLowerCase() == 'sub.zxc1x1.ru' &&
        uri.pathSegments.isNotEmpty;
  }

  List<Subscription> _sourcesFor(
    ProviderManifest? manifest,
    List<Subscription> subscriptions,
  ) {
    // MosaicVPN itself is a normal URL source. Generic third-party provider
    // sources keep their existing immutable/pinned behavior, but no synthetic
    // Mosaic row is created from a manifest.
    final providers = subscriptions
        .where((source) => source.isProviderSource)
        .toList(growable: false);
    final orderedSources = subscriptions
        .where((source) => !source.isProviderSource)
        .toList(growable: true);
    final pendingOrder = _pendingSubscriptionOrder;
    if (pendingOrder == null) return [...providers, ...orderedSources];

    final byID = {for (final source in orderedSources) source.id: source};
    final reordered = <Subscription>[];
    for (final id in pendingOrder) {
      final source = byID.remove(id);
      if (source != null) reordered.add(source);
    }
    reordered.addAll(byID.values);
    return [...providers, ...reordered];
  }

  List<_RouteRow> _rowsFor({
    required ProviderManifest? manifest,
    required Subscription source,
    required List<Server> servers,
    required List<ServerGroup> localGroups,
  }) {
    final rows = <_RouteRow>[];
    if (_isMosaicSubscription(source) || source.isProviderSource) {
      final strings = AppStrings.of(context);
      rows.addAll((manifest?.routes ?? const <ManifestGroup>[])
          // The provider decides which route categories exist. A group stays a
          // normal route row even when disabled; private physical pool nodes
          // never cross this manifest/UI boundary.
          .where((group) => group.category != 'raw')
          .map(
            (group) => _RouteRow(
              id: group.id,
              type: group.routeType == 'direct'
                  ? (group.protocol.isEmpty
                      ? 'VLESS'
                      : group.protocol.toUpperCase())
                  : strings.t('smart_group'),
              name: _groupTitle(group),
              ping: _groupLatencyProgress?.groupId == group.id
                  ? _groupLatencyProgress?.latencyMs
                  : null,
              jitter: _groupLatencyProgress?.groupId == group.id
                  ? _groupLatencyProgress?.jitterMs
                  : null,
              loss: _groupLatencyProgress?.groupId == group.id
                  ? _groupLatencyProgress?.lossPercent
                  : null,
              traffic: _groupLatencyProgress?.groupId == group.id
                  ? '${_groupLatencyProgress!.label} проверено'
                  : '—',
              country: group.countryCode,
              isGroup: true,
              isSmartGroup: group.routeType == 'smart_group',
              icon: _groupIcon(group.icon),
              disabled: group.disabled,
              disabledReason: group.disabledReason,
              canTest: true,
            ),
          ));
    }
    if (source.id == 'local-default') {
      rows.addAll(
        localGroups.map(
          (group) => _RouteRow(
            id: group.id,
            type: AppStrings.of(context).t('local_group'),
            name: group.name.isEmpty ? 'Безымянный сборник' : group.name,
            ping: null,
            traffic: AppStrings.of(context).t('automatic'),
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
              !_isMosaicSubscription(source) &&
              !source.hidePhysicalNodes)
          .map(
            (server) => _RouteRow(
              id: server.id,
              type: server.protocol.displayName,
              name: server.name.isEmpty ? 'Безымянный сервер' : server.name,
              ping: !server.hasLatency && !server.latencyFailed
                  ? null
                  : server.latencyFailed
                      ? -1
                      : server.lastTestMS,
              traffic: '—',
              // Jitter and loss stay null until the live probe records them;
              // download speed can already be supplied by a completed speed test.
              jitter: null,
              loss: null,
              speed: server.downSpeed,
              country: server.country,
              isGroup: false,
              icon: Icons.dns_outlined,
              canTest: true,
              canDelete: source.id == 'local-default',
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
      case _RouteSort.jitter:
        result = (left.jitter ?? 1 << 30).compareTo(right.jitter ?? 1 << 30);
      case _RouteSort.loss:
        result = (left.loss ?? double.infinity)
            .compareTo(right.loss ?? double.infinity);
      case _RouteSort.speed:
        result = (right.speed ?? -1).compareTo(left.speed ?? -1);
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
    if (sourceId == ref.read(selectedSubscriptionIdProvider)) return;
    ref.read(selectedSubscriptionIdProvider.notifier).set(sourceId);
  }

  Future<void> _reorderSubscriptions(List<String> orderedIDs) async {
    setState(() => _pendingSubscriptionOrder = orderedIDs);
    final stored =
        ref.read(subscriptionsProvider).valueOrNull ?? const <Subscription>[];
    // Every URL subscription, including MosaicVPN, is user-owned and may be
    // moved. Generic provider sources remain pinned for compatibility.
    final backendOrder = [
      ...stored
          .where((source) => source.isProviderSource)
          .map((source) => source.id),
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

  Future<void> _refreshSubscription(Subscription source) async {
    try {
      await ref.read(daemonApiProvider).refreshSubscription(source.id);
      ref.invalidate(mosaicManifestProvider);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(serversProvider);
      if (mounted) {
        _showMessage('Подписка обновлена.', ThemeColors.of(context).success);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          error.toString().replaceFirst('Bad state: ', ''),
          ThemeColors.of(context).danger,
        );
      }
    }
  }

  void _openSubscriptionCabinet(Subscription source) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SubscriptionCabinetScreen(subscription: source),
      ),
    );
  }

  /// Runs the latency test for every route of one subscription: physical
  /// servers through [DaemonApiBase.testServer], Smart Groups through the
  /// shared group latency runner. Results stream into the same ping column
  /// used by per-route tests.
  Future<void> _testAllRoutesForSource(Subscription source) async {
    if (_activeGroupLatencyTest != null) {
      _showMessage(
        'Сначала завершите или остановите активную проверку задержки.',
        ThemeColors.of(context).warning,
      );
      return;
    }
    final api = ref.read(daemonApiProvider);

    // Only user-visible routes take part in "test all": manifest routes for a
    // Mosaic source, plain servers otherwise. Hidden Smart Group pool
    // candidates are probed by their group runner, never one-by-one here.
    List<Server> scoped = const <Server>[];
    List<ManifestGroup> groups = const <ManifestGroup>[];
    if (_isMosaicSubscription(source) && source.id.isNotEmpty) {
      try {
        final manifest = await ref
            .read(providerManifestForSubscriptionProvider(source.id).future);
        groups = manifest.routes
            .where((group) => group.category != 'raw' && !group.disabled)
            .toList(growable: false);
      } catch (_) {
        // Manifest failure falls back to the visible server list below.
      }
    }
    if (!mounted) return;
    if (groups.isEmpty) {
      final allServers =
          ref.read(serversProvider).valueOrNull ?? const <Server>[];
      scoped = allServers
          .where((server) => server.subscriptionID == source.id)
          .toList(growable: false);
    }

    final total = scoped.length + groups.length;
    if (total == 0) {
      _showMessage(
          'Нет маршрутов для проверки.', ThemeColors.of(context).textSecondary);
      return;
    }

    final progress =
        ValueNotifier<ProgressValue>(ProgressValue(done: 0, total: total));

    // Parallel sweep with cancellation. Four workers keep the burst modest
    // while finishing an order of magnitude faster than the old serial loop.
    var done = 0;
    var reachable = 0;
    var nextTask = 0;
    final tasks = <Future<bool> Function()>[
      for (final server in scoped)
        () async {
          try {
            final result = await api.testServer(server.id);
            return !result.failed;
          } catch (_) {
            return false; // unreachable route must not stop the sweep
          }
        },
      for (final group in groups)
        () async {
          try {
            final result = await api.testDirectRoute(group.id);
            return !result.failed && result.latencyMS >= 0;
          } catch (_) {
            // Smart Groups fall back to their own bounded runner.
            try {
              await _runGroupLatencyTest(group);
              return true;
            } catch (_) {
              return false;
            }
          }
        },
    ];

    if (!mounted) return;
    final progressColor = ThemeColors.of(context).textSecondary;

    // Non-dismissable progress dialog with a stop button. Popping it sets
    // the cancel flag; workers finish their current probe and exit the loop.
    var cancelled = false;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Проверка маршрутов'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<ProgressValue>(
                  valueListenable: progress,
                  builder: (_, value, __) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${value.done}/${value.total}',
                          style: TextStyle(color: progressColor)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value:
                            value.total == 0 ? null : value.done / value.total,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Остановить'),
              ),
            ],
          ),
        );
      },
    ));

    Future<bool> worker() async {
      while (!cancelled && nextTask < tasks.length) {
        final task = tasks[nextTask++];
        final ok = await task();
        done++;
        if (ok) reachable++;
        progress.value = ProgressValue(done: done, total: total);
      }
      return true;
    }

    await Future.wait(<Future<bool>>[
      worker(),
      worker(),
      worker(),
      worker(),
    ]);

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    ref.invalidate(serversProvider);
    if (!mounted) return;
    final successColor = ThemeColors.of(context).success;
    final warningColor = ThemeColors.of(context).warning;
    _showMessage(
      cancelled
          ? 'Остановлено: отвечают $reachable из $total.'
          : 'Готово: отвечают $reachable из $total маршрутов.',
      reachable > 0 ? successColor : warningColor,
    );
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
        if (ref.read(selectedSubscriptionIdProvider) == source.id) {
          ref.read(selectedSubscriptionIdProvider.notifier).set(null);
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
            value: _RouteSort.ping, child: Text('Сортировать по задержке')),
        PopupMenuItem(
            value: _RouteSort.jitter, child: Text('Сортировать по джиттеру')),
        PopupMenuItem(
            value: _RouteSort.loss, child: Text('Сортировать по потерям')),
        PopupMenuItem(
            value: _RouteSort.speed, child: Text('Сортировать по скорости')),
        PopupMenuItem(
            value: _RouteSort.traffic, child: Text('Сортировать по трафику')),
      ],
    );
    if (selected != null && mounted) _applySort(selected);
  }

  Future<void> _showColumnMenu(Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_RouteColumn>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: _RouteColumn.values
          .where((column) => column != _RouteColumn.action)
          .map(
            (column) => CheckedPopupMenuItem<_RouteColumn>(
              value: column,
              checked: _visibleColumns[column] ?? false,
              child: Text(_columnLabel(column)),
            ),
          )
          .toList(growable: false),
    );
    if (selected == null || !mounted) return;
    setState(() {
      // Keep the route name permanently visible; the user must always know
      // what a connect action targets.
      if (selected != _RouteColumn.name) {
        _visibleColumns[selected] = !(_visibleColumns[selected] ?? false);
      }
    });
  }

  void _resizeColumn(_RouteColumn column, double delta) {
    final current = _columnWidths[column] ?? 120;
    setState(() => _columnWidths[column] = (current + delta).clamp(72, 520));
  }

  String _columnLabel(_RouteColumn column) => switch (column) {
        _RouteColumn.type => 'Тип',
        _RouteColumn.name => 'Название',
        _RouteColumn.country => 'Страна',
        _RouteColumn.ping => 'Задержка',
        _RouteColumn.jitter => 'Джиттер',
        _RouteColumn.loss => 'Потери',
        _RouteColumn.speed => 'Скорость',
        _RouteColumn.traffic => 'Трафик',
        _RouteColumn.action => 'Действие',
      };

  Future<void> _connect(_RouteRow row) async {
    if (row.disabled) {
      _showMessage(
        row.disabledReason.isEmpty
            ? 'Этот маршрут пока недоступен.'
            : row.disabledReason,
        ThemeColors.of(context).warning,
      );
      return;
    }
    setState(() => _connectingId = row.id);
    ref.read(selectedRouteIdProvider.notifier).set(row.id);
    try {
      final api = ref.read(daemonApiProvider);
      final selectedSourceID = ref.read(selectedSubscriptionIdProvider);
      final selectedManifest = selectedSourceID?.isNotEmpty == true
          ? ref
              .read(providerManifestForSubscriptionProvider(selectedSourceID!))
              .valueOrNull
          : ref.read(mosaicManifestProvider).valueOrNull;
      final manifestGroup = selectedManifest?.groups
          .where((group) => group.id == row.id)
          .cast<ManifestGroup?>()
          .firstWhere((group) => group != null, orElse: () => null);
      // Desktop ranks opaque Smart Group candidates through its local daemon.
      // Android has no mosaicd: its facade builds a signed group-scoped native
      // TUN config and waits for the real VpnService terminal state instead.
      if (row.isGroup &&
          row.isSmartGroup &&
          manifestGroup != null &&
          !AppPlatform.isAndroid) {
        await _smartGroupSelector.connect(api, manifestGroup);
      } else if (row.isGroup) {
        await api.connectGroup(row.id);
      } else {
        await api.connect(row.id);
      }
      final uiPrefs = UiPreferencesService();
      await uiPrefs.writeLastConnectedRouteId(row.id);
      if (selectedSourceID != null && selectedSourceID.isNotEmpty) {
        await uiPrefs.writeLastConnectedSubscriptionId(selectedSourceID);
      }
      ref.invalidate(vpnStatusProvider);
      if (mounted) {
        _showMessage(
            'Подключение установлено.', ThemeColors.of(context).success);
      }
    } catch (error) {
      // TUN without an administrator token is fully recoverable: offer the
      // UAC restart instead of a dead-end error notice (Throne behaviour).
      if (isElevationRequiredError(error) && mounted) {
        final accepted = await handleElevationRequired(context);
        if (!mounted) return;
        if (!accepted) {
          _showMessage(
            'Подключение в режиме TUN требует прав администратора.',
            ThemeColors.of(context).danger,
          );
        }
        return;
      }
      if (mounted) {
        final detail = error.toString().replaceFirst('Bad state: ', '');
        _showMessage(
          detail.isEmpty
              ? 'Не удалось подключиться. Обновите маршрут и повторите попытку.'
              : detail,
          ThemeColors.of(context).danger,
        );
      }
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  void _handleRoutePrimaryAction(_RouteRow row) {
    if (_connectingId != null) return;
    final status = ref.read(vpnStatusProvider).valueOrNull;
    final activeRouteID = status?.activeGroupId.isNotEmpty == true
        ? status!.activeGroupId
        : status?.server?.id;
    if (status?.isConnected == true && activeRouteID == row.id) {
      unawaited(_disconnectActiveRoute());
      return;
    }
    if (row.disabled) return;
    final currentSelectedId = ref.read(selectedRouteIdProvider);
    if (currentSelectedId == row.id) {
      _connect(row);
      return;
    }
    ref.read(selectedRouteIdProvider.notifier).set(row.id);
  }

  Future<void> _disconnectActiveRoute() async {
    try {
      await ref.read(daemonApiProvider).disconnect();
      ref.invalidate(vpnStatusProvider);
    } catch (_) {
      if (mounted) {
        _showMessage('Не удалось отключиться.', ThemeColors.of(context).danger);
      }
    }
  }

  Future<void> _showRouteMenu(_RouteRow row, Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final activeGroupID =
        _activeGroupLatencyTest == null ? null : _groupLatencyProgress?.groupId;
    final status = ref.read(vpnStatusProvider).valueOrNull;
    final activeRouteID = status?.activeGroupId.isNotEmpty == true
        ? status!.activeGroupId
        : status?.server?.id;
    final isActiveRoute =
        status?.isConnected == true && activeRouteID == row.id;
    final canDisconnect = status?.isConnected == true;
    final action = await showMenu<_RouteAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: canDisconnect ? _RouteAction.disconnect : _RouteAction.connect,
          enabled: canDisconnect || !row.disabled,
          child: ListTile(
            leading: Icon(canDisconnect
                ? Icons.stop_circle_outlined
                : Icons.play_circle_outline_rounded),
            title: Text(canDisconnect
                ? isActiveRoute
                    ? 'Отключиться'
                    : 'Отключить активный маршрут'
                : 'Подключиться'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        if (row.isGroup && activeGroupID == row.id)
          const PopupMenuItem(
            value: _RouteAction.stopLatencyTest,
            child: ListTile(
              leading: Icon(Icons.stop_circle_outlined),
              title: Text('Остановить тест задержки'),
              contentPadding: EdgeInsets.zero,
            ),
          )
        else
          PopupMenuItem(
            value: _RouteAction.testLatency,
            enabled: row.canTest && activeGroupID == null,
            child: ListTile(
              leading: const Icon(Icons.network_ping_rounded),
              title: Text(row.isGroup
                  ? 'Тест задержки группы'
                  : 'Проверить задержку маршрута'),
              subtitle: activeGroupID == null
                  ? null
                  : const Text('Сначала завершите активный тест'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (!row.isGroup)
          const PopupMenuItem(
            value: _RouteAction.testSpeed,
            child: ListTile(
              leading: Icon(Icons.speed_rounded),
              title: Text('Тест скорости маршрута'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (row.canDelete)
          PopupMenuItem(
            value: _RouteAction.delete,
            child: ListTile(
              leading: Icon(Icons.delete_outline,
                  color: ThemeColors.of(context).danger),
              title: Text('Удалить с устройства',
                  style: TextStyle(color: ThemeColors.of(context).danger)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _RouteAction.connect:
        await _connect(row);
      case _RouteAction.disconnect:
        try {
          await ref.read(daemonApiProvider).disconnect();
          ref.invalidate(vpnStatusProvider);
        } catch (_) {
          if (mounted) {
            _showMessage('Не удалось остановить маршрут.',
                ThemeColors.of(context).danger);
          }
        }
      case _RouteAction.testLatency:
        await _testRoute(row);
      case _RouteAction.stopLatencyTest:
        _stopGroupLatencyTest();
      case _RouteAction.testSpeed:
        await _testSpeedRoute(row);
      case _RouteAction.delete:
        await _deleteRoute(row);
    }
  }

  String _formatSpeed(int bps) {
    if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(1)} Мбит/с';
    if (bps >= 1000) return '${(bps / 1000).toStringAsFixed(0)} Кбит/с';
    return '$bps бит/с';
  }

  Future<void> _testSpeedRoute(_RouteRow row) async {
    if (row.isGroup) return;
    try {
      final result =
          await ref.read(daemonApiProvider).speedTest(serverID: row.id);
      if (!mounted) return;
      if (result.error.isNotEmpty) {
        _showMessage(result.error, ThemeColors.of(context).danger);
        return;
      }
      _showMessage(
        result.downloadBps > 0
            ? 'Тест скорости завершён: ${_formatSpeed(result.downloadBps)}.'
            : 'Тест скорости завершён.',
        ThemeColors.of(context).success,
      );
      ref.invalidate(serversProvider);
    } catch (_) {
      if (mounted) {
        _showMessage('Не удалось выполнить тест скорости маршрута.',
            ThemeColors.of(context).danger);
      }
    }
  }

  Future<void> _testRoute(_RouteRow row) async {
    if (!row.canTest) return;
    if (_activeGroupLatencyTest != null) {
      _showMessage(
        'Сначала завершите или остановите активную проверку задержки.',
        ThemeColors.of(context).warning,
      );
      return;
    }
    if (row.isGroup) {
      final sourceID = ref.read(selectedSubscriptionIdProvider);
      final manifest = sourceID?.isNotEmpty == true
          ? await ref
              .read(providerManifestForSubscriptionProvider(sourceID!).future)
          : await ref.read(mosaicManifestProvider.future);
      if (!mounted) return;
      final group = manifest.routes.cast<ManifestGroup?>().firstWhere(
            (value) => value?.id == row.id,
            orElse: () => null,
          );
      if (group == null) {
        _showMessage(
          'Smart Group не найдена. Обновите подписку и повторите попытку.',
          ThemeColors.of(context).warning,
        );
        return;
      }
      // A single-server direct route has no candidate feed: probing it with
      // the Smart Group runner used to report misleading group errors.
      if (!row.isSmartGroup) {
        try {
          final result =
              await ref.read(daemonApiProvider).testDirectRoute(group.id);
          ref.invalidate(serversProvider);
          if (!mounted) return;
          final ok = !result.failed && result.latencyMS >= 0;
          _showMessage(
            ok
                ? '${group.title.isEmpty ? group.id : group.title}: '
                    '${result.latencyMS} мс.'
                : 'Сервер не отвечает.',
            ok
                ? ThemeColors.of(context).success
                : ThemeColors.of(context).danger,
          );
        } catch (_) {
          if (!mounted) return;
          _showMessage(
            'Не удалось проверить маршрут. Повторите после обновления источника.',
            ThemeColors.of(context).danger,
          );
        }
        return;
      }
      await _runGroupLatencyTest(group);
      return;
    }
    try {
      await ref.read(daemonApiProvider).testServer(row.id);
      ref.invalidate(serversProvider);
      if (!mounted) return;
      _showMessage(
          'Проверка маршрута завершена.', ThemeColors.of(context).success);
    } catch (_) {
      if (!mounted) return;
      _showMessage(
        'Не удалось проверить маршрут. Повторите после обновления источника.',
        ThemeColors.of(context).danger,
      );
    }
  }

  Future<void> _runGroupLatencyTest(ManifestGroup group) async {
    final runner = SmartGroupLatencyTest(
      api: ref.read(daemonApiProvider),
      selector: _smartGroupSelector,
    );
    setState(() {
      _activeGroupLatencyTest = runner;
      _groupLatencyProgress = SmartGroupLatencyProgress(
        groupId: group.id,
        completed: 0,
        total: 0,
        successful: 0,
      );
    });
    try {
      final result = await runner.run(group, onProgress: (progress) {
        if (mounted) setState(() => _groupLatencyProgress = progress);
      });
      if (!mounted) return;
      _showMessage(
        result.cancelled
            ? 'Проверка задержки остановлена: ${result.label}.'
            : 'Проверка задержки завершена: ${result.label}.',
        result.cancelled
            ? ThemeColors.of(context).warning
            : ThemeColors.of(context).success,
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        error.toString().replaceFirst('Bad state: ', ''),
        ThemeColors.of(context).danger,
      );
    } finally {
      if (mounted) setState(() => _activeGroupLatencyTest = null);
    }
  }

  void _stopGroupLatencyTest() {
    final active = _activeGroupLatencyTest;
    if (active == null) return;
    active.cancel();
    _showMessage('Остановка проверки задержки после текущего измерения…',
        ThemeColors.of(context).textSecondary);
  }

  Future<void> _deleteRoute(_RouteRow row) async {
    if (!row.canDelete) {
      _showMessage(
        'Удалять можно только серверы, добавленные вручную в локальный сборник.',
        ThemeColors.of(context).warning,
      );
      return;
    }
    final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Удалить сервер?'),
            content:
                Text('«${row.name}» будет удалён только с этого устройства.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: ThemeColors.of(context).danger),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Удалить'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved) return;
    try {
      await ref.read(daemonApiProvider).deleteServer(row.id);
      ref.invalidate(serversProvider);
      if (!mounted) return;
      _showMessage('Сервер удалён.', ThemeColors.of(context).success);
    } catch (_) {
      if (!mounted) return;
      _showMessage(
          'Не удалось удалить сервер.', ThemeColors.of(context).danger);
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

enum _SourceTabAction {
  refresh,
  copyLink,
  openInBrowser,
  edit,
  delete,
  share,
  openCabinet,
  testAllRoutes,
}

class _SourceTabs extends StatefulWidget {
  const _SourceTabs({
    required this.sources,
    required this.selectedId,
    required this.onSelected,
    required this.onReorder,
    required this.onRefreshSource,
    required this.onOpenCabinet,
    required this.onEdit,
    required this.onDelete,
    required this.onTestAllRoutes,
  });

  final List<Subscription> sources;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Future<void> Function(List<String> orderedIDs) onReorder;
  final Future<void> Function(Subscription source) onRefreshSource;
  final ValueChanged<Subscription> onOpenCabinet;
  final Future<void> Function(Subscription source) onEdit;
  final Future<void> Function(Subscription source) onDelete;
  final Future<void> Function(Subscription source) onTestAllRoutes;

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

  void _showNotice(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyLink(Subscription source) async {
    if (source.url.trim().isEmpty) {
      _showNotice('У этой подписки нет экспортируемой ссылки.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: source.url));
    if (mounted) _showNotice('Ссылка подписки скопирована.');
  }

  Future<void> _openInBrowser(Subscription source) async {
    final uri = Uri.tryParse(source.url.trim());
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      _showNotice(
          'У этой подписки нет ссылки, которую можно открыть в браузере.');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      _showNotice('Не удалось открыть ссылку в браузере.');
    }
  }

  Future<void> _share(Subscription source) async {
    if (source.url.trim().isEmpty) {
      _showNotice('У этой подписки нет экспортируемой ссылки.');
      return;
    }
    await Share.share(
      source.url,
      subject: source.name.isEmpty ? 'Подписка MosaicVPN' : source.name,
    );
  }

  PopupMenuItem<_SourceTabAction> _menuItem(
    _SourceTabAction value,
    IconData icon,
    String title, {
    bool enabled = true,
    bool destructive = false,
  }) {
    return PopupMenuItem<_SourceTabAction>(
      value: value,
      enabled: enabled,
      child: ListTile(
        leading: Icon(icon, color: destructive ? Colors.redAccent : null),
        title: Text(title),
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  Future<void> _showContextMenu(
    Subscription source,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final hasUrl = source.url.trim().isNotEmpty;
    final isMutable = source.id != 'local-default' && !source.isProviderSource;
    final action = await showMenu<_SourceTabAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        _menuItem(_SourceTabAction.refresh, Icons.refresh_rounded, 'Обновить'),
        _menuItem(_SourceTabAction.testAllRoutes, Icons.network_ping_rounded,
            'Тест всех маршрутов'),
        _menuItem(
            _SourceTabAction.copyLink, Icons.link_rounded, 'Копировать ссылку',
            enabled: hasUrl),
        _menuItem(_SourceTabAction.openInBrowser, Icons.open_in_browser_rounded,
            'Открыть в браузере',
            enabled: hasUrl),
        _menuItem(_SourceTabAction.share, Icons.ios_share_rounded, 'Поделиться',
            enabled: hasUrl),
        const PopupMenuDivider(),
        _menuItem(_SourceTabAction.openCabinet,
            Icons.account_balance_wallet_outlined, 'Открыть профиль подписки'),
        if (isMutable) ...[
          const PopupMenuDivider(),
          _menuItem(
              _SourceTabAction.edit, Icons.edit_outlined, 'Переименовать'),
          _menuItem(_SourceTabAction.delete, Icons.delete_outline, 'Удалить',
              destructive: true),
        ],
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SourceTabAction.refresh:
        await widget.onRefreshSource(source);
      case _SourceTabAction.testAllRoutes:
        await widget.onTestAllRoutes(source);
      case _SourceTabAction.copyLink:
        await _copyLink(source);
      case _SourceTabAction.openInBrowser:
        await _openInBrowser(source);
      case _SourceTabAction.edit:
        await widget.onEdit(source);
      case _SourceTabAction.delete:
        await widget.onDelete(source);
      case _SourceTabAction.share:
        await _share(source);
      case _SourceTabAction.openCabinet:
        widget.onOpenCabinet(source);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final providers = widget.sources
        .where((source) => source.isProviderSource)
        .toList(growable: false);
    final regular = widget.sources
        .where((source) => !source.isProviderSource)
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
          for (final provider in providers) ...[
            const SizedBox(width: 4),
            Listener(
              onPointerDown: (event) {
                if (event.buttons == kSecondaryMouseButton) {
                  _showContextMenu(provider, event.position);
                }
              },
              child: _SourceTab(
                source: provider,
                selected: provider.id == widget.selectedId,
                onSelected: () => widget.onSelected(provider.id),
                onMenu: (position) => _showContextMenu(provider, position),
              ),
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
    this.dragHandle,
    this.onMenu,
  });

  final Subscription source;
  final bool selected;
  final VoidCallback onSelected;
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
                  Icons.rss_feed_outlined,
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
  const _SourceSummary({
    required this.source,
    required this.isMosaic,
    this.onOpenCabinet,
  });

  final Subscription source;
  final bool isMosaic;
  final VoidCallback? onOpenCabinet;

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
          if (onOpenCabinet != null) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Открыть кабинет подписки',
              onPressed: onOpenCabinet,
              icon: const Icon(Icons.account_balance_wallet_outlined),
              color: AtlasTheme.accent,
            ),
          ],
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
    required this.selectedId,
    required this.connectingId,
    required this.sort,
    required this.ascending,
    required this.onSort,
    required this.onSortMenu,
    required this.visibleColumns,
    required this.columnWidths,
    required this.onColumnMenu,
    required this.onResizeColumn,
    required this.activeLatencyTestGroupId,
    required this.onStopGroupLatencyTest,
    required this.onRouteMenu,
    required this.onPrimaryAction,
    required this.onConnect,
    required this.onTest,
    required this.onDelete,
  });

  final List<_RouteRow> rows;
  final String? activeId;
  final String? selectedId;
  final String? connectingId;
  final _RouteSort sort;
  final bool ascending;
  final ValueChanged<_RouteSort> onSort;
  final Future<void> Function(Offset) onSortMenu;
  final Map<_RouteColumn, bool> visibleColumns;
  final Map<_RouteColumn, double> columnWidths;
  final Future<void> Function(Offset) onColumnMenu;
  final void Function(_RouteColumn, double) onResizeColumn;
  final String? activeLatencyTestGroupId;
  final VoidCallback onStopGroupLatencyTest;
  final Future<void> Function(_RouteRow, Offset) onRouteMenu;
  final ValueChanged<_RouteRow> onPrimaryAction;
  final ValueChanged<_RouteRow> onConnect;
  final Future<void> Function(_RouteRow) onTest;
  final Future<void> Function(_RouteRow) onDelete;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 640) {
      return _MobileRouteList(
        rows: rows,
        activeId: activeId,
        connectingId: connectingId,
        onConnect: onConnect,
        onTest: onTest,
        onDelete: onDelete,
        activeLatencyTestGroupId: activeLatencyTestGroupId,
        onStopGroupLatencyTest: onStopGroupLatencyTest,
        onRouteMenu: onRouteMenu,
      );
    }
    final colors = ThemeColors.of(context);
    final preferredColumns = _RouteColumn.values
        .where((column) => visibleColumns[column] ?? false)
        .toList(growable: false);
    return Container(
      decoration: BoxDecoration(
        color: colors.bgCard,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout =
                _layoutForWidth(preferredColumns, constraints.maxWidth);
            final sortIndex =
                layout.columns.indexWhere((column) => _sortFor(column) == sort);
            return DataTable(
              showCheckboxColumn: false,
              horizontalMargin: 12,
              columnSpacing: 16,
              headingRowColor: WidgetStatePropertyAll(colors.bgElevated),
              dataRowMinHeight: 62,
              dataRowMaxHeight: 68,
              sortColumnIndex: sortIndex < 0 ? null : sortIndex,
              sortAscending: ascending,
              columns: layout.columns
                  .map((column) => _column(context, column, layout.widths))
                  .toList(),
              rows: rows
                  .map((row) =>
                      _row(context, row, layout.columns, layout.widths))
                  .toList(),
            );
          },
        ),
      ),
    );
  }

  _RouteTableLayout _layoutForWidth(
      List<_RouteColumn> preferred, double maxWidth) {
    final candidates = <_RouteColumn>[
      _RouteColumn.name,
      _RouteColumn.action,
      _RouteColumn.type,
      _RouteColumn.country,
      _RouteColumn.ping,
      _RouteColumn.traffic,
      _RouteColumn.jitter,
      _RouteColumn.loss,
      _RouteColumn.speed,
    ].where(preferred.contains).toList(growable: false);
    if (!candidates.contains(_RouteColumn.name)) {
      candidates.insert(0, _RouteColumn.name);
    }
    if (!candidates.contains(_RouteColumn.action)) {
      candidates.insert(1, _RouteColumn.action);
    }
    final widths = <_RouteColumn, double>{
      for (final column in candidates) column: _effectiveWidth(column),
    };
    final selected = <_RouteColumn>[];
    final available = (maxWidth - 24).clamp(220.0, double.infinity);
    double used = 0;
    for (final column in candidates) {
      final next = used + (selected.isEmpty ? 0 : 16) + widths[column]!;
      if (selected.isEmpty || next <= available) {
        selected.add(column);
        used = next;
      }
    }
    // A compact desktop table must always leave a clearly labelled route and
    // an explicit connect/settings affordance. User visibility preferences are
    // preserved; non-fitting secondary columns reappear on wider windows.
    if (!selected.contains(_RouteColumn.name)) {
      selected.insert(0, _RouteColumn.name);
    }
    if (!selected.contains(_RouteColumn.action)) {
      selected.add(_RouteColumn.action);
    }
    return _RouteTableLayout(columns: selected, widths: widths);
  }

  double _effectiveWidth(_RouteColumn column) {
    final preferred = columnWidths[column] ?? 120;
    return switch (column) {
      _RouteColumn.name => preferred.clamp(180, 320).toDouble(),
      _RouteColumn.action => 56,
      _ => preferred.clamp(72, 160).toDouble(),
    };
  }

  DataRow _row(BuildContext context, _RouteRow row, List<_RouteColumn> columns,
      Map<_RouteColumn, double> widths) {
    final connected = activeId == row.id || activeId == 'group:${row.id}';
    final connecting = connectingId == row.id;
    final selected = selectedId == row.id;
    return DataRow(
      selected: connected || selected,
      onSelectChanged:
          row.disabled || connecting ? null : (_) => onPrimaryAction(row),
      color: WidgetStateProperty.resolveWith((states) {
        if (connected) return AtlasTheme.success.withValues(alpha: .12);
        if (row.disabled) return AtlasTheme.error.withValues(alpha: .08);
        if (selected || states.contains(WidgetState.selected)) {
          return AtlasTheme.accent.withValues(alpha: .14);
        }
        if (states.contains(WidgetState.hovered)) {
          return AtlasTheme.accent.withValues(alpha: .06);
        }
        if (states.contains(WidgetState.pressed)) {
          return AtlasTheme.accent.withValues(alpha: .18);
        }
        return null;
      }),
      cells: columns
          .map((column) => DataCell(
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (event.buttons == kSecondaryMouseButton) {
                      onRouteMenu(row, event.position);
                    }
                  },
                  child: _cell(
                      context, row, column, connected, connecting, widths),
                ),
              ))
          .toList(growable: false),
    );
  }

  /// Ping cell with user-specified colour coding: green ≤150 ms, yellow
  /// ≤300 ms, red above, and a bold red "Недоступен" for failed probes.
  Widget _pingCell(BuildContext context, _RouteRow row) {
    final colors = ThemeColors.of(context);
    final width = _effectiveWidth(_RouteColumn.ping);
    if (row.ping == null) {
      return SizedBox(
          width: width,
          child: Text('—',
              maxLines: 1, style: TextStyle(color: colors.textSecondary)));
    }
    final pingValue = row.ping!;
    if (pingValue < 0) {
      return SizedBox(
        width: width,
        child: Text('Недоступен',
            maxLines: 1,
            style: TextStyle(
                color: AtlasTheme.error, fontWeight: FontWeight.w700)),
      );
    }
    final ping = pingValue;
    final color = ping <= 150
        ? AtlasTheme.success
        : ping <= 300
            ? AtlasTheme.warning
            : AtlasTheme.error;
    return SizedBox(
        width: width,
        child: Text('$ping мс',
            maxLines: 1,
            style: TextStyle(color: color, fontWeight: FontWeight.w700)));
  }

  Widget _cell(BuildContext context, _RouteRow row, _RouteColumn column,
      bool connected, bool connecting, Map<_RouteColumn, double> widths) {
    final colors = ThemeColors.of(context);
    final width = widths[column] ?? _effectiveWidth(column);
    final disabledColor = AtlasTheme.error;
    final muted = row.disabled ? disabledColor : colors.textSecondary;
    final primary = row.disabled ? disabledColor : colors.textPrimary;
    Widget text(String value, {bool strong = false}) => SizedBox(
          width: width,
          child: Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: strong ? primary : muted,
                fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
              )),
        );
    return switch (column) {
      _RouteColumn.type => SizedBox(
          width: width,
          child: Row(children: [
            Icon(row.icon, size: 18, color: muted),
            const SizedBox(width: 8),
            Expanded(
                child: Text(row.type,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted))),
          ]),
        ),
      _RouteColumn.name => SizedBox(
          width: width,
          child: Row(children: [
            Expanded(
                child: Text(row.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: primary, fontWeight: FontWeight.w700))),
            if (connecting)
              const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)))
            else if (connected)
              const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.check_circle_rounded,
                      color: AtlasTheme.success, size: 18)),
          ]),
        ),
      _RouteColumn.country => text(_countryLabel(row.country)),
      _RouteColumn.ping => _pingCell(context, row),
      _RouteColumn.jitter =>
        text(row.jitter == null ? '—' : '${row.jitter} мс'),
      _RouteColumn.loss =>
        text(row.loss == null ? '—' : '${row.loss!.toStringAsFixed(1)}%'),
      _RouteColumn.speed =>
        text(row.speed == null ? '—' : _formatSpeed(row.speed!)),
      _RouteColumn.traffic => text(row.traffic),
      _RouteColumn.action => SizedBox(
          width: width,
          child: IconButton(
            tooltip: connected ? 'Подключено' : 'Подключиться',
            onPressed: row.disabled || connecting ? null : () => onConnect(row),
            icon: Icon(
              connected
                  ? Icons.check_circle_outline_rounded
                  : Icons.play_circle_outline_rounded,
              color: connected ? AtlasTheme.success : AtlasTheme.accent,
            ),
          ),
        ),
    };
  }

  DataColumn _column(BuildContext context, _RouteColumn column,
      Map<_RouteColumn, double> widths) {
    final field = _sortFor(column);
    return DataColumn(
      numeric: _isNumeric(column),
      onSort: field == null ? null : (_, __) => onSort(field),
      label: _header(context, column, field, widths),
    );
  }

  Widget _header(BuildContext context, _RouteColumn column, _RouteSort? field,
      Map<_RouteColumn, double> widths) {
    final colors = ThemeColors.of(context);
    final width = widths[column] ?? _effectiveWidth(column);
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) {
          onColumnMenu(event.position);
        }
      },
      child: GestureDetector(
        onHorizontalDragUpdate: column == _RouteColumn.action
            ? null
            : (details) => onResizeColumn(column, details.delta.dx),
        child: SizedBox(
          width: width,
          child: Row(children: [
            Expanded(
              child: Text(_label(column),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: colors.textPrimary, fontWeight: FontWeight.w700)),
            ),
            if (field != null && sort == field)
              Icon(
                  ascending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 14,
                  color: AtlasTheme.accent),
            if (column != _RouteColumn.action)
              Icon(Icons.drag_handle_rounded,
                  size: 14, color: colors.textMuted),
            if (column == _RouteColumn.action)
              IconButton(
                tooltip: 'Настроить колонки',
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                padding: EdgeInsets.zero,
                onPressed: () {
                  final renderBox = context.findRenderObject() as RenderBox;
                  onColumnMenu(renderBox
                      .localToGlobal(renderBox.size.center(Offset.zero)));
                },
                icon: Icon(Icons.view_column_outlined,
                    size: 17, color: colors.textMuted),
              ),
          ]),
        ),
      ),
    );
  }

  String _label(_RouteColumn column) => switch (column) {
        _RouteColumn.type => 'Тип',
        _RouteColumn.name => 'Название',
        _RouteColumn.country => 'Страна',
        _RouteColumn.ping => 'Задержка',
        _RouteColumn.jitter => 'Джиттер',
        _RouteColumn.loss => 'Потери',
        _RouteColumn.speed => 'Скорость',
        _RouteColumn.traffic => 'Трафик',
        _RouteColumn.action => '',
      };

  _RouteSort? _sortFor(_RouteColumn column) => switch (column) {
        _RouteColumn.type => _RouteSort.type,
        _RouteColumn.name => _RouteSort.name,
        _RouteColumn.country => null,
        _RouteColumn.ping => _RouteSort.ping,
        _RouteColumn.jitter => _RouteSort.jitter,
        _RouteColumn.loss => _RouteSort.loss,
        _RouteColumn.speed => _RouteSort.speed,
        _RouteColumn.traffic => _RouteSort.traffic,
        _RouteColumn.action => null,
      };

  bool _isNumeric(_RouteColumn column) => switch (column) {
        _RouteColumn.ping ||
        _RouteColumn.jitter ||
        _RouteColumn.loss ||
        _RouteColumn.speed ||
        _RouteColumn.traffic =>
          true,
        _ => false,
      };

  String _formatSpeed(int bps) {
    if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(1)} Мбит/с';
    if (bps >= 1000) return '${(bps / 1000).toStringAsFixed(0)} Кбит/с';
    return '$bps бит/с';
  }

  String _countryLabel(String value) {
    final country = value.trim();
    if (country.isEmpty) return '—';
    final code = country.toUpperCase();
    if (RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
      final flag = String.fromCharCodes(
        code.codeUnits.map((unit) => 0x1F1E6 + unit - 65),
      );
      return '$flag $code';
    }
    return country;
  }
}

class _RouteTableLayout {
  const _RouteTableLayout({required this.columns, required this.widths});

  final List<_RouteColumn> columns;
  final Map<_RouteColumn, double> widths;
}

class _MobileRouteList extends StatelessWidget {
  const _MobileRouteList({
    required this.rows,
    required this.activeId,
    required this.connectingId,
    required this.onConnect,
    required this.onTest,
    required this.onDelete,
    required this.activeLatencyTestGroupId,
    required this.onStopGroupLatencyTest,
    required this.onRouteMenu,
  });

  final List<_RouteRow> rows;
  final String? activeId;
  final String? connectingId;
  final ValueChanged<_RouteRow> onConnect;
  final Future<void> Function(_RouteRow) onTest;
  final Future<void> Function(_RouteRow) onDelete;
  final String? activeLatencyTestGroupId;
  final VoidCallback onStopGroupLatencyTest;
  final Future<void> Function(_RouteRow, Offset) onRouteMenu;

  Future<void> _actions(BuildContext context, _RouteRow row) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: const Text('Подключиться'),
              enabled: !row.disabled,
              onTap: row.disabled
                  ? null
                  : () {
                      Navigator.of(sheetContext).pop();
                      onConnect(row);
                    },
            ),
            if (row.isGroup && activeLatencyTestGroupId == row.id)
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('Остановить тест задержки'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onStopGroupLatencyTest();
                },
              )
            else if (row.canTest)
              ListTile(
                leading: const Icon(Icons.network_ping_rounded),
                title: Text(
                    row.isGroup ? 'Тест задержки группы' : 'Проверить маршрут'),
                subtitle: Text(activeLatencyTestGroupId == null
                    ? (row.isGroup
                        ? 'Проверить группу без показа нод пула'
                        : 'Измерить доступность выбранного сервера')
                    : 'Сначала завершите активный тест'),
                enabled: activeLatencyTestGroupId == null,
                onTap: activeLatencyTestGroupId == null
                    ? () async {
                        Navigator.of(sheetContext).pop();
                        await onTest(row);
                      }
                    : null,
              ),
            if (row.canDelete)
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: ThemeColors.of(context).danger),
                title: Text('Удалить с устройства',
                    style: TextStyle(color: ThemeColors.of(context).danger)),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await onDelete(row);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.bgCard,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: colors.border),
        itemBuilder: (context, index) {
          final row = rows[index];
          final connected = activeId == row.id || activeId == 'group:${row.id}';
          final connecting = connectingId == row.id;
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            enabled: !row.disabled && !connecting,
            leading: Icon(row.icon,
                color: row.disabled ? colors.textMuted : colors.textSecondary),
            title: Text(row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: row.disabled ? colors.textMuted : colors.textPrimary,
                  fontWeight: FontWeight.w700,
                )),
            subtitle: Text(
              '${row.type} · ${row.ping == null ? 'Не проверен' : '${row.ping} мс'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textSecondary),
            ),
            trailing: connecting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (connected)
                      const Icon(Icons.check_circle_rounded,
                          color: AtlasTheme.success, size: 20),
                    IconButton(
                      tooltip: 'Действия маршрута',
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: () => _actions(context, row),
                    ),
                  ]),
            onTap: row.disabled || connecting ? null : () => onConnect(row),
            onLongPress: () => _actions(context, row),
          );
        },
      ),
    );
  }
}

// Group names are supplied by the provider manifest; the client only knows
// the generic Smart Group route type.
String _groupTitle(ManifestGroup group) =>
    group.title.isEmpty ? group.id : group.title;

IconData _groupIcon(String icon) {
  return switch (icon) {
    'lightning' => Icons.bolt_rounded,
    'speed' => Icons.speed_rounded,
    'shield' => Icons.shield_outlined,
    'wrench' => Icons.build_rounded,
    'hourglass' => Icons.hourglass_top_rounded,
    'flag_de' || 'flag_ca' || 'flag_us' => Icons.flag_outlined,
    _ => Icons.route_outlined,
  };
}

/// Immutable progress snapshot for the "test all routes" sweep dialog.
class ProgressValue {
  const ProgressValue({required this.done, required this.total});

  final int done;
  final int total;
}
