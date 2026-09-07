import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/subscription.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/services/scale_proof_prober.dart';
import '../../core/services/ui_preferences_service.dart';
import '../../core/theme/atlas_theme.dart';
import '../../shared/widgets/atlas_widgets.dart';

class AtlasRouteItem {
  final String id;
  final String title;
  final String subtitle;
  final String icon;
  final bool disabled;
  final String disabledReason;
  final String? shareUri;

  const AtlasRouteItem({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.icon = '',
    this.disabled = false,
    this.disabledReason = '',
    this.shareUri,
  });
}

class AtlasRoutePickerSheet extends ConsumerStatefulWidget {
  final List<AtlasRouteItem> routes;
  final String? selectedId;
  final ValueChanged<AtlasRouteItem> onSelected;

  const AtlasRoutePickerSheet({
    super.key,
    required this.routes,
    required this.selectedId,
    required this.onSelected,
  });

  static Future<AtlasRouteItem?> show(
    BuildContext context, {
    required List<AtlasRouteItem> routes,
    required String? selectedId,
  }) {
    return showModalBottomSheet<AtlasRouteItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AtlasRoutePickerSheet(
        routes: routes,
        selectedId: selectedId,
        onSelected: (item) => Navigator.of(context).pop(item),
      ),
    );
  }

  @override
  ConsumerState<AtlasRoutePickerSheet> createState() =>
      _AtlasRoutePickerSheetState();
}

