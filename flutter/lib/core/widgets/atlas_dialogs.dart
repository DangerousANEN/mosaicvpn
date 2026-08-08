import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';
import 'atlas_form_widgets.dart';

/// Shared dialog helpers for consistent styling across the app.

/// Confirmation dialog with customizable title, message, and button labels.
/// Returns true if confirmed, false (or null) if cancelled.
Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool danger = false,
  IconData? icon,
}) async {
  final c = ThemeColors.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
      title: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 24, color: danger ? c.danger : c.accent),
            const SizedBox(width: 10),
          ],
          Expanded(
              child: Text(title,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600))),
        ],
      ),
      content:
          Text(message, style: TextStyle(color: c.textSecondary, fontSize: 14)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel, style: TextStyle(color: c.textMuted)),
        ),
        AtlasButton(
            label: confirmLabel,
            onPressed: () => Navigator.of(ctx).pop(true),
            danger: danger,
            primary: danger),
      ],
    ),
  );
}

/// Input dialog with a single text field.
/// Returns the entered string, or null if cancelled.
Future<String?> showInputDialog({
  required BuildContext context,
  required String title,
  String? label,
  String? hint,
  String? initialValue,
  String confirmLabel = 'Save',
  String cancelLabel = 'Cancel',
  bool obscure = false,
  int maxLines = 1,
}) async {
  final c = ThemeColors.of(context);
  final controller = TextEditingController(text: initialValue);

  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
      title: Text(title,
          style: TextStyle(
              color: c.textPrimary, fontSize: 18, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 360,
        child: AtlasTextField(
          controller: controller,
          label: label,
          hint: hint,
          obscure: obscure,
          maxLines: maxLines,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: Text(cancelLabel, style: TextStyle(color: c.textMuted)),
        ),
        AtlasButton(
            label: confirmLabel,
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            primary: true),
      ],
    ),
  );
}

/// Info dialog — just a message with a single OK button.
Future<void> showInfoDialog({
  required BuildContext context,
  required String title,
  required String message,
  IconData? icon,
}) async {
  final c = ThemeColors.of(context);
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.bgCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
      title: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 24, color: c.accent),
            const SizedBox(width: 10),
          ],
          Expanded(
              child: Text(title,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600))),
        ],
      ),
      content:
          Text(message, style: TextStyle(color: c.textSecondary, fontSize: 14)),
      actions: [
        AtlasButton(
            label: 'OK',
            onPressed: () => Navigator.of(ctx).pop(),
            primary: true),
      ],
    ),
  );
}

/// Bottom sheet helper for quick actions.
Future<T?> showAtlasBottomSheet<T>({
  required BuildContext context,
  required String title,
  required List<AtlasSheetAction<T>> actions,
}) async {
  final c = ThemeColors.of(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: c.bgCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Text(title,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, size: 20, color: c.textMuted),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...actions.map((action) {
            return ListTile(
              leading: action.icon != null
                  ? Icon(action.icon,
                      size: 22,
                      color: action.danger ? c.danger : c.textSecondary)
                  : null,
              title: Text(action.label,
                  style: TextStyle(
                      color: action.danger ? c.danger : c.textPrimary,
                      fontSize: 14)),
              subtitle: action.subtitle != null
                  ? Text(action.subtitle!,
                      style: TextStyle(color: c.textMuted, fontSize: 12))
                  : null,
              onTap: () => Navigator.of(ctx).pop(action.value),
            );
          }),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class AtlasSheetAction<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool danger;

  const AtlasSheetAction({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.danger = false,
  });
}
