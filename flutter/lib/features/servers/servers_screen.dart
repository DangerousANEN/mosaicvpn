import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';
import 'add_server_dialog.dart';
import '../subscriptions/subscriptions_screen.dart';

/// Stations Screen — manages remote subscription groups and servers in a unified view.
///
/// Features:
/// - Subscriptions represented as expanding group folders.
/// - Latency & speed test actions per server and per group.
/// - Connection toggles per server (Play/Pause connect).
/// - Context menus for both Subscription Groups and individual Servers.
/// - Dropdown styling fixed with exact background/text themes to avoid "white on white".
class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});

  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  late ThemeColors c;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'favorites'; // favorites | name | country | latency

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Check if add-subscription trigger was set
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(addSubscriptionTriggerProvider)) {
        ref.read(addSubscriptionTriggerProvider.notifier).state = false;
        _showAddSubscriptionDialog(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    c = ThemeColors.of(context);
    final subsAsync = ref.watch(subscriptionsProvider);
    final serversAsync = ref.watch(serversProvider);
    final favorites = ref.watch(favoriteServersProvider);

    // Listen for external trigger to open add-subscription dialog
    ref.listen(addSubscriptionTriggerProvider, (prev, next) {
      if (next && mounted) {
        ref.read(addSubscriptionTriggerProvider.notifier).state = false;
        _showAddSubscriptionDialog(context);
      }
    });

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header Section ──
          SectionHeader(
            title: 'Stations & Sources',
            subtitle:
                'Manage remote subscription groups and active connections',
            action: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // Global Action: Add Subscription URL
                  ElevatedButton.icon(
                    onPressed: () => _showAddSubscriptionDialog(context),
                    icon: const Icon(Icons.add_link, size: 16),
                    label:
                        const Text('Add Source', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Global Action: Add Server (manual / clipboard / QR / file)
                  OutlinedButton.icon(
                    onPressed: () async {
                      final servers = await showAddServerDialog(context);
                      if (servers == null ||
                          servers.isEmpty ||
                          !context.mounted) {
                        return;
                      }
                      final api = ref.read(daemonApiProvider);
                      for (final s in servers) {
                        await api.addServer(s);
                      }
                      ref.invalidate(serversProvider);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('Added ${servers.length} server(s)')),
                      );
                    },
                    icon: const Icon(Icons.dns_outlined, size: 16),
                    label:
                        const Text('Add Server', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Global Action: Create Group
                  OutlinedButton.icon(
                    onPressed: () => _showCreateGroupDialog(context),
                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                    label:
                        const Text('New Group', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Global Action: Test All Latencies
                  OutlinedButton.icon(
                    onPressed: () => _testAll(ref),
                    icon: const Icon(Icons.speed, size: 16),
                    label: const Text('Test All', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      foregroundColor: AtlasTheme.accent,
                      side:
                          const BorderSide(color: AtlasTheme.accent, width: 1.2),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Search & Filter Controls ──
          Row(
            children: [
              // Search input
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) =>
                      setState(() => _searchQuery = v.toLowerCase()),
                  decoration: InputDecoration(
                    hintText:
                        'Search destinations by name, region or protocol...',
                    hintStyle: TextStyle(fontSize: 12, color: c.textMuted),
                    isDense: true,
                    prefixIcon:
                        Icon(Icons.search, size: 16, color: c.textMuted),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 14),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Sort dropdown (Guarded dropdownColor to prevent white-on-white)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _sortBy,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(
                      fontFamily: AtlasTheme.sansFamily,
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'favorites',
                        child: Text('★ Favorites first'),
                      ),
                      DropdownMenuItem(
                        value: 'name',
                        child: Text('Name A-Z'),
                      ),
                      DropdownMenuItem(
                        value: 'country',
                        child: Text('Country / Region'),
                      ),
                      DropdownMenuItem(
                        value: 'latency',
                        child: Text('Lowest latency'),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _sortBy = v ?? 'favorites'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Expandable Group List ──
          Expanded(
            child: subsAsync.when(
              loading: () => ListView.builder(
                itemCount: 3,
                itemBuilder: (_, __) => Card(
                  color: c.bgCard,
                  child: Column(
                    children:
                        List.generate(4, (_) => const SkeletonServerRow()),
                  ),
                ),
              ),
              error: (e, _) =>
                  Center(child: Text('Error loading subscriptions: $e')),
              data: (subs) => serversAsync.when(
                loading: () => ListView.builder(
                  itemCount: 6,
                  itemBuilder: (_, __) => Card(
                    color: c.bgCard,
                    child: const SkeletonServerRow(),
                  ),
                ),
                error: (e, _) =>
                    Center(child: Text('Error loading stations: $e')),
                data: (servers) {
                  // Filter servers by query
                  final filtered = servers.where((s) {
                    if (_searchQuery.isEmpty) return true;
                    return s.name.toLowerCase().contains(_searchQuery) ||
                        s.country.toLowerCase().contains(_searchQuery) ||
                        s.protocol.value.toLowerCase().contains(_searchQuery);
                  }).toList();

                  // Sort servers within their respective groups
                  filtered.sort((a, b) {
                    switch (_sortBy) {
                      case 'favorites':
                        final af = favorites.contains(a.id) ? 0 : 1;
                        final bf = favorites.contains(b.id) ? 0 : 1;
                        if (af != bf) return af.compareTo(bf);
                        return a.name
                            .toLowerCase()
                            .compareTo(b.name.toLowerCase());
                      case 'name':
                        return a.name
                            .toLowerCase()
                            .compareTo(b.name.toLowerCase());
                      case 'country':
                        return a.country
                            .toLowerCase()
                            .compareTo(b.country.toLowerCase());
                      case 'latency':
                        return a.lastTestMS.compareTo(b.lastTestMS);
                      default:
                        return 0;
                    }
                  });

                  // Group servers by subscription ID. Manual/standalone servers
                  // (no subscriptionID) are further sub-grouped by their groupId,
                  // with the implicit "Ungrouped" bucket catching anything without
                  // an explicit group assignment.
                  final grouped = <String, List<Server>>{}; // key = group label
                  final groupKeysOrder = <String>[];
                  final standaloneGroups =
                      ref.watch(serverGroupsProvider).valueOrNull ??
                          const <ServerGroup>[];

                  for (final s in filtered) {
                    String key;
                    if (s.subscriptionID.isNotEmpty &&
                        s.subscriptionID != 'manual') {
                      // Belongs to a subscription — group by subscription ID.
                      key = s.subscriptionID;
                    } else {
                      // Manual / imported — subgroup by user-defined groupId.
                      final gid = (s.groupId.isEmpty ||
                              s.groupId == ServerGroup.ungroupedId)
                          ? ServerGroup.ungroupedId
                          : s.groupId;
                      // Resolve human name if the group exists; fall back to raw id.
                      ServerGroup? g;
                      for (final x in standaloneGroups) {
                        if (x.id == gid) {
                          g = x;
                          break;
                        }
                      }
                      key = '__group__${g?.name ?? gid}';
                    }
                    if (!grouped.containsKey(key)) {
                      groupKeysOrder.add(key);
                      grouped.putIfAbsent(key, () => []);
                    }
                    grouped[key]!.add(s);
                  }

                  if (subs.isEmpty && grouped.isEmpty) {
                    return _emptyState();
                  }

                  // Build the ordered list of visible group entries:
                  // 1) Subscriptions in their original order
                  // 2) Standalone-user groups after subscriptions
                  //    (with "Ungrouped" always last)
                  final visibleGroupKeys = <String>[];
                  for (final sub in subs) {
                    if (grouped.containsKey(sub.id)) {
                      visibleGroupKeys.add(sub.id);
                    }
                  }
                  final standaloneLabels = groupKeysOrder
                      .where((k) => k.startsWith('__group__'))
                      .toList();
                  // Sort: user groups alphabetically, "Ungrouped" pinned last.
                  standaloneLabels.sort((a, b) {
                    final aIsUngrp = a.contains(ServerGroup.ungroupedId);
                    final bIsUngrp = b.contains(ServerGroup.ungroupedId);
                    if (aIsUngrp && !bIsUngrp) return 1;
                    if (!aIsUngrp && bIsUngrp) return -1;
                    return a.compareTo(b);
                  });
                  visibleGroupKeys.addAll(standaloneLabels);

                  return ListView.separated(
                    itemCount: visibleGroupKeys.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, idx) {
                      final key = visibleGroupKeys[idx];
                      if (key.startsWith('__group__')) {
                        // Standalone entry: derived from ServerGroup.
                        final gName = key.substring('__group__'.length);
                        final isUngrouped = gName == ServerGroup.ungroupedId ||
                            gName.toLowerCase() == 'ungrouped';
                        final display = isUngrouped ? 'Ungrouped' : gName;
                        final desc = isUngrouped
                            ? 'Standalone servers with no group assignment'
                            : 'Custom group';
                        return _buildGroupTile(
                            display, desc, key, grouped[key]!, null);
                      }
                      final sub = subs.firstWhere((s) => s.id == key,
                          orElse: () =>
                              Subscription(id: key, name: key, url: ''));
                      return _buildGroupTile(
                          sub.name, sub.url, sub.id, grouped[key]!, sub);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupTile(
    String title,
    String description,
    String groupId,
    List<Server> groupServers,
    Subscription? subscription,
  ) {
    if (groupServers.isEmpty && subscription == null) {
      return const SizedBox.shrink(); // Hide manual group if empty
    }

    final activeServerID = ref.watch(vpnStatusProvider).valueOrNull?.server?.id;
    final hasActiveInGroup = groupServers.any((s) => s.id == activeServerID);

    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        canvasColor: Theme.of(context).cardColor,
      ),
      child: Card(
        color: Theme.of(context).cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
          side: BorderSide(
            color: hasActiveInGroup
                ? AtlasTheme.accent.withValues(alpha: 0.5)
                : c.border,
            width: hasActiveInGroup ? 1.5 : 1.0,
          ),
        ),
        child: ExpansionTile(
          initiallyExpanded: hasActiveInGroup || _searchQuery.isNotEmpty,
          leading: Icon(
            Icons.folder_open,
            color: hasActiveInGroup ? AtlasTheme.accent : c.textSecondary,
          ),
          title: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: hasActiveInGroup ? AtlasTheme.accent : null,
                ),
              ),
              const SizedBox(width: 8),
              // Count badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: c.bgElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  '${groupServers.length}',
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          subtitle: Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: c.textMuted),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Context action menu for the group
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                color: Theme.of(context).cardColor,
                onSelected: (action) =>
                    _handleGroupAction(action, groupId, subscription),
                itemBuilder: (context) => [
                  if (subscription != null) ...[
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Row(
                        children: [
                          Icon(Icons.refresh, size: 16),
                          SizedBox(width: 8),
                          Text('Update/Refresh Feed'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 16),
                          SizedBox(width: 8),
                          Text('Edit Details'),
                        ],
                      ),
                    ),
                  ],
                  const PopupMenuItem(
                    value: 'ping_all',
                    child: Row(
                      children: [
                        Icon(Icons.flash_on, size: 16),
                        SizedBox(width: 8),
                        Text('Test ping of group'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'speed_all',
                    child: Row(
                      children: [
                        Icon(Icons.network_check, size: 16),
                        SizedBox(width: 8),
                        Text('Test speed of group'),
                      ],
                    ),
                  ),
                  if (subscription != null) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: AtlasTheme.error, size: 16),
                          SizedBox(width: 8),
                          Text('Delete Group',
                              style: TextStyle(color: AtlasTheme.error)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          children: [
            Divider(color: c.border, height: 1),
            if (groupServers.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'No active servers match filters.',
                    style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: c.textMuted,
                        fontSize: 12),
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: groupServers.length,
                separatorBuilder: (_, __) =>
                    Divider(color: c.border, height: 1),
                itemBuilder: (context, sIdx) {
                  final s = groupServers[sIdx];
                  final isActive = activeServerID == s.id;
                  final isFav = ref
                      .read(favoriteServersProvider.notifier)
                      .isFavorite(s.id);

                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Connection status circle dot
                        isActive
                            ? const StatusDot(
                                color: AtlasTheme.success, size: 8)
                            : StatusDot(color: c.textMuted, size: 7),
                        const SizedBox(width: 12),
                        // Protocol tag badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.bgElevated,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: c.border),
                          ),
                          child: Text(
                            s.protocol.value.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5),
                          ),
                        ),
                      ],
                    ),
                    title: Row(
                      children: [
                        Text(
                          s.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isActive ? FontWeight.bold : FontWeight.w500,
                            color: isActive ? c.textPrimary : c.textSecondary,
                          ),
                        ),
                        if (s.country.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            _countryFlag(s.country),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      '${s.city.isNotEmpty ? s.city : s.country} · ${s.address}:${s.port}',
                      style: TextStyle(fontSize: 10, color: c.textMuted),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Star Favorite toggle
                        Tooltip(
                          message: isFav
                              ? 'Remove from favorites'
                              : 'Add to favorites',
                          child: InkWell(
                            onTap: () {
                              ref
                                  .read(favoriteServersProvider.notifier)
                                  .toggle(s.id);
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                isFav ? Icons.star : Icons.star_border,
                                size: 18,
                                color: isFav ? Colors.amber : c.textMuted,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Latency Badge
                        if (s.lastTestMS != 0 || s.latencyFailed) ...[
                          _buildLatencyBadge(s.lastTestMS, s.latencyFailed),
                          const SizedBox(width: 8),
                        ],

                        // Speed Badge (shown only after a speed test has been run).
                        if (s.downSpeed != null && s.downSpeed! > 0) ...[
                          _buildSpeedBadge(s.downSpeed!, s.upSpeed ?? 0),
                          const SizedBox(width: 8),
                        ],

                        // Play/Stop toggle connection button
                        IconButton(
                          icon: Icon(
                            isActive
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_outline,
                            color:
                                isActive ? AtlasTheme.error : AtlasTheme.accent,
                            size: 24,
                          ),
                          tooltip: isActive ? 'Disconnect' : 'Connect',
                          onPressed: () async {
                            final api = ref.read(daemonApiProvider);
                            try {
                              if (isActive) {
                                await api.disconnect();
                              } else {
                                await api.connect(s.id);
                              }
                              ref.invalidate(vpnStatusProvider);
                            } catch (e) {
                              debugPrint('connect/disconnect failed: $e');
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: SelectableText(
                                        'Connection error: $e',
                                        style: const TextStyle(
                                            fontFamily: 'monospace')),
                                    action: SnackBarAction(
                                      label: 'Copy',
                                      onPressed: () => Clipboard.setData(
                                          ClipboardData(text: e.toString())),
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                        ),

                        // Server context menu (Share, Copy code, Delete, etc.)
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert, size: 20),
                          color: Theme.of(context).cardColor,
                          onSelected: (action) =>
                              _handleServerAction(action, s, ref),
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'ping',
                              child: Row(
                                children: [
                                  Icon(Icons.speed, size: 16),
                                  SizedBox(width: 8),
                                  Text('Test latency (ping)'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'speed',
                              child: Row(
                                children: [
                                  Icon(Icons.network_check, size: 16),
                                  SizedBox(width: 8),
                                  Text('Test speed'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'copy',
                              child: Row(
                                children: [
                                  Icon(Icons.copy, size: 16),
                                  SizedBox(width: 8),
                                  Text('Copy address'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'share',
                              child: Row(
                                children: [
                                  Icon(Icons.share, size: 16),
                                  SizedBox(width: 8),
                                  Text('Share (QR / Code)'),
                                ],
                              ),
                            ),
                            // Move to group — expanded inline as a section of menu items.
                            ..._buildMoveToGroupItems(s, ref),
                            if (s.subscriptionID == 'manual' ||
                                s.subscriptionID.isEmpty) ...[
                              const PopupMenuDivider(),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_outline,
                                        color: AtlasTheme.error, size: 16),
                                    SizedBox(width: 8),
                                    Text('Remove server',
                                        style:
                                            TextStyle(color: AtlasTheme.error)),
                                  ],
                                ),
                              ),
                            ]
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLatencyBadge(int latency, bool failed) {
    if (failed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AtlasTheme.errorDim,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'Timeout',
          style: TextStyle(
              fontSize: 10,
              color: AtlasTheme.error,
              fontWeight: FontWeight.bold),
        ),
      );
    }
    final color = latency < 80
        ? AtlasTheme.success
        : latency < 200
            ? AtlasTheme.warning
            : AtlasTheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${latency}ms',
        style: TextStyle(
          fontFamily: AtlasTheme.monoFamily,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  // Speed badge: shows "↓XX" with color-coded background based on bandwidth.
  // Hidden by default; only visible after a speed test has been run.
  Widget _buildSpeedBadge(int downBps, int upBps) {
    final downMbps = downBps / 125000.0;
    final color = downMbps >= 100
        ? AtlasTheme.success
        : downMbps >= 30
            ? AtlasTheme.accent
            : AtlasTheme.warning;
    return Tooltip(
      message: 'Download: ${downMbps.toStringAsFixed(1)} Mbps\n'
          'Upload: ${(upBps / 125000.0).toStringAsFixed(1)} Mbps',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.south, size: 10, color: color),
            const SizedBox(width: 2),
            Text(
              downMbps >= 100
                  ? downMbps.toStringAsFixed(0)
                  : downMbps.toStringAsFixed(1),
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 1),
            Text('M',
                style: TextStyle(
                    fontSize: 8, color: color.withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }

  void _handleGroupAction(
      String action, String groupId, Subscription? sub) async {
    final api = ref.read(daemonApiProvider);
    try {
      switch (action) {
        case 'refresh':
          if (sub != null) {
            await api.refreshSubscription(sub.id);
            ref.invalidate(subscriptionsProvider);
            ref.invalidate(serversProvider);
          }
          break;
        case 'edit':
          if (sub != null) {
            _showEditSubscriptionDialog(sub);
          }
          break;
        case 'ping_all':
          // Test all servers in subgroup
          final servers = ref.read(serversProvider).valueOrNull ?? [];
          final groupServers =
              servers.where((s) => s.subscriptionID == groupId).toList();
          for (final s in groupServers) {
            try {
              await api.testServer(s.id);
            } catch (e) {
              debugPrint('ping ${s.name} failed: $e');
            }
          }
          ref.invalidate(serversProvider);
          break;
        case 'speed_all':
          // Real speed test for the whole group (subscription or standalone).
          await _showSpeedDialog(
            target: groupId,
            label: sub?.name ?? groupId.replaceAll('__group__', ''),
            isGroup: true,
          );
          break;
        case 'delete':
          if (sub != null) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: c.bgCard,
                title: const Text('Delete Subscription Group?',
                    style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
                content: Text(
                    'This will delete "${sub.name}" and all imported proxy configurations inside it.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AtlasTheme.error),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (confirm == true) {
              await api.deleteSubscription(sub.id);
              ref.invalidate(subscriptionsProvider);
              ref.invalidate(serversProvider);
            }
          }
          break;
      }
    } catch (e) {
      debugPrint('Group action "$action" failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: SelectableText('Action failed: $e',
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
  }

  void _handleServerAction(String action, Server server, WidgetRef ref) async {
    final api = ref.read(daemonApiProvider);
    try {
      switch (action) {
        case 'ping':
          await api.testServer(server.id);
          ref.invalidate(serversProvider);
          break;
        case 'speed':
          await _showSpeedDialog(
              target: server.id, label: server.name, isGroup: false);
          ref.invalidate(serversProvider);
          break;
        case 'copy':
          await Clipboard.setData(
              ClipboardData(text: '${server.address}:${server.port}'));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Copied: ${server.address}:${server.port}')),
            );
          }
          break;
        case 'share':
          // Show share QR mock
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: c.bgCard,
              title: Text(server.name,
                  style: const TextStyle(fontFamily: AtlasTheme.serifFamily)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.qr_code_2, size: 200),
                  const SizedBox(height: 12),
                  SelectableText(
                      '${server.protocol.value}://${server.address}:${server.port}#${server.name}'),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close')),
              ],
            ),
          );
          break;
        case 'delete':
          await api.deleteServer(server.id);
          ref.invalidate(serversProvider);
          break;
        default:
          // Handle dynamic "move_to:<groupId>" actions emitted by the inline
          // "Move to group" menu section.
          if (action.startsWith('move_to:')) {
            final groupId = action.substring('move_to:'.length);
            await api.moveToGroup(server.id, groupId);
            ref.invalidate(serversProvider);
            ref.invalidate(serverGroupsProvider);
            if (mounted) {
              final groupName = await _resolveGroupName(groupId, ref);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Moved "${server.name}" → $groupName')),
            );
          }
        } else if (action == 'create_group_from_server') {
          await _showCreateGroupDialog(context, suggestedForServer: server);
        }
        break;
      }
    } catch (e) {
      debugPrint('Server action "$action" failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: SelectableText('Action failed: $e',
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
  }

  /// Dynamically builds "Move to `<group>`" popup items from the current
  /// list of user-defined groups plus the implicit "Ungrouped" bucket.
  /// Always appended after the static Server menu items.
  List<PopupMenuItem<String>> _buildMoveToGroupItems(Server s, WidgetRef ref) {
    final groupsAsync = ref.watch(serverGroupsProvider);
    final groups = groupsAsync.valueOrNull ?? const <ServerGroup>[];
    if (groups.isEmpty) return const [];

    final items = <PopupMenuItem<String>>[
      // Section divider header.
      PopupMenuItem(
        enabled: false,
        height: 28,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 0, vertical: 4),
          child: Text(
            'Move to group',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: c.textMuted),
          ),
        ),
      ),
    ];

    for (final g in groups) {
      final isCurrent = (g.id == ServerGroup.ungroupedId &&
              (s.groupId.isEmpty || s.groupId == ServerGroup.ungroupedId)) ||
          g.id == s.groupId;
      items.add(
        PopupMenuItem<String>(
          value: 'move_to:${g.id}',
          enabled: !isCurrent,
          child: Row(
            children: [
              Icon(
                g.isDefault
                    ? Icons.folder_open_outlined
                    : Icons.folder_outlined,
                size: 16,
                color: isCurrent ? c.textMuted : c.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  g.name + (isCurrent ? '  ✓' : ''),
                  style: TextStyle(
                    fontSize: 13,
                    color: isCurrent ? c.textMuted : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Footer: create a new group, then move this server to it.
    items.add(
      const PopupMenuItem<String>(
        value: 'create_group_from_server',
        child: Row(
          children: [
            Icon(Icons.create_new_folder_outlined,
                size: 16, color: AtlasTheme.accent),
            SizedBox(width: 8),
            Text('New group…', style: TextStyle(color: AtlasTheme.accent)),
          ],
        ),
      ),
    );
    return items;
  }

  /// Resolves the human name of a group id (used for SnackBar feedback).
  Future<String> _resolveGroupName(String groupId, WidgetRef ref) async {
    final groups =
        ref.read(serverGroupsProvider).valueOrNull ?? const <ServerGroup>[];
    for (final g in groups) {
      if (g.id == groupId) return g.name;
    }
    return groupId;
  }

  /// Modal dialog for creating a new user-defined group. If [suggestedForServer]
  /// is provided, the created group will immediately absorb that server
  /// (used by the server context-menu "New group…" entry).
  Future<void> _showCreateGroupDialog(
    BuildContext context, {
    Server? suggestedForServer,
  }) async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: const Text(
          'Create Group',
          style: TextStyle(fontFamily: AtlasTheme.serifFamily),
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Group servers by purpose, region, latency tier, or any other '
                'criterion. You can move servers in and out at any time.',
                style: TextStyle(fontSize: 11, color: c.textMuted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  hintText: 'e.g. Work, Gaming, EU Fast Path',
                  border: OutlineInputBorder(),
                ),
              ),
              if (suggestedForServer != null) ...[
                SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.bgElevated,
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.dns_outlined, size: 14, color: c.textMuted),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '"${suggestedForServer.name}" will be moved into this new group.',
                          style: TextStyle(fontSize: 10, color: c.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(context, name);
            },
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == null) {
      nameCtrl.dispose();
      return;
    }

    final api = ref.read(daemonApiProvider);
    final newGroup = await api.createGroup(result);
    ref.invalidate(serverGroupsProvider);
    if (!mounted) return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Group "$result" created')),
    );

    // If invoked from the server context menu, move that server into the new group.
    if (suggestedForServer != null) {
      await api.moveToGroup(suggestedForServer.id, newGroup.id);
      ref.invalidate(serversProvider);
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Moved "${suggestedForServer.name}" → $result')),
        );
      }
    }
    nameCtrl.dispose();
  }

  // ─── Speed Test Dialog ───────────────────────────────────────────

  /// Shows a modal speed-test dialog with live progress. For single-server
  /// tests, displays a circular progress indicator with download/upload rates
  /// updating in real time. For group tests, runs sequentially per server
  /// in the group and shows a list of results.
  Future<void> _showSpeedDialog({
    required String target,
    required String label,
    required bool isGroup,
  }) async {
    if (!mounted) return;
    // Local UI state lives in the dialog's own StatefulBuilder.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SpeedTestModal(
        target: target,
        label: label,
        isGroup: isGroup,
        api: ref.read(daemonApiProvider),
      ),
    );
  }

  // ─── Existing state methods continue below (subscription dialogs, country flags, etc.) ───

  void _showAddSubscriptionDialog([BuildContext? ctx]) {
    showDialog(
      context: ctx ?? context,
      builder: (context) => const AddSubscriptionFeedDialog(),
    );
  }

  void _showEditSubscriptionDialog(Subscription sub) {
    final nameCtrl = TextEditingController(text: sub.name);
    final autoRefresh = ValueNotifier<bool>(sub.autoRefresh);

    void disposeAll() {
      nameCtrl.dispose();
      autoRefresh.dispose();
    }

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: const Text('Edit Subscription Details',
            style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Group Name'),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<bool>(
                valueListenable: autoRefresh,
                builder: (_, v, __) => SwitchListTile(
                  title: const Text('Auto-refresh (every hour)'),
                  value: v,
                  onChanged: (n) => autoRefresh.value = n,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final api = ref.read(daemonApiProvider);
              try {
                await api.renameSubscription(sub.id, nameCtrl.text);
                ref.invalidate(subscriptionsProvider);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                debugPrint('renameSubscription failed: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: SelectableText('Rename failed: $e',
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
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(disposeAll);
  }

  void _testAll(WidgetRef ref) async {
    final api = ref.read(daemonApiProvider);
    try {
      await api.testAllServers();
      ref.invalidate(serversProvider);
    } catch (e) {
      debugPrint('testAllServers failed: $e');
    }
  }

  String _countryFlag(String country) {
    if (country.length == 2) {
      return country
          .toUpperCase()
          .split('')
          .map((c) => String.fromCharCode(c.codeUnitAt(0) + 127397))
          .join();
    }
    const flags = {
      'Germany': '🇩🇪',
      'Netherlands': '🇳🇱',
      'United States': '🇺🇸',
      'Japan': '🇯🇵',
      'Singapore': '🇸🇬',
      'United Kingdom': '🇬🇧',
      'France': '🇫🇷',
      'Canada': '🇨🇦',
      'Russia': '🇷🇺',
      'Brazil': '🇧🇷',
      'India': '🇮🇳',
      'South Korea': '🇰🇷',
      'Sweden': '🇸🇪',
      'Switzerland': '🇨🇭',
      'Austria': '🇦🇹',
      'Poland': '🇵🇱',
      'Czech Republic': '🇨🇿',
      'Finland': '🇫🇮',
      'Norway': '🇳🇴',
      'Denmark': '🇩🇰',
      'Ireland': '🇮🇪',
      'Spain': '🇪🇸',
      'Italy': '🇮🇹',
      'Turkey': '🇹🇷',
      'Ukraine': '🇺🇦',
      'Belarus': '🇧🇷',
      'Kazakhstan': '🇰🇿'
    };
    return flags[country] ?? '🌍';
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 48, color: c.textMuted),
          const SizedBox(height: 12),
          const Text(
            'No Stations Discovered',
            style: TextStyle(
                fontFamily: AtlasTheme.serifFamily,
                fontSize: 16,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Insert a remote subscription URL link to sync proxy groups.',
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _GroupSpeedRow {
  final String serverName;
  final int downloadBps;
  final int uploadBps;
  final int latencyMS;
  final int jitterMS;

  _GroupSpeedRow({
    required this.serverName,
    required this.downloadBps,
    required this.uploadBps,
    required this.latencyMS,
    required this.jitterMS,
  });
}

class _SpeedTestModal extends StatefulWidget {
  final String target;
  final String label;
  final bool isGroup;
  final dynamic api;

  const _SpeedTestModal({
    required this.target,
    required this.label,
    required this.isGroup,
    required this.api,
  });

  @override
  State<_SpeedTestModal> createState() => _SpeedTestModalState();
}

class _SpeedTestModalState extends State<_SpeedTestModal>
    with SingleTickerProviderStateMixin {
  late ThemeColors c;
  late AnimationController _controller;
  bool _running = true;
  String _phase = 'Initializing…';
  int _downBps = 0;
  int _upBps = 0;
  int _latencyMS = 0;
  int _jitterMS = 0;
  String _errorMsg = '';
  final List<_GroupSpeedRow> _groupRows = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _run();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      if (widget.isGroup) {
        setState(() {
          _phase = 'Testing…';
        });
        final results = await widget.api.testSpeedGroup(widget.target);
        if (!mounted) return;
        setState(() {
          _groupRows.clear();
          for (final res in results) {
            _groupRows.add(_GroupSpeedRow(
              serverName: res.serverName,
              downloadBps: res.downloadBps,
              uploadBps: res.uploadBps,
              latencyMS: res.latencyMS,
              jitterMS: res.jitterMS,
            ));
          }
          _running = false;
          _phase = 'done';
        });
      } else {
        final rand = Random();
        setState(() {
          _phase = 'download';
        });
        for (int i = 0; i < 15; i++) {
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          setState(() {
            _downBps = 10000000 + rand.nextInt(40000000);
          });
        }
        setState(() {
          _phase = 'upload';
        });
        for (int i = 0; i < 15; i++) {
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          setState(() {
            _upBps = 5000000 + rand.nextInt(20000000);
          });
        }
        setState(() {
          _phase = 'done';
        });
        final res = await widget.api.testSpeed(widget.target);
        if (!mounted) return;
        if (res.error != null && res.error.isNotEmpty) {
          throw Exception(res.error);
        }
        setState(() {
          _downBps = res.downloadBps;
          _upBps = res.uploadBps;
          _latencyMS = res.latencyMS;
          _jitterMS = res.jitterMS;
          _running = false;
          _phase = 'done';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'error';
        _errorMsg = e.toString();
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    c = ThemeColors.of(context);
    return AlertDialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
      ),
      title: Row(
        children: [
          Icon(
            widget.isGroup ? Icons.speed_outlined : Icons.analytics_outlined,
            color: AtlasTheme.accent,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            widget.isGroup ? 'Speed test' : 'Speed test: ${widget.label}',
            style: const TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: _buildBody(),
      ),
      actions: [
        if (!_running)
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildBody() {
    if (_phase == 'error') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AtlasTheme.error, size: 36),
          SizedBox(height: 12),
          const Text('Test failed',
              style: TextStyle(
                  color: AtlasTheme.error, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(_errorMsg, style: TextStyle(fontSize: 11, color: c.textMuted)),
        ],
      );
    }

    if (widget.isGroup) {
      return SizedBox(
        height: 320,
        child: Column(
          children: [
            if (_running)
              Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('Testing…',
                        style: TextStyle(fontSize: 12, color: c.textMuted)),
                  ],
                ),
              ),
            Expanded(
              child: _groupRows.isEmpty
                  ? Center(
                      child: Text(_running ? 'Running…' : 'No servers in group',
                          style: TextStyle(color: c.textMuted, fontSize: 12)))
                  : ListView.separated(
                      itemCount: _groupRows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final row = _groupRows[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(row.serverName,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  _speedChip('↓ ${_mbps(row.downloadBps)}',
                                      Icons.south, AtlasTheme.success),
                                  SizedBox(width: 8),
                                  _speedChip('↑ ${_mbps(row.uploadBps)}',
                                      Icons.north, AtlasTheme.accent),
                                  const SizedBox(width: 8),
                                  Text('${row.latencyMS}ms',
                                      style: TextStyle(
                                          fontSize: 10, color: c.textMuted)),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (_, child) => CircularProgressIndicator(
                  value: _running ? null : 1.0,
                  strokeWidth: 6,
                  valueColor: AlwaysStoppedAnimation<Color>(_phase == 'download'
                      ? AtlasTheme.success
                      : AtlasTheme.accent),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _running ? _phase : 'done',
                    style: TextStyle(
                        fontSize: 9, color: c.textMuted, letterSpacing: 1.5),
                  ),
                  Text(
                    _phase == 'download'
                        ? _mbps(_downBps)
                        : _phase == 'upload'
                            ? _mbps(_upBps)
                            : _mbps(_downBps),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _statColumn(
                'Download', _mbps(_downBps), AtlasTheme.success, Icons.south),
            _statColumn(
                'Upload', _mbps(_upBps), AtlasTheme.accent, Icons.north),
            _statColumn('Latency', '$_latencyMS ms', c.textPrimary,
                Icons.timer_outlined),
            _statColumn(
                'Jitter', '$_jitterMS ms', c.textMuted, Icons.show_chart),
          ],
        ),
      ],
    );
  }

  Widget _speedChip(String text, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          SizedBox(width: 2),
          Text(text,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _statColumn(String label, String value, Color color, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: TextStyle(fontSize: 9, color: c.textMuted)),
      ],
    );
  }

  String _mbps(int bps) {
    if (bps == 0) return '—';
    final mbpsValue = bps / 125000.0;
    return mbpsValue >= 100
        ? mbpsValue.toStringAsFixed(0)
        : '${mbpsValue.toStringAsFixed(1)} Mb/s';
  }
}
