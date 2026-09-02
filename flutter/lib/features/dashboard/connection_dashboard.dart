import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/api/daemon_api_base.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/platform/app_platform.dart';
import '../../core/services/elevation_prompt.dart';
import '../../core/services/smart_group_selector.dart';
import '../../core/services/smart_group_runtime_controller.dart';
import '../../core/services/ui_preferences_service.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/atlas_theme.dart';
import 'dashboard_facts.dart';

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
  late final AnimationController _pulse;
  final SmartGroupSelector _smartGroupSelector = SmartGroupSelector();
  final UiPreferencesService _uiPrefs = UiPreferencesService();
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    // Stop first so no tick can attempt to recreate/use a ticker while Flutter
    // is unmounting this state. Calling _pulse.stop() is safe even if the
    // controller was never attached in a test harness.
    _pulse.stop();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final status = ref.watch(vpnStatusProvider).valueOrNull ?? VpnStatus();
    final sharedSubId = ref.watch(selectedSubscriptionIdProvider);
    final sharedRouteId = ref.watch(selectedRouteIdProvider);
    // Dashboard and Routes must start from the same persisted sources. A
    // synthetic global Mosaic row made the Dashboard show a different number
    // of subscriptions and used unscoped group IDs that the daemon cannot
    // connect on multi-subscription installs.
    final subscriptions =
        ref.watch(subscriptionsProvider).valueOrNull ?? <Subscription>[];
    final selectedSubscription = subscriptions.firstWhere(
      (subscription) => subscription.id == sharedSubId,
      orElse: () =>
          subscriptions.isNotEmpty ? subscriptions.first : Subscription(),
    );
    final isMosaicSource = _isMosaicSubscription(selectedSubscription);
    final selectedManifest = isMosaicSource &&
            selectedSubscription.id.isNotEmpty
        ? ref.watch(
            providerManifestForSubscriptionProvider(selectedSubscription.id))
        : null;
    final manifestGroups =
        (selectedManifest?.valueOrNull?.routes ?? <ManifestGroup>[])
            .where((group) => group.category != 'raw')
            .toList();
    final userServers = ref.watch(serversProvider).valueOrNull ?? <Server>[];
    final List<_RouteChoice> groups = isMosaicSource
        ? manifestGroups.map<_RouteChoice>(_manifestAsRouteChoice).toList()
        : userServers
            .where((server) => server.subscriptionID == selectedSubscription.id)
            .map<_RouteChoice>(_serverAsRouteChoice)
            .toList();

    if (sharedSubId != selectedSubscription.id &&
        selectedSubscription.id.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(selectedSubscriptionIdProvider.notifier)
              .set(selectedSubscription.id);
        }
      });
    }
    if (groups.isNotEmpty &&
        !groups.any((group) => group.id == sharedRouteId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && groups.isNotEmpty) {
          // A connected route always wins the initial selection so the
          // dashboard reflects the route actually chosen on the Routes screen
          // instead of defaulting to the first row.
          final status = ref.read(vpnStatusProvider).valueOrNull;
          final activeId = status?.activeGroupId.isNotEmpty == true
              ? status!.activeGroupId
              : status?.server?.id;
          final connected =
              activeId != null ? groups.where((g) => g.id == activeId) : null;
          final firstEnabled = groups.where((group) => !group.disabled);
          final targetId = connected?.isNotEmpty == true
              ? connected!.first.id
              : firstEnabled.isNotEmpty
                  ? firstEnabled.first.id
                  : groups.first.id;
          ref.read(selectedRouteIdProvider.notifier).set(targetId);
        }
      });
    }

    return Scaffold(
      backgroundColor: c.bgBase,
      body: SafeArea(
        child: groups.isEmpty
            ? _NoDashboardRoutes(
                subscriptions: subscriptions,
                selectedSubscription: selectedSubscription,
                onSubscriptionChanged: _selectSubscription,
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final selected = groups.firstWhere(
                    (group) => group.id == sharedRouteId,
                    orElse: () => groups.first,
                  );
                  final isDesktop = constraints.maxWidth >= 760;
                  return isDesktop
                      ? _buildDesktopLayout(context, c, status, subscriptions,
                          selectedSubscription, groups, selected)
                      : _buildMobileLayout(context, c, status, subscriptions,
                          selectedSubscription, groups, selected);
                },
              ),
      ),
    );
  }

  bool _isMosaicSubscription(Subscription subscription) {
    if (subscription.id == 'mosaic-direct') return true;
    final uri = Uri.tryParse(subscription.url.trim());
    return uri != null &&
        uri.isScheme('https') &&
        uri.host.toLowerCase() == 'sub.zxc1x1.ru' &&
        uri.pathSegments.isNotEmpty;
  }

  Widget _buildMobileLayout(
    BuildContext context,
    ThemeColors c,
    VpnStatus status,
    List<Subscription> subscriptions,
    Subscription selectedSubscription,
    List<_RouteChoice> groups,
    _RouteChoice selected,
  ) {
    final s = AppStrings.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DashboardHeader(
                onRefresh: () => ref.invalidate(vpnStatusProvider)),
            const SizedBox(height: 10),
            Expanded(
              child: _ConnectionHeroCard(
                status: status,
                animation: _pulse,
                routeTitle: selected.title,
                routeSubtitle: selected.subtitle.isEmpty
                    ? s.t('route_picker_hint')
                    : selected.subtitle,
                onPickRoute: groups.length > 1
                    ? () => _pickGroup(context, groups, selected)
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            if (groups.length > 1) ...[
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: groups.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    final active = group.id == selected.id;
                    return Semantics(
                      button: true,
                      label: 'Выбрать маршрут ${group.title}',
                      child: Material(
                        color: group.disabled
                            ? AtlasTheme.error.withValues(alpha: .10)
                            : active
                                ? AtlasTheme.accent
                                : c.bgCard,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: group.disabled
                              ? null
                              : () {
                                  ref
                                      .read(selectedRouteIdProvider.notifier)
                                      .set(group.id);
                                },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 13),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: group.disabled
                                    ? AtlasTheme.error
                                    : active
                                        ? AtlasTheme.accent
                                        : c.border,
                              ),
                            ),
                            alignment: Alignment.center,
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(_chipIcon(group.icon),
                                  size: 15,
                                  color: group.disabled
                                      ? AtlasTheme.error
                                      : active
                                          ? AtlasTheme.onAccent
                                          : c.textSecondary),
                              const SizedBox(width: 6),
                              Text(group.title,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: group.disabled
                                        ? AtlasTheme.error
                                        : active
                                            ? AtlasTheme.onAccent
                                            : c.textPrimary,
                                  )),
                            ]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
            _connectionButton(c, status, selected, expand: true),
            const SizedBox(height: 10),
            _ProtectionRow(status: status),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopLayout(
    BuildContext context,
    ThemeColors c,
    VpnStatus status,
    List<Subscription> subscriptions,
    Subscription selectedSubscription,
    List<_RouteChoice> groups,
    _RouteChoice selected,
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
                                _SubscriptionSelector(
                                  subscriptions: subscriptions,
                                  selected: selectedSubscription,
                                  onChanged: _selectSubscription,
                                  compact: true,
                                ),
                                const SizedBox(height: 18),
                                _SectionTitle(s.t('route_picker')),
                                const SizedBox(height: 12),
                                _RouteSelector(
                                  group: selected,
                                  onTap: () =>
                                      _pickGroup(context, groups, selected),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        DashboardFacts(status: status, routes: groups),
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
    _RouteChoice selected, {
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

  Future<void> _toggle(VpnStatus status, _RouteChoice selected) async {
    final api = ref.read(daemonApiProvider);
    try {
      setState(() => _busy = true);
      if (selected.disabled) {
        final disabledLabel = selected.disabledReason.isEmpty
            ? 'Маршрут временно отключён.'
            : selected.disabledReason;
        _notice(disabledLabel, error: true);
        return;
      }
      if (status.isConnected || status.isConnecting) {
        final wasSameRoute = _sameActiveRoute(status, selected);
        SmartGroupRuntimeController.instance.stop();
        await api.disconnect();
        // The daemon stop is asynchronous. Do not race the next connect with
        // the old runtime; wait for the authoritative state transition.
        await _waitForDisconnected(api);
        if (wasSameRoute) {
          ref.invalidate(vpnStatusProvider);
          return;
        }
      }
      if (selected.disabled) {
        final disabledLabel = selected.disabledReason.isEmpty
            ? 'Маршрут временно отключён.'
            : selected.disabledReason;
        _notice(disabledLabel, error: true);
      } else if (AppPlatform.isAndroid) {
        await _toggleAndroidRuntime(selected);
        await _uiPrefs.writeLastConnectedRouteId(selected.id);
        if (_selectedSubscriptionId(ref) case final subId?
            when subId.isNotEmpty) {
          await _uiPrefs.writeLastConnectedSubscriptionId(subId);
        }
      } else if (selected.isSmartGroup && selected.manifestGroup != null) {
        final group = selected.manifestGroup!;
        final selection = await _smartGroupSelector.connect(api, group);
        SmartGroupRuntimeController.instance.start(
          api: api,
          selector: _smartGroupSelector,
          group: group,
          candidateId: selection.candidateId,
        );
        await _uiPrefs.writeLastConnectedRouteId(selected.id);
        if (_selectedSubscriptionId(ref) case final subId?
            when subId.isNotEmpty) {
          await _uiPrefs.writeLastConnectedSubscriptionId(subId);
        }
      } else if (selected.isGroup) {
        await api.connectGroup(selected.id);
        await _uiPrefs.writeLastConnectedRouteId(selected.id);
        if (_selectedSubscriptionId(ref) case final subId?
            when subId.isNotEmpty) {
          await _uiPrefs.writeLastConnectedSubscriptionId(subId);
        }
      } else {
        await api.connect(selected.id);
        await _uiPrefs.writeLastConnectedRouteId(selected.id);
        if (_selectedSubscriptionId(ref) case final subId?
            when subId.isNotEmpty) {
          await _uiPrefs.writeLastConnectedSubscriptionId(subId);
        }
      }
      ref.invalidate(vpnStatusProvider);
    } catch (error) {
      // TUN without an administrator token is fully recoverable: offer the
      // UAC restart instead of a dead-end error notice (Throne behaviour).
      if (isElevationRequiredError(error) && mounted) {
        final accepted = await handleElevationRequired(context);
        if (!accepted) {
          _notice(
            'Подключение в режиме TUN требует прав администратора.',
            error: true,
          );
        }
        return;
      }
      if (mounted) {
        final detail = _connectionErrorDetail(error);
        _notice(
          '${AppStrings.of(context).t('connection_failed')} $detail',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleAndroidRuntime(_RouteChoice selected) async {
    // The shared toggle has already stopped an active runtime and waited for
    // disconnected, so Android must only perform the new connect here.
    final api = ref.read(daemonApiProvider);
    if (selected.isGroup) {
      await api.connectGroup(selected.id);
    } else {
      await api.connect(selected.id);
    }
  }

  bool _sameActiveRoute(VpnStatus status, _RouteChoice selected) {
    final active = status.activeGroupId.isNotEmpty
        ? status.activeGroupId
        : status.server?.id;
    return active == selected.id;
  }

  Future<void> _waitForDisconnected(DaemonApiBase api) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final current = await api.getStatus();
      if (!current.isConnected && !current.isConnecting) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw TimeoutException('VPN runtime не подтвердил отключение.');
  }

  String _connectionErrorDetail(Object error) {
    if (error is StateError && error.message.isNotEmpty) {
      return error.message;
    }
    final raw = error.toString();
    if (raw.contains('permission_required') || raw.contains('разрешение VPN')) {
      return 'Разрешите создание VPN-подключения в Android и повторите попытку.';
    }
    if (raw.contains('sing-box') || raw.contains('runtime')) {
      return 'Нативный VPN runtime не подтвердил запуск. Откройте журнал подключения и повторите попытку.';
    }
    return AppStrings.of(context).t('connection_try_other_route');
  }

  String? _selectedSubscriptionId(WidgetRef ref) =>
      ref.read(selectedSubscriptionIdProvider);

  Future<void> _pickGroup(BuildContext context, List<_RouteChoice> groups,
      _RouteChoice current) async {
    final selected = await showDialog<_RouteChoice>(
      context: context,
      builder: (_) => _AtlasChoiceDialog<_RouteChoice>(
        eyebrow: 'Маршруты',
        title: AppStrings.of(context).t('route_picker'),
        hint: AppStrings.of(context).t('route_picker_hint'),
        choices: groups,
        selectedId: current.id,
        titleOf: (route) => route.title,
        subtitleOf: (route) => route.disabled && route.disabledReason.isNotEmpty
            ? route.disabledReason
            : route.subtitle,
        iconOf: (route) => _groupIcon(route.icon),
        enabledOf: (route) => !route.disabled,
      ),
    );
    if (selected != null && mounted) {
      ref.read(selectedRouteIdProvider.notifier).set(selected.id);
    }
  }

  void _selectSubscription(Subscription subscription) {
    if (subscription.id == ref.read(selectedSubscriptionIdProvider)) return;
    ref.read(selectedSubscriptionIdProvider.notifier).set(subscription.id);
    ref.read(selectedRouteIdProvider.notifier).set(null);
  }

  _RouteChoice _manifestAsRouteChoice(ManifestGroup group) {
    final strings = AppStrings.of(context);
    final description = _localizedGroupDescription(context, group);
    return _RouteChoice(
      id: group.id,
      title: _localizedGroupTitle(context, group),
      subtitle: [
        group.routeType == 'direct'
            ? [
                if (group.protocol.isNotEmpty) group.protocol.toUpperCase(),
                if (group.countryCode.isNotEmpty) group.countryCode,
              ].join(' · ')
            : strings.t('smart_group'),
        if (description.isNotEmpty) description,
      ].join(' · '),
      icon: group.icon,
      isGroup: true,
      isSmartGroup: group.routeType == 'smart_group',
      disabled: group.disabled,
      disabledReason: group.disabledReason,
      manifestGroup: group,
    );
  }

  _RouteChoice _serverAsRouteChoice(Server server) => _RouteChoice(
        id: server.id,
        importUri: server.importUri,
        title: server.name.isEmpty
            ? AppStrings.of(context).t('unnamed_server')
            : server.name,
        subtitle: server.hasLatency
            ? '${server.protocol.displayName} · ${server.lastTestMS} мс'
            : server.protocol.displayName,
        icon: 'node',
        isGroup: false,
        isSmartGroup: false,
      );

  void _notice(String value, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value),
          backgroundColor: error ? ThemeColors.of(context).danger : null));
}

class _RouteChoice {
  const _RouteChoice({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isGroup,
    required this.isSmartGroup,
    this.disabled = false,
    this.disabledReason = '',
    this.manifestGroup,
    this.importUri = '',
  });

  final String id;
  final String title;
  final String subtitle;
  final String icon;
  final bool isGroup;
  final bool isSmartGroup;
  final bool disabled;
  final String disabledReason;
  final ManifestGroup? manifestGroup;
  final String importUri;
}

class _SubscriptionSelector extends StatelessWidget {
  const _SubscriptionSelector({
    required this.subscriptions,
    required this.selected,
    required this.onChanged,
    this.compact = false,
  });

  final List<Subscription> subscriptions;
  final Subscription selected;
  final ValueChanged<Subscription> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    if (subscriptions.isEmpty) return const SizedBox.shrink();
    final label = compact ? s.t('subscriptions') : s.t('route_source');
    final title = selected.name.isEmpty
        ? AppStrings.of(context).t('unnamed_subscription')
        : selected.name;
    final subtitle = selected.isProviderSource
        ? 'Профиль MosaicVPN · ${selected.serverCount} маршрутов'
        : selected.serverCount == 1
            ? '1 маршрут'
            : '${selected.serverCount} маршрутов';
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            final picked = await showDialog<Subscription>(
              context: context,
              builder: (_) => _AtlasChoiceDialog<Subscription>(
                eyebrow: label,
                title: 'Выберите подписку',
                hint:
                    'Маршруты и состояние подключения меняются только внутри выбранного источника.',
                choices: subscriptions,
                selectedId: selected.id,
                titleOf: (subscription) => subscription.name.isEmpty
                    ? AppStrings.of(context).t('unnamed_subscription')
                    : subscription.name,
                subtitleOf: (subscription) => subscription.isProviderSource
                    ? 'MosaicVPN · ${subscription.serverCount} маршрутов'
                    : subscription.serverCount == 1
                        ? '1 маршрут'
                        : '${subscription.serverCount} маршрутов',
                iconOf: (_) => const Icon(Icons.layers_outlined),
              ),
            );
            if (picked != null) onChanged(picked);
          },
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                14, compact ? 10 : 12, 12, compact ? 10 : 12),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AtlasTheme.accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.layers_outlined,
                    size: 19, color: AtlasTheme.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: TextStyle(
                            color: c.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.textPrimary, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textMuted, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.unfold_more_rounded, color: c.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AtlasChoiceDialog<T> extends StatelessWidget {
  const _AtlasChoiceDialog({
    required this.eyebrow,
    required this.title,
    required this.hint,
    required this.choices,
    required this.selectedId,
    required this.titleOf,
    required this.subtitleOf,
    required this.iconOf,
    this.enabledOf,
  });

  final String eyebrow;
  final String title;
  final String hint;
  final List<T> choices;
  final String selectedId;
  final String Function(T choice) titleOf;
  final String Function(T choice) subtitleOf;
  final Widget Function(T choice) iconOf;
  final bool Function(T choice)? enabledOf;

  String _idOf(T choice) {
    if (choice is Subscription) return choice.id;
    if (choice is _RouteChoice) return choice.id;
    return titleOf(choice);
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.bgElevated,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: c.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 14, 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(eyebrow.toUpperCase(),
                            style: TextStyle(
                                color: AtlasTheme.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1)),
                        const SizedBox(height: 5),
                        Text(title,
                            style: TextStyle(
                                fontFamily: AtlasTheme.serifFamily,
                                color: c.textPrimary,
                                fontSize: 24,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 5),
                        Text(hint,
                            style: TextStyle(
                                color: c.textSecondary, fontSize: 12)),
                      ]),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: c.textMuted),
                ),
              ]),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: choices.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    final active = _idOf(choice) == selectedId;
                    final enabled = enabledOf?.call(choice) ?? true;
                    return Material(
                      color: active
                          ? AtlasTheme.accent.withValues(alpha: .13)
                          : c.bgCard,
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: enabled
                            ? () => Navigator.of(context).pop(choice)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: active ? AtlasTheme.accent : c.border,
                            ),
                          ),
                          child: Row(children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color:
                                    (active ? AtlasTheme.accent : c.textMuted)
                                        .withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: IconTheme(
                                data: IconThemeData(
                                    color: active
                                        ? AtlasTheme.accent
                                        : c.textSecondary),
                                child: Center(child: iconOf(choice)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(titleOf(choice),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: enabled
                                                ? c.textPrimary
                                                : c.textMuted,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 3),
                                    Text(subtitleOf(choice),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: c.textMuted, fontSize: 12)),
                                  ]),
                            ),
                            const SizedBox(width: 10),
                            Icon(
                                active
                                    ? Icons.check_circle_rounded
                                    : Icons.chevron_right_rounded,
                                color:
                                    active ? AtlasTheme.accent : c.textMuted),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NoDashboardRoutes extends StatelessWidget {
  const _NoDashboardRoutes({
    required this.subscriptions,
    required this.selectedSubscription,
    required this.onSubscriptionChanged,
  });

  final List<Subscription> subscriptions;
  final Subscription selectedSubscription;
  final ValueChanged<Subscription> onSubscriptionChanged;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SubscriptionSelector(
                subscriptions: subscriptions,
                selected: selectedSubscription,
                onChanged: onSubscriptionChanged,
              ),
              const SizedBox(height: 24),
              Icon(Icons.route_outlined, size: 48, color: c.textMuted),
              const SizedBox(height: 12),
              Text(AppStrings.of(context).t('no_routes_available'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                AppStrings.of(context).t('no_routes_hint'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
          tooltip: s.t('refresh_status'),
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
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bgElevated.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border.withValues(alpha: .75)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
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

/// The dashboard's main surface: a large status ring with the connected
/// route, a device→shield→globe mini-diagram and the primary action. It is
/// deliberately the only tall element so everything fits without scrolling.
class _ConnectionHeroCard extends StatelessWidget {
  final VpnStatus status;
  final Animation<double> animation;
  final String routeTitle;
  final String routeSubtitle;
  final VoidCallback? onPickRoute;

  const _ConnectionHeroCard({
    required this.status,
    required this.animation,
    required this.routeTitle,
    required this.routeSubtitle,
    this.onPickRoute,
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
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: c.bgCard,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: tint.withValues(alpha: .35)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _TunnelDiagramPainter(
                  progress: animation.value,
                  color: tint,
                  active: connected || connecting,
                ),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 148,
                  height: 148,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 148,
                        height: 148,
                        child: CustomPaint(
                          painter: _StatusRingPainter(
                            progress: animation.value,
                            color: tint,
                            active: connected || connecting,
                          ),
                        ),
                      ),
                      Icon(
                        connected
                            ? Icons.lock_outline_rounded
                            : connecting
                                ? Icons.route_outlined
                                : Icons.power_settings_new_rounded,
                        color: tint,
                        size: 46,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(title,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 22,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(connected || connecting ? routeTitle : routeSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5)),
                if (connected && (status.latencyMS > 0)) ...[
                  const SizedBox(height: 2),
                  Text('${status.latencyMS} мс',
                      style: TextStyle(color: tint, fontSize: 11.5)),
                ],
                if (onPickRoute != null && !connecting) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: onPickRoute,
                    icon: Icon(Icons.tune_rounded,
                        size: 16, color: AtlasTheme.accent),
                    label: Text(s.t('route_picker'),
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AtlasTheme.accent)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Device → tunnel shield → globe diagram. When connected, animated packets
/// travel along the path; when disconnected the same path renders dimmed.
class _TunnelDiagramPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool active;
  _TunnelDiagramPainter({
    required this.progress,
    required this.color,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final startY = Offset(size.width * .12, size.height * .78);
    final shieldY = Offset(size.width * .5, size.height * .30);
    final endY = Offset(size.width * .88, size.height * .78);
    final path = Path()
      ..moveTo(startY.dx, startY.dy)
      ..quadraticBezierTo(shieldY.dx, shieldY.dy - 40, endY.dx, endY.dy);
    // Tunnel body
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: active ? .30 : .12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // Endpoints
    final nodePaint = Paint()..color = color.withValues(alpha: .55);
    canvas.drawCircle(startY, 5, nodePaint);
    canvas.drawCircle(endY, 5, nodePaint);
    canvas.drawCircle(shieldY, 6, Paint()..color = color.withValues(alpha: .8));
    // Travelling packets while active
    if (!active) return;
    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1;
      final metric = path.computeMetrics().first;
      final point = metric.getTangentForOffset(metric.length * phase)!.position;
      canvas.drawCircle(
          point, 3, Paint()..color = color.withValues(alpha: (1 - phase) * .9));
    }
  }

  @override
  bool shouldRepaint(covariant _TunnelDiagramPainter old) =>
      old.progress != progress || old.color != color || old.active != active;
}

/// Expanding pulse ring around the hero status icon.
class _StatusRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool active;
  _StatusRingPainter({
    required this.progress,
    required this.color,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final base = Paint()
      ..color = color.withValues(alpha: active ? .75 : .35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, size.width / 2 - 6, base);
    if (!active) return;
    for (var i = 0; i < 2; i++) {
      final phase = (progress + i / 2) % 1;
      final radius = (size.width / 2 - 6) + phase * 16;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: (1 - phase) * .28)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StatusRingPainter old) =>
      old.progress != progress || old.color != color || old.active != active;
}

/// Expanding pulse ring behind the desktop `_ConnectionVisual` icon.
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

IconData _chipIcon(String raw) => switch (raw) {
      'lightning' => Icons.bolt_rounded,
      'speed' => Icons.speed_rounded,
      'shield' => Icons.shield_outlined,
      'node' => Icons.dns_outlined,
      _ => Icons.public_rounded,
    };

class _RouteSelector extends StatelessWidget {
  final _RouteChoice group;
  final VoidCallback onTap;
  const _RouteSelector({required this.group, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return Material(
      color: group.disabled ? c.bgBase : c.bgCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: group.disabled ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: group.disabled
                  ? c.border
                  : AtlasTheme.accent.withValues(alpha: .38),
            ),
          ),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AtlasTheme.accent.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(child: _groupIcon(group.icon)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ТЕКУЩИЙ МАРШРУТ',
                        style: TextStyle(
                            color: c.textMuted,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                            letterSpacing: .9)),
                    const SizedBox(height: 3),
                    Text(group.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: group.disabled ? c.textMuted : c.textPrimary,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                        group.subtitle.isEmpty
                            ? s.t('route_picker_hint')
                            : group.disabled && group.disabledReason.isNotEmpty
                                ? group.disabledReason
                                : group.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textMuted, fontSize: 12)),
                  ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: c.bgElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Выбрать',
                    style: TextStyle(
                        color: AtlasTheme.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 3),
                Icon(Icons.tune_rounded, color: AtlasTheme.accent, size: 15),
              ]),
            ),
          ]),
        ),
      ),
    );
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

// Smart groups are defined by the provider manifest. The generic client
// deliberately does not know Mosaic-specific IDs, geographies, or policies.
String _localizedGroupTitle(BuildContext context, ManifestGroup group) =>
    group.title.isEmpty ? group.id : group.title;

String _localizedGroupDescription(BuildContext context, ManifestGroup group) =>
    group.description.isEmpty ? group.badge : group.description;

Widget _groupIcon(String raw) {
  final icon = switch (raw) {
    'lightning' => Icons.bolt_rounded,
    'speed' => Icons.speed_rounded,
    'shield' => Icons.shield_outlined,
    'wrench' => Icons.build_rounded,
    'hourglass' => Icons.hourglass_top_rounded,
    'flag_de' => Icons.flag_outlined,
    'flag_us' => Icons.flag_outlined,
    'flag_ca' => Icons.flag_outlined,
    'node' => Icons.dns_outlined,
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
