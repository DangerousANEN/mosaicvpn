import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';

/// Connections screen — live TCP/UDP flow monitor.
class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  String _searchQuery = '';
  String _filterOutbound = 'all'; // all | proxy | direct | block

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final connsAsync = ref.watch(connectionsProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Active Connections',
            subtitle: 'Live TCP/UDP flows through the tunnel',
            action: TextButton.icon(
              onPressed: () async {
                final api = ref.read(daemonApiProvider);
                try {
                  await api.closeAllConnections();
                } catch (e) {
                  debugPrint('closeAllConnections failed: $e');
                }
                ref.invalidate(connectionsProvider);
              },
              icon: const Icon(Icons.cancel, size: 16),
              label: const Text('Close All'),
            ),
          ),
          const SizedBox(height: 12),

          // q6: Search + filter bar
          Row(
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  onChanged: (v) =>
                      setState(() => _searchQuery = v.toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search host, process, chain...',
                    hintStyle: const TextStyle(fontSize: 12),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 16),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                      borderSide: BorderSide(color: c.border),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Filter dropdown
              DropdownButton<String>(
                value: _filterOutbound,
                dropdownColor: Theme.of(context).cardColor,
                style: TextStyle(
                  fontFamily: AtlasTheme.sansFamily,
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All')),
                  DropdownMenuItem(value: 'proxy', child: Text('Proxy')),
                  DropdownMenuItem(value: 'direct', child: Text('Direct')),
                  DropdownMenuItem(value: 'block', child: Text('Blocked')),
                ],
                onChanged: (v) => setState(() => _filterOutbound = v ?? 'all'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Table header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: c.bgInk,
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(AtlasTheme.radiusSm)),
            ),
            child: Row(
              children: [
                _headerCell(context, 'HOST', 3),
                _headerCell(context, 'OUT', 1),
                _headerCell(context, 'CHAIN', 2),
                _headerCell(context, 'UP', 1),
                _headerCell(context, 'DOWN', 1),
                _headerCell(context, 'NET', 1, alignRight: true),
                _headerCell(context, 'ACTION', 1, alignRight: true),
              ],
            ),
          ),

          // Connection list
          Expanded(
            child: connsAsync.when(
              data: (conns) {
                // q6: Apply search + filter
                var filtered = conns.where((c) {
                  if (_filterOutbound == 'proxy' && !c.isProxy) return false;
                  if (_filterOutbound == 'direct' && !c.isDirect) return false;
                  if (_filterOutbound == 'block' && (c.isProxy || c.isDirect)) {
                    return false;
                  }
                  if (_searchQuery.isEmpty) return true;
                  return c.host.toLowerCase().contains(_searchQuery) ||
                      c.process.toLowerCase().contains(_searchQuery) ||
                      c.chain.toLowerCase().contains(_searchQuery);
                }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lan, size: 48, color: c.textMuted),
                        const SizedBox(height: 16),
                        Text(
                          conns.isEmpty
                              ? 'No active connections.'
                              : 'No matches for filter.',
                          style: TextStyle(
                            fontFamily: AtlasTheme.serifFamily,
                            fontSize: 16,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) =>
                      _ConnRow(conn: filtered[i], ref: ref),
                );
              },
              loading: () => ListView.builder(
                  itemCount: 5,
                  itemBuilder: (_, __) =>
                      const Card(child: SkeletonServerRow())),
              error: (_, __) => Center(
                child: Text(
                  'Unable to load connections.',
                  style: TextStyle(color: c.textMuted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCell(BuildContext context, String text, int flex,
          {bool alignRight = false}) =>
      Expanded(
        flex: flex,
        child: Text(
          text,
          textAlign: alignRight ? TextAlign.right : TextAlign.left,
          style: TextStyle(
            fontFamily: AtlasTheme.monoFamily,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: ThemeColors.of(context).textOnInk,
            letterSpacing: 0.5,
          ),
        ),
      );
}

class _ConnRow extends StatelessWidget {
  final Connection conn;
  final WidgetRef ref;

  const _ConnRow({required this.conn, required this.ref});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final outboundColor = conn.isProxy
        ? AtlasTheme.accent
        : conn.isDirect
            ? AtlasTheme.success
            : AtlasTheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          // Host
          Expanded(
            flex: 3,
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: conn.host));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
              child: Tooltip(
                message: 'Long-press to copy',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conn.host,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: c.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (conn.process.isNotEmpty)
                      Text(
                        conn.process,
                        style: TextStyle(
                          fontSize: 10,
                          color: c.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Outbound
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: outboundColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              ),
              child: Text(
                conn.displayOutbound,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: outboundColor,
                ),
              ),
            ),
          ),

          // Chain
          Expanded(
            flex: 2,
            child: Text(
              conn.chain,
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 10,
                color: c.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Upload
          Expanded(
            flex: 1,
            child: Text(
              formatBytes(conn.upload),
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 11,
                color: c.textSecondary,
              ),
            ),
          ),

          // Download
          Expanded(
            flex: 1,
            child: Text(
              formatBytes(conn.download),
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 11,
                color: c.textSecondary,
              ),
            ),
          ),

          // Network
          Expanded(
            flex: 1,
            child: Text(
              conn.network.toUpperCase(),
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 10,
                color: c.textMuted,
              ),
            ),
          ),

          // Close
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Close connection',
                onPressed: () async {
                  final api = ref.read(daemonApiProvider);
                  try {
                    await api.closeConnection(conn.id);
                  } catch (e) {
                    debugPrint('closeConnection failed: $e');
                  }
                  ref.invalidate(connectionsProvider);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
