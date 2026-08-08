import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/models.dart';
import '../../core/providers/billing_provider.dart';
import '../../core/theme/atlas_theme.dart';
import '../../core/widgets/atlas_form_widgets.dart';

/// Show dialog to link a Telegram account.
Future<void> showLinkAccountDialog(BuildContext context, WidgetRef ref) async {
  final c = ThemeColors.of(context);
  final telegramIdController = TextEditingController();
  final tokenController = TextEditingController();
  String? errorMsg;
  bool loading = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: c.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
              side: BorderSide(color: c.border),
            ),
            title: Row(
              children: [
                Icon(Icons.telegram, size: 24, color: c.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Link Telegram Account',
                    style: TextStyle(
                      fontFamily: AtlasTheme.serifFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter your Telegram Numeric ID and optional Session Token obtained from @mosaicvpnbot.',
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  AtlasTextField(
                    controller: telegramIdController,
                    label: 'Telegram User ID',
                    hint: 'e.g. 123456789',
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  AtlasTextField(
                    controller: tokenController,
                    label: 'Session Token (Optional)',
                    hint: 'Token from @mosaicvpnbot',
                  ),
                  if (errorMsg != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: c.danger.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, size: 16, color: c.danger),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errorMsg!,
                              style: TextStyle(fontSize: 12, color: c.danger),
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
                onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                child: Text('Cancel', style: TextStyle(color: c.textMuted)),
              ),
              AtlasButton(
                label: 'Link Account',
                primary: true,
                loading: loading,
                onPressed: () async {
                  final idStr = telegramIdController.text.trim();
                  final telegramId = int.tryParse(idStr);
                  if (telegramId == null || telegramId <= 0) {
                    setState(() {
                      errorMsg = 'Please enter a valid numeric Telegram ID.';
                    });
                    return;
                  }

                  setState(() {
                    loading = true;
                    errorMsg = null;
                  });

                  final token = tokenController.text.trim();
                  final success = await ref
                      .read(billingNotifierProvider.notifier)
                      .linkAccount(telegramId,
                          sessionToken: token.isNotEmpty ? token : null);

                  if (ctx.mounted) {
                    if (success) {
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Telegram account linked successfully!'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    } else {
                      setState(() {
                        loading = false;
                        errorMsg = 'Failed to link account. Check details.';
                      });
                    }
                  }
                },
              ),
            ],
          );
        },
      );
    },
  );
}

/// Quick preset for CryptoBot Top-Up.
class TopupPreset {
  final double amount;
  final int days;
  final String label;

  const TopupPreset({
    required this.amount,
    required this.days,
    required this.label,
  });
}

const List<TopupPreset> defaultTopupPresets = [
  TopupPreset(amount: 3.0, days: 30, label: '\$3 / 30 Days'),
  TopupPreset(amount: 5.0, days: 60, label: '\$5 / 60 Days'),
  TopupPreset(amount: 10.0, days: 120, label: '\$10 / 120 Days'),
  TopupPreset(amount: 20.0, days: 360, label: '\$20 / 360 Days'),
];

