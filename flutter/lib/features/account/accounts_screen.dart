import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/theme/atlas_theme.dart';
import '../groups/subscription_cabinet_screen.dart';

/// Subscription-first account index.
///
/// This deliberately replaces the legacy singleton account surface. A card is
/// always tied to exactly one subscription and opens that subscription's
/// profile/cabinet. Provider adapters may add billing capabilities; ordinary
/// feeds still expose their local, parsed subscription information.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ThemeColors.of(context);
    final subscriptions = ref.watch(subscriptionsProvider);

    return Scaffold(
      backgroundColor: colors.bgBase,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(subscriptionsProvider);
            await ref.read(subscriptionsProvider.future);
          },
          child: subscriptions.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => _AccountsError(
              onRetry: () => ref.invalidate(subscriptionsProvider),
            ),
            data: (rows) => _AccountsBody(subscriptions: rows),
          ),
        ),
      ),
    );
  }
}

class _AccountsBody extends StatelessWidget {
  const _AccountsBody({required this.subscriptions});

  final List<Subscription> subscriptions;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth >= 760 ? 820.0 : double.infinity;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Аккаунты',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: colors.textPrimary,
                                fontFamily: AtlasTheme.serifFamily,
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Профиль и кабинет привязаны к подписке. Откройте нужную подписку, чтобы посмотреть доступ, трафик, устройства и платежи.',
                      style:
                          TextStyle(color: colors.textSecondary, height: 1.35),
                    ),
                    const SizedBox(height: 20),
                    if (subscriptions.isEmpty)
                      _EmptyAccounts(colors: colors)
                    else
                      ...subscriptions.map(
                        (subscription) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _SubscriptionAccountCard(
                            subscription: subscription,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SubscriptionAccountCard extends StatelessWidget {
  const _SubscriptionAccountCard({required this.subscription});

  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    final title =
        subscription.name.isEmpty ? 'Безымянная подписка' : subscription.name;
    final isManaged = subscription.isProviderSource;
    final state =
        isManaged ? 'Профиль поставщика доступен' : 'Базовый профиль подписки';
    final detail = subscription.hasError
        ? 'Требуется обновление: ${subscription.lastError}'
        : isManaged
            ? 'Откройте кабинет для входа, доступа, устройств и платежей.'
            : 'Откройте профиль, чтобы посмотреть доступные сведения и подключить совместимый кабинет.';

    return Material(
      color: colors.bgCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                SubscriptionCabinetScreen(subscription: subscription),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: subscription.hasError
                  ? colors.danger.withValues(alpha: .55)
                  : colors.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AtlasTheme.accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  isManaged ? Icons.shield_outlined : Icons.rss_feed_outlined,
                  color: AtlasTheme.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      state,
                      style: TextStyle(
                        color: subscription.hasError
                            ? colors.danger
                            : AtlasTheme.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: colors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts({required this.colors});

  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          Icon(Icons.account_tree_outlined, size: 34, color: colors.textMuted),
          const SizedBox(height: 10),
          Text(
            'Пока нет подписок',
            style: TextStyle(
                color: colors.textPrimary, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            'Добавьте подписку на экране «Профили и маршруты». После этого здесь появится её профиль.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _AccountsError extends StatelessWidget {
  const _AccountsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sync_problem_outlined, color: colors.danger, size: 34),
            const SizedBox(height: 12),
            Text('Не удалось загрузить подписки',
                style: TextStyle(
                    color: colors.textPrimary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
