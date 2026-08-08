import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/billing_provider.dart';
import '../../core/theme/atlas_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';
import 'billing_dialogs.dart';

/// BillingScreen — MosaicVPN Telegram account link, subscription stats, and CryptoBot top-ups.
class BillingScreen extends ConsumerWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final billingAsync = ref.watch(billingProfileProvider);

    return Scaffold(
      backgroundColor: c.bgBase,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Billing & Account',
              subtitle: 'Manage Remnawave account link, traffic limits, and top-ups',
              action: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh Billing Profile',
                onPressed: () {
                  ref.read(billingNotifierProvider.notifier).refreshProfile();
                },
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: billingAsync.when(
                data: (profile) => _BillingContent(profile: profile),
                loading: () => const _BillingSkeleton(),
                error: (err, stack) => _BillingError(
                  error: err,
                  onRetry: () => ref
                      .read(billingNotifierProvider.notifier)
                      .refreshProfile(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BillingContent extends ConsumerWidget {
  final BillingProfile profile;

  const _BillingContent({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AccountLinkCard(profile: profile),
          const SizedBox(height: 16),
          _SubscriptionDetailsCard(profile: profile),
          const SizedBox(height: 16),
          _TopupActionCard(profile: profile),
        ],
      ),
    );
  }
}

/// Telegram Account Link Info or Prompt Card.
class _AccountLinkCard extends ConsumerWidget {
  final BillingProfile profile;

  const _AccountLinkCard({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);

    if (!profile.linked) {
      return AtlasCard(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.warning.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.link_off, color: c.warning, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'No Telegram Account Linked',
                          style: TextStyle(
                            fontFamily: AtlasTheme.serifFamily,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Link your Telegram account to view squad details and enable CryptoBot payments.',
                          style: TextStyle(fontSize: 13, color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: () => showLinkAccountDialog(context, ref),
                  icon: const Icon(Icons.telegram, size: 18),
                  label: const Text('Link Telegram Account'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: c.textOnInk,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.telegram, color: c.success, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          profile.username.isNotEmpty
                              ? '@${profile.username}'
                              : 'Linked Telegram User',
                          style: TextStyle(
                            fontFamily: AtlasTheme.serifFamily,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: profile.status.toLowerCase() == 'active'
                                ? c.success.withValues(alpha: 0.2)
                                : c.warning.withValues(alpha: 0.2),
                            borderRadius:
                                BorderRadius.circular(AtlasTheme.radiusSm),
                          ),
                          child: Text(
                            profile.status.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: profile.status.toLowerCase() == 'active'
                                  ? c.success
                                  : c.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Telegram ID: ${profile.telegramId}'
                      '${profile.shortUuid.isNotEmpty ? " • Short UUID: ${profile.shortUuid}" : ""}',
                      style: TextStyle(
                        fontFamily: AtlasTheme.monoFamily,
                        fontSize: 12,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: c.bgCard,
                      title: const Text('Unlink Telegram Account?'),
                      content: const Text(
                        'Are you sure you want to unlink your Telegram account from this client?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: c.danger,
                              foregroundColor: Colors.white),
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Unlink'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true && context.mounted) {
                    await ref
                        .read(billingNotifierProvider.notifier)
                        .unlinkAccount();
                  }
                },
                icon: Icon(Icons.link_off, size: 16, color: c.danger),
                label: Text('Unlink', style: TextStyle(color: c.danger)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Subscription Details Card: Used vs Total Traffic, Expiration & Days Left, Squad Name.
class _SubscriptionDetailsCard extends StatelessWidget {
  final BillingProfile profile;

  const _SubscriptionDetailsCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);

    final used = profile.usedTrafficBytes;
    final limit = profile.trafficLimitBytes;
    final progress = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    final daysLeft = profile.daysLeft;

    Color daysColor = c.success;
    if (daysLeft <= 0) {
      daysColor = c.danger;
    } else if (daysLeft <= 3) {
      daysColor = c.warning;
    }

    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainStateHelper.spaceBetween,
            children: [
              Text(
                'Subscription & Traffic',
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
              if (profile.squadName.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: c.bgInk,
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.shield_outlined, size: 14, color: c.accent),
                      const SizedBox(width: 6),
                      Text(
                        profile.squadName,
                        style: TextStyle(
                          fontFamily: AtlasTheme.monoFamily,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.textOnInk,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // Traffic progress bar section
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Traffic Used',
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
                  ),
                  Text(
                    limit > 0
                        ? '${formatBytes(used)} / ${formatBytes(limit)}'
                        : '${formatBytes(used)} (Unlimited)',
                    style: TextStyle(
                      fontFamily: AtlasTheme.monoFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                child: LinearProgressIndicator(
                  value: limit > 0 ? progress : 0.05,
                  minHeight: 8,
                  backgroundColor: c.bgChild,
                  color: progress > 0.9 ? c.danger : c.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          // Expiration & Days Remaining
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Expiration Date',
                      style: TextStyle(fontSize: 12, color: c.textMuted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      profile.expireAt != null
                          ? formatTime(profile.expireAt)
                          : 'No expiration date',
                      style: TextStyle(
                        fontFamily: AtlasTheme.monoFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: daysColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  border: Border.all(color: daysColor.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      '$daysLeft Days Left',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: daysColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (profile.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              profile.description,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: c.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// MainStateHelper for row spaceBetween
class MainStateHelper {
  static const MainAxisAlignment spaceBetween = MainAxisAlignment.spaceBetween;
}

/// CryptoBot Top-Up Action Card.
class _TopupActionCard extends ConsumerWidget {
  final BillingProfile profile;

  const _TopupActionCard({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);

    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.account_balance_wallet,
                    color: c.accent, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CryptoBot Top-Up',
                      style: TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Instantly extend your subscription via Telegram CryptoBot (USDT, TON, BTC).',
                      style: TextStyle(fontSize: 13, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton.icon(
                onPressed: profile.linked
                    ? () => showTopupDialog(context, ref)
                    : () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Please link your Telegram account first to top up.',
                            ),
                          ),
                        );
                        showLinkAccountDialog(context, ref);
                      },
                icon: const Icon(Icons.add_card, size: 18),
                label: const Text('Top Up Balance'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: c.textOnInk,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Loading skeleton for BillingScreen.
class _BillingSkeleton extends StatelessWidget {
  const _BillingSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Card(child: SkeletonServerRow()),
        SizedBox(height: 16),
        Card(child: SkeletonServerRow()),
      ],
    );
  }
}

/// Error view for BillingScreen.
class _BillingError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _BillingError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: c.danger),
          const SizedBox(height: 16),
          Text(
            'Failed to load billing profile',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 18,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error.toString(),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