/// Show CryptoBot Top-Up modal/dialog.
Future<void> showTopupDialog(BuildContext context, WidgetRef ref) async {
  final c = ThemeColors.of(context);
  double selectedAmount = 5.0;
  int selectedDays = 60;
  final amountController = TextEditingController(text: '5.0');
  final daysController = TextEditingController(text: '60');
  final descController = TextEditingController();
  bool isCustom = false;
  String? errorMsg;
  bool loading = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: c.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
              side: BorderSide(color: c.border),
            ),
            title: Row(
              children: [
                Icon(Icons.currency_bitcoin, size: 24, color: c.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'CryptoBot Top-Up',
                    style: TextStyle(
                      fontFamily: AtlasTheme.serifFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select a subscription package or enter a custom amount (USDT) to top up via CryptoBot.',
                      style: TextStyle(fontSize: 13, color: c.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Popular Packages',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: defaultTopupPresets.map((preset) {
                        final isSelected = !isCustom &&
                            selectedAmount == preset.amount &&
                            selectedDays == preset.days;
                        return ChoiceChip(
                          label: Text(preset.label),
                          selected: isSelected,
                          selectedColor: c.accent,
                          backgroundColor: c.bgChild,
                          labelStyle: TextStyle(
                            color: isSelected ? c.textOnInk : c.textPrimary,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12,
                          ),
                          onSelected: (selected) {
                            if (selected) {
                              setState(() {
                                isCustom = false;
                                selectedAmount = preset.amount;
                                selectedDays = preset.days;
                                amountController.text = preset.amount.toStringAsFixed(1);
                                daysController.text = preset.days.toString();
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Checkbox(
                          value: isCustom,
                          activeColor: c.accent,
                          onChanged: (val) {
                            setState(() {
                              isCustom = val ?? false;
                            });
                          },
                        ),
                        Text(
                          'Custom amount',
                          style: TextStyle(fontSize: 13, color: c.textPrimary),
                        ),
                      ],
                    ),
                    if (isCustom) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: AtlasTextField(
                              controller: amountController,
                              label: 'Amount (USDT)',
                              hint: '5.00',
                              keyboardType:
                                  const TextInputType.numberWithOptions(decimal: true),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AtlasTextField(
                              controller: daysController,
                              label: 'Days',
                              hint: '30',
                              keyboardType: TextInputType.number,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    AtlasTextField(
                      controller: descController,
                      label: 'Note / Description (Optional)',
                      hint: 'MosaicVPN subscription top-up',
                    ),
                    if (errorMsg != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: c.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                          border: Border.all(color: c.danger.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, size: 16, color: c.danger),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                errorMsg!,
                                style: TextStyle(fontSize: 12, color: c.danger),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                child: Text('Cancel', style: TextStyle(color: c.textMuted)),
              ),
              AtlasButton(
                label: 'Create Invoice',
                primary: true,
                icon: Icons.receipt_long,
                loading: loading,
                onPressed: () async {
                  double amt;
                  int d;
                  if (isCustom) {
                    final amtVal = double.tryParse(amountController.text.trim());
                    final daysVal = int.tryParse(daysController.text.trim());
                    if (amtVal == null || amtVal <= 0) {
                      setState(() {
                        errorMsg = 'Enter a valid positive amount.';
                      });
                      return;
                    }
                    amt = amtVal;
                    d = daysVal ?? 0;
                  } else {
                    amt = selectedAmount;
                    d = selectedDays;
                  }

                  setState(() {
                    loading = true;
                    errorMsg = null;
                  });

                  final desc = descController.text.trim();
                  final response = await ref
                      .read(billingNotifierProvider.notifier)
                      .createTopup(
                        amount: amt,
                        days: d > 0 ? d : null,
                        description: desc.isNotEmpty ? desc : null,
                      );

                  if (ctx.mounted) {
                    if (response != null) {
                      Navigator.of(ctx).pop();
                      await showInvoiceDetailsDialog(context, ref, response);
                    } else {
                      setState(() {
                        loading = false;
                        errorMsg = 'Failed to create invoice. Check connection.';
                      });
                    }
                  }
                },
              ),
            ],
          );
        },
      );
    },
  );
}

/// Show dialog with created CryptoBot Invoice details & payment link.
Future<void> showInvoiceDetailsDialog(
  BuildContext context,
  WidgetRef ref,
  TopupResponse invoice,
) async {
  final c = ThemeColors.of(context);
  String? statusText;
  bool checking = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: c.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
              side: BorderSide(color: c.border),
            ),
            title: Row(
              children: [
                Icon(Icons.check_circle_outline, size: 24, color: c.success),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Invoice #${invoice.invoiceId}',
                    style: TextStyle(
                      fontFamily: AtlasTheme.serifFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.bgElevated,
                      borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                      border: Border.all(color: c.border),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'AMOUNT TO PAY',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                            color: c.textMuted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${invoice.amount} ${invoice.asset}',
                          style: TextStyle(
                            fontFamily: AtlasTheme.monoFamily,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: c.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Pay URL / Telegram Invoice',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: c.bgChild,
                      borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            invoice.payUrl,
                            style: TextStyle(
                              fontFamily: AtlasTheme.monoFamily,
                              fontSize: 12,
                              color: c.textPrimary,
                            ),
                            maxLines: 1,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.copy, size: 18, color: c.accent),
                          tooltip: 'Copy URL',
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: invoice.payUrl),
                            );
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('Pay URL copied to clipboard!'),
                                  behavior: SnackBarBehavior.floating,
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (statusText != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: statusText == 'paid'
                            ? c.success.withValues(alpha: 0.15)
                            : c.warning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                        border: Border.all(
                          color: statusText == 'paid' ? c.success : c.warning,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            statusText == 'paid'
                                ? Icons.check_circle
                                : Icons.hourglass_empty,
                            size: 18,
                            color: statusText == 'paid' ? c.success : c.warning,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              statusText == 'paid'
                                  ? 'Payment received! Your subscription has been updated.'
                                  : 'Invoice status: $statusText',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: statusText == 'paid' ? c.success : c.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: checking
                              ? null
                              : () async {
                                  setState(() => checking = true);
                                  final st = await ref
                                      .read(billingNotifierProvider.notifier)
                                      .checkTopupStatus(invoice.invoiceId);
                                  if (ctx.mounted) {
                                    setState(() {
                                      checking = false;
                                      statusText = st?.status ?? 'unknown';
                                    });
                                  }
                                },
                          icon: checking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.refresh, size: 16),
                          label: const Text('Check Status'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final uri = Uri.tryParse(invoice.payUrl);
                            if (uri != null && await canLaunchUrl(uri)) {
                              await launchUrl(uri,
                                  mode: LaunchMode.externalApplication);
                            } else {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                    content: Text('Could not launch payment URL'),
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('Pay CryptoBot'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              AtlasButton(
                label: 'Close',
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          );
        },
      );
    },
  );
}
