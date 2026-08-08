import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/skeleton_loader.dart';

import '../billing/billing_widgets.dart';

/// Subscriptions screen — manage remote server sources.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final subsAsync = ref.watch(subscriptionsProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Subscriptions',
            subtitle: 'Remote sources of egress stations',
            action: ElevatedButton.icon(
              onPressed: () => _showAddSubscriptionDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Source'),
            ),
          ),
          const SizedBox(height: 16),
          const BillingBanner(),
          const SizedBox(height: 16),
          Expanded(
            child: subsAsync.when(
              data: (subs) {
                if (subs.isEmpty) {
                  return _emptyState(context, ref);
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    final api = ref.read(daemonApiProvider);
                    final errors = <String>[];
                    for (final s in subs) {
                      try {
                        await api.refreshSubscription(s.id);
                      } catch (e) {
                        errors.add('${s.name}: $e');
                      }
                    }
                    ref.invalidate(subscriptionsProvider);
                    ref.invalidate(serversProvider);
                    if (errors.isNotEmpty && context.mounted) {
                      final errText =
                          'Refresh errors:\n${errors.join('\n')}';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(seconds: 10),
                          content: SelectableText(
                            errText,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                          action: SnackBarAction(
                            label: 'Copy',
                            onPressed: () async {
                              await Clipboard.setData(
                                  ClipboardData(text: errText));
                            },
                          ),
                        ),
                      );
                    }
                  },
                  child: ListView.separated(
                    itemCount: subs.length,
                    separatorBuilder: (_, __) =>
                        Divider(color: c.border, height: 1),
                    itemBuilder: (context, i) => _SubTile(sub: subs[i], ref: ref),
                  ),
                );
              },
              loading: () => ListView.builder(
                  itemCount: 3,
                  itemBuilder: (_, __) =>
                      const Card(child: SkeletonServerRow())),
              error: (_, __) => _emptyState(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.rss_feed, size: 48, color: c.textMuted),
          const SizedBox(height: 16),
          Text(
            'No subscriptions yet.',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 18,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add a subscription URL to import servers.',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => _showAddSubscriptionDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Add Source'),
          ),
        ],
      ),
    );
  }

  void _showAddSubscriptionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const AddSubscriptionFeedDialog(),
    );
  }
}

class AddSubscriptionFeedDialog extends ConsumerStatefulWidget {
  const AddSubscriptionFeedDialog({super.key});

  @override
  ConsumerState<AddSubscriptionFeedDialog> createState() =>
      _AddSubscriptionFeedDialogState();
}

class _AddSubscriptionFeedDialogState
    extends ConsumerState<AddSubscriptionFeedDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _autoRefresh = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || _isLoading) return;

    setState(() => _isLoading = true);
    try {
      final api = ref.read(daemonApiProvider);
      final name =
          _nameCtrl.text.trim().isEmpty ? 'Remote Feed' : _nameCtrl.text.trim();
      await api.addSubscription(
        name,
        url,
        autoRefresh: _autoRefresh,
      );
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(serversProvider);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        final errText = 'Failed to add subscription: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: SelectableText(
              errText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: errText));
              },
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AlertDialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
      title: const Text('Add Remote Provider Feed',
          style: TextStyle(fontFamily: AtlasTheme.serifFamily, fontSize: 16)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              enabled: !_isLoading,
              decoration: const InputDecoration(
                labelText: 'Feed/Group Name',
                hintText: 'e.g. My Proxies Feed',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              enabled: !_isLoading,
              decoration: const InputDecoration(
                labelText: 'Subscription URL',
                hintText: 'https://example.com/sub',
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Auto-refresh (every hour)',
                  style: TextStyle(fontSize: 13)),
              value: _autoRefresh,
              onChanged:
                  _isLoading ? null : (n) => setState(() => _autoRefresh = n),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

class _SubTile extends StatelessWidget {
  final Subscription sub;
  final WidgetRef ref;

  const _SubTile({required this.sub, required this.ref});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AtlasCard(
      child: Row(
        children: [
          // Server count badge
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: c.bgElevated,
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              border: Border.all(color: c.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${sub.serverCount}',
                  style: TextStyle(
                    fontFamily: AtlasTheme.monoFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                Text(
                  'srv',
                  style: TextStyle(
                    fontSize: 8,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub.name,
                  style: const TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (sub.hasError)
                      Text(
                        sub.lastError,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AtlasTheme.error,
                        ),
                      )
                    else
                      Text(
                        'Last fetch: ${formatRelative(sub.lastFetched)}',
                        style: TextStyle(
                          fontSize: 10,
                          color: c.textMuted,
                        ),
                      ),
                    if (sub.autoRefresh) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AtlasTheme.infoDim,
                          borderRadius:
                              BorderRadius.circular(AtlasTheme.radiusSm),
                        ),
                        child: const Text(
                          'AUTO',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: AtlasTheme.info,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Actions
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                onPressed: () async {
                  final api = ref.read(daemonApiProvider);
                  try {
                    await api.refreshSubscription(sub.id);
                    ref.invalidate(subscriptionsProvider);
                    ref.invalidate(serversProvider);
                  } catch (e) {
                    debugPrint('refreshSubscription failed: $e');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: SelectableText('Refresh failed: $e',
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
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Delete',
                onPressed: () async {
                  final api = ref.read(daemonApiProvider);
                  try {
                    await api.deleteSubscription(sub.id);
                    ref.invalidate(subscriptionsProvider);
                    ref.invalidate(serversProvider);
                  } catch (e) {
                    debugPrint('deleteSubscription failed: $e');
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
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
