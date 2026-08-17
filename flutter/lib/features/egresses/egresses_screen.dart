import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/daemon_error_message.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../groups/groups_screen.dart' show groupsManifestProvider;

/// Egresses screen — manage multiple proxy listeners on different ports.
///
/// Each egress is a local inbound (SOCKS5/HTTP/mixed) that routes
/// traffic through a specific server. This enables per-app routing:
/// browser → port 2080 → Frankfurt, games → port 2081 → Tokyo, etc.
class EgressesScreen extends ConsumerWidget {
  const EgressesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final egressesAsync = ref.watch(egressesProvider);
    final serversAsync = ref.watch(serversProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Egresses',
            subtitle: 'Local proxy listeners on separate ports',
            action: TextButton.icon(
              onPressed: () => _showEgressDialog(
                context,
                ref,
                serversAsync,
                null,
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Egress'),
            ),
          ),
          const SizedBox(height: 16),

          // Info banner
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AtlasTheme.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              border: Border.all(
                color: AtlasTheme.accent.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: AtlasTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Each egress listens on a local port and routes traffic '
                    'through the selected server. Configure apps to use '
                    'different proxies for per-app routing.',
                    style: TextStyle(
                      fontSize: 11,
                      color: c.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Egress list
          Expanded(
            child: egressesAsync.when(
              loading: () => ListView.builder(
                  itemCount: 4,
                  itemBuilder: (_, __) =>
                      const Card(child: SkeletonServerRow())),
              error: (e, _) => _EgressRuntimeError(
                message: daemonErrorMessage(context, e),
                onRetry: () => ref.invalidate(egressesProvider),
              ),
              data: (egresses) {
                if (egresses.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.input, size: 48, color: c.textMuted),
                        const SizedBox(height: 12),
                        Text('No egresses configured',
                            style: TextStyle(color: c.textMuted, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text('Add an egress to start a local proxy listener',
                            style: TextStyle(color: c.textMuted, fontSize: 11)),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: egresses.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _EgressTile(egress: egresses[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EgressRuntimeError extends StatelessWidget {
  const _EgressRuntimeError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.bgCard,
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
            border: Border.all(color: c.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_outlined, size: 34, color: c.textMuted),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared dialog for both adding and editing an egress.
/// If [existing] is null → Add mode. Otherwise → Edit mode.
void _showEgressDialog(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<List<Server>> serversAsync,
  Egress? existing,
) {
  final c = ThemeColors.of(context);
  final isEdit = existing != null;
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final portCtrl =
      TextEditingController(text: existing?.port.toString() ?? '2080');
  String type = existing?.type ?? 'mixed';
  String? serverID = existing?.serverID;
  String? groupID = existing?.groupID;
  bool autoConnect = existing?.autoConnect ?? false; // q4
  bool allowLAN = existing?.listen == '0.0.0.0';
  final servers = serversAsync.valueOrNull ?? [];
  // Read manifest groups (synchronous read, no watch in void fn)
  final manifestGroups =
      ref.read(groupsManifestProvider).valueOrNull?.groups ?? [];

  // Dispose controllers after dialog closes (Add, Cancel, back gesture).
  void disposeCtrls() {
    nameCtrl.dispose();
    portCtrl.dispose();
  }

  showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: c.bgElevated,
            title: Text(
              isEdit ? 'Edit Egress' : 'Add Egress',
              style: const TextStyle(
                  fontFamily: AtlasTheme.serifFamily, fontSize: 18),
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Browser Proxy',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(
                      fontFamily: AtlasTheme.sansFamily,
                      fontSize: 13,
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: const [
                      DropdownMenuItem(
                          value: 'mixed', child: Text('Mixed (SOCKS5 + HTTP)')),
                      DropdownMenuItem(value: 'socks', child: Text('SOCKS5')),
                      DropdownMenuItem(value: 'http', child: Text('HTTP')),
                    ],
                    onChanged: (v) => setState(() => type = v ?? 'mixed'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: portCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      suffixText: 'port',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: groupID != null
                        ? 'group:$groupID'
                        : serverID != null
                            ? 'server:$serverID'
                            : 'default',
                    dropdownColor: Theme.of(ctx).cardColor,
                    style: TextStyle(
                      fontFamily: AtlasTheme.sansFamily,
                      fontSize: 13,
                      color: Theme.of(ctx).textTheme.bodyMedium?.color,
                    ),
                    decoration: const InputDecoration(labelText: 'Route to'),
                    hint: const Text('Select server or group'),
                    items: [
                      const DropdownMenuItem<String>(
                        value: 'default',
                        child: Text('Default (active)'),
                      ),
                      if (manifestGroups.isNotEmpty) ...[
                        const DropdownMenuItem<String>(
                          enabled: false,
                          value: '__groups_header__',
                          child: Text('Provider Groups',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 11)),
                        ),
                        ...manifestGroups.map((g) => DropdownMenuItem(
                              value: 'group:${g.id}',
                              child: Text('${g.title} · ${g.strategyLabel}'),
                            )),
                      ],
                      const DropdownMenuItem<String>(
                        enabled: false,
                        value: '__servers_header__',
                        child: Text('Individual Servers',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 11)),
                      ),
                      ...servers.map((s) => DropdownMenuItem(
                            value: 'server:${s.id}',
                            child: Text('${s.name} · ${s.country}'),
                          )),
                    ],
                    onChanged: (v) => setState(() {
                      if (v == null || v == 'default') {
                        serverID = null;
                        groupID = null;
                      } else if (v.startsWith('group:')) {
                        groupID = v.substring(6);
                        serverID = null;
                      } else if (v.startsWith('server:')) {
                        serverID = v.substring(7);
                        groupID = null;
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  // q4: Auto-connect checkbox
                  Tooltip(
                    message:
                        'When enabled, this egress listener starts automatically when the app launches',
                    child: CheckboxListTile(
                      value: autoConnect,
                      onChanged: (v) =>
                          setState(() => autoConnect = v ?? false),
                      title: const Text('Auto-connect on launch',
                          style: TextStyle(fontSize: 13)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Allow access from LAN
                  Tooltip(
                    message:
                        'Allow other devices in your local network (LAN) to connect to this proxy port',
                    child: CheckboxListTile(
                      value: allowLAN,
                      onChanged: (v) => setState(() => allowLAN = v ?? false),
                      title: const Text('Allow access from LAN',
                          style: TextStyle(fontSize: 13)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    final api = ref.read(daemonApiProvider);
                    final server =
                        servers.where((s) => s.id == serverID).firstOrNull;
                    final group = manifestGroups
                        .where((g) => g.id == groupID)
                        .firstOrNull;
                    final parsedPort = int.tryParse(portCtrl.text) ?? 2080;
                    final port = parsedPort.clamp(1, 65535);
                    // Check for duplicate port
                    final egresses =
                        ref.read(egressesProvider).valueOrNull ?? [];
                    final dupPort = egresses
                        .any((e) => e.port == port && e.id != existing?.id);
                    if (dupPort && ctx.mounted) {
                      await showDialog(
                        context: ctx,
                        builder: (d) => AlertDialog(
                          backgroundColor: c.bgElevated,
                          title: const Text('Port Conflict',
                              style: TextStyle(fontSize: 16)),
                          content: Text(
                              'Port $port is already used by another egress.',
                              style: TextStyle(
                                  fontSize: 13, color: c.textSecondary)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(d),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                    final payload = {
                      'name': nameCtrl.text.isNotEmpty
                          ? nameCtrl.text
                          : 'Egress $port',
                      'type': type,
                      'listen': allowLAN ? '0.0.0.0' : '127.0.0.1',
                      'port': port,
                      'server_id': serverID,
                      'server_name': server?.name,
                      'group_id': groupID,
                      'group_name': group?.title,
                      'active': existing?.active ?? false,
                      'auto_connect': autoConnect,
                    };
                    if (existing != null) {
                      await api.updateEgress(existing.id, payload);
                    } else {
                      await api.addEgress(payload);
                    }
                    ref.invalidate(egressesProvider);
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    debugPrint('egress save failed: $e');
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: SelectableText('Save failed: $e',
                              style: const TextStyle(fontFamily: 'monospace')),
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
                child: Text(isEdit ? 'Save' : 'Add'),
              ),
            ],
          );
        },
      );
    },
  ).whenComplete(disposeCtrls);
}

class _EgressTile extends ConsumerWidget {
  final Egress egress;
  const _EgressTile({required this.egress});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final serversAsync = ref.watch(serversProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.bgElevated,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          // Status dot
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: egress.active ? AtlasTheme.success : c.textMuted,
            ),
          ),
          const SizedBox(width: 14),

          // Name + server
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  egress.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    // Type badge
                    _TypeBadge(type: egress.type),
                    const SizedBox(width: 8),
                    // Route target: group or server
                    if (egress.groupID != null && egress.groupName != null)
                      Tooltip(
                        message: 'Auto-selects best node from group pool',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AtlasTheme.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.hub,
                                  size: 10, color: AtlasTheme.accent),
                              const SizedBox(width: 3),
                              Text(
                                egress.groupName!,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: AtlasTheme.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Text(
                        egress.serverName ?? 'Default',
                        style: TextStyle(
                          fontSize: 11,
                          color: c.textMuted,
                        ),
                      ),
                    if (egress.autoConnect) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Auto-connects on app launch',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AtlasTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.flash_on,
                                  size: 9, color: AtlasTheme.accent),
                              SizedBox(width: 2),
                              Text('AUTO',
                                  style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.w700,
                                      color: AtlasTheme.accent,
                                      letterSpacing: 0.5)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (egress.listen == '0.0.0.0') ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Shared to local network (LAN)',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AtlasTheme.info.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.share,
                                  size: 9, color: AtlasTheme.info),
                              SizedBox(width: 2),
                              Text('LAN',
                                  style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.w700,
                                      color: AtlasTheme.info,
                                      letterSpacing: 0.5)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Address:port
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${egress.listen}:${egress.port}',
                style: TextStyle(
                  fontFamily: AtlasTheme.monoFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: c.textPrimary,
                ),
              ),
              if (egress.active && egress.connections > 0)
                Text(
                  '${egress.connections} conn · ↑${formatBytes(egress.upload)} ↓${formatBytes(egress.download)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: c.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),

          // Toggle
          Switch(
            value: egress.active,
            onChanged: (v) async {
              final api = ref.read(daemonApiProvider);
              try {
                await api.toggleEgress(egress.id, v);
                ref.invalidate(egressesProvider);
              } catch (e) {
                debugPrint('toggleEgress failed: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: SelectableText('Toggle failed: $e',
                          style: const TextStyle(fontFamily: 'monospace')),
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
          const SizedBox(width: 4),

          // Edit button
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            color: c.textMuted,
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
            tooltip: 'Edit',
            onPressed: () => _showEgressDialog(
              context,
              ref,
              serversAsync,
              egress,
            ),
          ),
          const SizedBox(width: 4),

          // Delete
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            color: c.textMuted,
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
            tooltip: 'Delete',
            onPressed: () async {
              // q5: Confirm before delete
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: c.bgElevated,
                  title: const Text('Delete Egress?',
                      style: TextStyle(fontSize: 16)),
                  content: Text(
                      'Remove "${egress.name}" listener on port ${egress.port}?',
                      style: TextStyle(fontSize: 13, color: c.textSecondary)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: AtlasTheme.error),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                final api = ref.read(daemonApiProvider);
                try {
                  await api.deleteEgress(egress.id);
                  ref.invalidate(egressesProvider);
                } catch (e) {
                  debugPrint('deleteEgress failed: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: SelectableText('Delete failed: $e',
                            style: const TextStyle(fontFamily: 'monospace')),
                        action: SnackBarAction(
                          label: 'Copy',
                          onPressed: () => Clipboard.setData(
                              ClipboardData(text: e.toString())),
                        ),
                      ),
                    );
                  }
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (type) {
      'mixed' => ('MIXED', Colors.indigo),
      'socks' => ('SOCKS5', Colors.teal),
      'http' => ('HTTP', Colors.orange),
      _ => (type.toUpperCase(), Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
