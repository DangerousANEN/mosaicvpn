import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/billing_provider.dart';
import '../../core/theme/atlas_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atlas_widgets.dart';
import 'billing_dialogs.dart';

/// BillingBanner — A compact banner widget for displaying Telegram sync and subscription traffic status,
/// designed to be embedded in screens like Subscriptions or Profiles.
class BillingBanner extends ConsumerWidget {
  const BillingBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billingAsync = ref.watch(billingProfileProvider);

    return billingAsync.when(
      data: (profile) => _buildBanner(context, ref, profile),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildBanner(BuildContext context, WidgetRef ref, BillingProfile profile) {
    final c = ThemeColors.of(context);

    if (!profile.linked) {
      return AtlasCard(
        child: Row(
          children: [
            Icon(Icons.telegram, size: 28, color: c.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Link Telegram Account',
                    style: TextStyle(
                      fontFamily: AtlasTheme.serifFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: c.textPrimary,
                    ),
                  ),
                  Text(
                    'Sync your subscription status & top up via CryptoBot',
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            ElevatedButton(
              onPressed: () => showLinkAccountDialog(context, ref),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.textOnInk,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              child: const Text('Link'),
            ),
          ],
        ),
      );
    }

    final used = profile.usedTrafficBytes;
    final limit = profile.trafficLimitBytes;
    final daysLeft = profile.daysLeft;

    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.telegram, size: 22, color: c.success),
              const SizedBox(width: 8),
              Text(
                profile.username.isNotEmpty
                    ? '@${profile.username}'
                    : 'ID: ${profile.telegramId}',
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
              if (profile.squadName.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.bgInk,
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  ),
                  child: Text(
                    profile.squadName,
                    style: TextStyle(
                      fontFamily: AtlasTheme.monoFamily,
                      fontSize: 11,
                      color: c.textOnInk,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                '$daysLeft days left',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: daysLeft <= 3 ? c.warning : c.success,
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => showTopupDialog(context, ref),
                icon: const Icon(Icons.add_card, size: 14),
                label: const Text('Top Up', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  child: LinearProgressIndicator(
                    value: limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.05,
                    minHeight: 6,
                    backgroundColor: c.bgChild,
                    color: c.accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                limit > 0
                    ? '${formatBytes(used)} / ${formatBytes(limit)}'
                    : formatBytes(used),
                style: TextStyle(
                  fontFamily: AtlasTheme.monoFamily,
                  fontSize: 11,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
