import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';
import '../../shared/widgets/atlas_widgets.dart';

/// Provider Manifest provider — fetches /v1/manifest from the Go daemon.
final providerManifestProvider =
    FutureProvider.autoDispose<ProviderManifest>((ref) async {
  final api = ref.read(daemonApiProvider);
  return api.getProviderManifest();
});

/// ProviderProfileScreen — displays the provider-defined profile section:
/// branding, billing info, service cards, and stats widgets.
///
/// This screen renders entirely from the backend-driven [ProviderManifest]
/// and requires no hard-coded UI content — all titles, descriptions, and
/// actions come from the manifest JSON.
class ProviderProfileScreen extends ConsumerWidget {
  const ProviderProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    final manifestAsync = ref.watch(providerManifestProvider);

    return Scaffold(
      backgroundColor: c.bgBase,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Provider Profile',
              subtitle: 'Branding, billing, and services — driven by the provider manifest',
              action: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh Manifest',
                onPressed: () => ref.invalidate(providerManifestProvider),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: manifestAsync.when(
                data: (manifest) => _ManifestContent(manifest: manifest),
                loading: () => const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (err, _) => _ManifestError(
                  error: err,
                  onRetry: () => ref.invalidate(providerManifestProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManifestContent extends StatelessWidget {
  final ProviderManifest manifest;

  const _ManifestContent({required this.manifest});

  @override
  Widget build(BuildContext context) {
    final profile = manifest.profile;
    if (profile == null) {
      return Center(
        child: Text(
          'No provider profile in manifest',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Branding header ──
          _BrandingCard(branding: profile.branding, providerName: manifest.providerName),
          const SizedBox(height: 16),

          // ── Node groups overview ──
          if (manifest.groups.isNotEmpty) ...[
            _GroupsCard(groups: manifest.groups),
            const SizedBox(height: 16),
          ],

          // ── Billing info ──
          if (profile.billing != null) ...[
            _BillingCard(billing: profile.billing!),
            const SizedBox(height: 16),
          ],

          // ── Service cards ──
          if (profile.services.isNotEmpty) ...[
            Text('Services',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: ThemeColors.of(context).textPrimary,
                      fontWeight: FontWeight.w600,
                    )),
            const SizedBox(height: 8),
            ...profile.services.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ServiceCard(service: s),
                )),
          ],
        ],
      ),
    );
  }
}

class _BrandingCard extends StatelessWidget {
  final ProviderBranding branding;
  final String providerName;

  const _BrandingCard({required this.branding, required this.providerName});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusLg),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Row(
        children: [
          // Logo placeholder
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AtlasTheme.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
            ),
            child: branding.logoUrl.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
                    child: Image.network(branding.logoUrl, fit: BoxFit.cover),
                  )
                : Icon(Icons.vpn_lock, color: AtlasTheme.accent, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(providerName,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w700,
                        )),
                if (branding.providerDescription.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(branding.providerDescription,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: c.textMuted,
                            )),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupsCard extends StatelessWidget {
  final List<ManifestGroup> groups;

  const _GroupsCard({required this.groups});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusLg),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Node Groups',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                  )),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: groups.map((g) {
              final isPremium = g.userTier == 'premium';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isPremium
                      ? AtlasTheme.accent.withValues(alpha: 0.12)
                      : c.bgBase,
                  borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  border: Border.all(
                    color: isPremium
                        ? AtlasTheme.accent.withValues(alpha: 0.3)
                        : c.border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (g.badge.isNotEmpty) ...[
                      Text(g.badge,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isPremium ? AtlasTheme.accent : c.textMuted,
                          )),
                      const SizedBox(width: 6),
                    ],
                    Text(g.title,
                        style: TextStyle(
                          fontSize: 13,
                          color: c.textPrimary,
                        )),
                    if (isPremium) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.star, size: 12, color: AtlasTheme.accent),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _BillingCard extends StatelessWidget {
  final ProviderBilling billing;

  const _BillingCard({required this.billing});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusLg),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet, size: 20, color: AtlasTheme.accent),
              const SizedBox(width: 8),
              Text('Billing',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                      )),
            ],
          ),
          const SizedBox(height: 12),
          // Pricing rows
          if (billing.pricePerDay.isNotEmpty) ...[
            ...billing.pricePerDay.entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${e.key} day${e.key == '1' ? '' : 's'}',
                          style: TextStyle(color: c.textMuted, fontSize: 13)),
                      Text('${e.value.toStringAsFixed(0)} ₽',
                          style: TextStyle(
                              color: c.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ],
                  ),
                )),
            const SizedBox(height: 8),
          ],
          // Payment methods
          if (billing.paymentMethods.isNotEmpty)
            Wrap(
              spacing: 6,
              children: billing.paymentMethods.map((m) => Chip(
                    label: Text(m, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                  )).toList(),
            ),
          if (billing.trialDays > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.card_giftcard, size: 14, color: AtlasTheme.accent),
                const SizedBox(width: 4),
                Text('${billing.trialDays} day trial available',
                    style: TextStyle(
                        color: AtlasTheme.accent, fontSize: 12)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final ProviderService service;

  const _ServiceCard({required this.service});

  IconData _iconFor(String name) {
    switch (name) {
      case 'support_agent':
        return Icons.support_agent;
      case 'speed':
        return Icons.speed;
      case 'link':
        return Icons.open_in_new;
      case 'security':
        return Icons.security;
      default:
        return Icons.extension;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Row(
        children: [
          Icon(_iconFor(service.icon), size: 22, color: AtlasTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(service.title,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                if (service.description.isNotEmpty)
                  Text(service.description,
                      style: TextStyle(color: c.textMuted, fontSize: 12)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

class _ManifestError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ManifestError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: c.textMuted),
          const SizedBox(height: 12),
          Text('Failed to load provider manifest',
              style: TextStyle(color: c.textPrimary, fontSize: 14)),
          const SizedBox(height: 4),
          Text(error.toString(),
              style: TextStyle(color: c.textMuted, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