class _AtlasRoutePickerSheetState extends ConsumerState<AtlasRoutePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, int?> _latencies = {};
  final Set<String> _probingIds = {};
  String _filter = '';
  bool _isFindingFastest = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _filter = _searchController.text.trim().toLowerCase());
    });
    _probeVisibleInitial();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _probeVisibleInitial() {
    final targets = widget.routes.take(15).toList();
    for (final item in targets) {
      if (item.disabled) continue;
      _probeRoute(item);
    }
  }

  Future<void> _probeRoute(AtlasRouteItem item) async {
    if (_probingIds.contains(item.id) || _latencies.containsKey(item.id)) return;
    if (item.shareUri == null || item.shareUri!.isEmpty) return;
    final ep = _parseEndpoint(item.shareUri!);
    if (ep == null) return;

    setState(() => _probingIds.add(item.id));
    final target = ProbeTarget(id: item.id, host: ep.host, port: ep.port);
    final latency = await ScaleProofProber.instance.probeSingle(target);
    if (mounted) {
      setState(() {
        _probingIds.remove(item.id);
        _latencies[item.id] = latency.latencyMs;
      });
    }
  }

  ({String host, int port})? _parseEndpoint(String uriString) {
    try {
      final uri = Uri.parse(uriString);
      if (uri.host.isNotEmpty && uri.port > 0) {
        return (host: uri.host, port: uri.port);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _findFastestServer() async {
    if (_isFindingFastest) return;
    setState(() => _isFindingFastest = true);

    final targets = <ProbeTarget>[];
    for (final r in widget.routes) {
      if (r.disabled || r.shareUri == null) continue;
      final ep = _parseEndpoint(r.shareUri!);
      if (ep != null) {
        targets.add(ProbeTarget(id: r.id, host: ep.host, port: ep.port));
      }
    }

    if (targets.isEmpty) {
      setState(() => _isFindingFastest = false);
      return;
    }

    final fastest = await ScaleProofProber.instance.findFastest(
      targets,
      maxBatches: 3,
      batchSize: 10,
    );

    if (mounted && fastest != null) {
      final best = widget.routes.firstWhere(
        (r) => r.id == fastest.id,
        orElse: () => widget.routes.first,
      );
      setState(() {
        _isFindingFastest = false;
        _latencies[fastest.id] = fastest.latencyMs;
      });
      widget.onSelected(best);
    } else if (mounted) {
      setState(() => _isFindingFastest = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final autoFailover = ref.watch(autoFailoverProvider);
    final filtered = widget.routes.where((r) {
      if (_filter.isEmpty) return true;
      return r.title.toLowerCase().contains(_filter) ||
          r.subtitle.toLowerCase().contains(_filter);
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: c.bgElevated,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: c.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .35),
                blurRadius: 30,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.textMuted.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'МАРШРУТЫ И СЕРВЕРЫ',
                            style: TextStyle(
                              color: AtlasTheme.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Выбор подключения',
                            style: TextStyle(
                              fontFamily: AtlasTheme.serifFamily,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: c.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                      color: c.textMuted,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: c.bgCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.alt_route_rounded,
                        size: 20,
                        color: autoFailover ? c.success : c.textMuted,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Автопереключение при сбое',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: c.textPrimary,
                              ),
                            ),
                            Text(
                              autoFailover
                                  ? 'Поиск рабочей ноды при падении'
                                  : 'Выключено (фиксированный IP для игр)',
                              style: TextStyle(
                                fontSize: 11,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: autoFailover,
                        activeColor: c.success,
                        onChanged: (val) {
                          ref.read(autoFailoverProvider.notifier).toggle();
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: TextStyle(color: c.textPrimary, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Поиск из ${widget.routes.length} серверов...',
                          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                          prefixIcon: Icon(Icons.search_rounded,
                              size: 18, color: c.textMuted),
                          filled: true,
                          fillColor: c.bgCard,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: c.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: c.border),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _isFindingFastest ? null : _findFastestServer,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AtlasTheme.accent.withValues(alpha: .15),
                        foregroundColor: AtlasTheme.accent,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                              color: AtlasTheme.accent.withValues(alpha: .3)),
                        ),
                      ),
                      icon: _isFindingFastest
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AtlasTheme.accent),
                            )
                          : const Icon(Icons.bolt_rounded, size: 16),
                      label: Text(
                        _isFindingFastest ? 'Поиск...' : 'Быстрый',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          'Маршруты не найдены',
                          style: TextStyle(color: c.textMuted),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final isSelected = item.id == widget.selectedId;
                          final isProbing = _probingIds.contains(item.id);
                          final latency = _latencies[item.id];

                          if (!item.disabled &&
                              latency == null &&
                              !isProbing) {
                            _probeRoute(item);
                          }

                          return Material(
                            color: isSelected
                                ? AtlasTheme.accent.withValues(alpha: .12)
                                : item.disabled
                                    ? c.bgBase.withValues(alpha: .5)
                                    : c.bgCard,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: item.disabled
                                  ? null
                                  : () => widget.onSelected(item),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isSelected
                                        ? AtlasTheme.accent
                                        : item.disabled
                                            ? c.border.withValues(alpha: .4)
                                            : c.border,
                                    width: isSelected ? 1.5 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? AtlasTheme.accent
                                            : c.bgElevated,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Center(
                                        child: Icon(
                                          isSelected
                                              ? Icons.check_rounded
                                              : _iconForGroup(item.icon),
                                          size: 18,
                                          color: isSelected
                                              ? AtlasTheme.onAccent
                                              : (item.disabled
                                                  ? c.textMuted
                                                  : AtlasTheme.accent),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: isSelected
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                              color: item.disabled
                                                  ? c.textMuted
                                                  : c.textPrimary,
                                            ),
                                          ),
                                          if (item.subtitle.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              item.disabled &&
                                                      item.disabledReason
                                                          .isNotEmpty
                                                  ? item.disabledReason
                                                  : item.subtitle,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: item.disabled
                                                    ? AtlasTheme.error
                                                    : c.textMuted,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (isProbing)
                                      SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: c.textMuted,
                                        ),
                                      )
                                    else if (latency != null && latency > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: (latency < 120
                                                  ? c.success
                                                  : latency < 280
                                                      ? c.warning
                                                      : c.error)
                                              .withValues(alpha: .15),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '$latency мс',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: latency < 120
                                                ? c.success
                                                : latency < 280
                                                    ? c.warning
                                                    : c.error,
                                          ),
                                        ),
                                      )
                                    else if (latency != null && latency <= 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: c.error.withValues(alpha: .12),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'Сбой',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: c.error,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  IconData _iconForGroup(String raw) {
    return switch (raw) {
      'lightning' => Icons.bolt_rounded,
      'speed' => Icons.speed_rounded,
      'shield' => Icons.shield_outlined,
      'globe' => Icons.public_rounded,
      _ => Icons.alt_route_rounded,
    };
  }
}
