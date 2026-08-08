import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';

/// Shared form widgets for consistent styling across the app.

// ── AtlasSwitch ──────────────────────────────────────────────────────

class AtlasSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? subtitle;

  const AtlasSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.label,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Row(
      children: [
        if (label != null) ...[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label!,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: TextStyle(color: c.textMuted, fontSize: 12)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
        ],
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: c.accent,
          inactiveThumbColor: c.textMuted,
          inactiveTrackColor: c.bgChild,
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ],
    );
  }
}

// ── AtlasTextField ─────────────────────────────────────────────────

class AtlasTextField extends StatelessWidget {
  final String? label;
  final String? hint;
  final String? initialValue;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final bool obscure;
  final bool enabled;
  final int maxLines;
  final TextInputType? keyboardType;
  final Widget? suffix;
  final Widget? prefix;

  const AtlasTextField({
    super.key,
    this.label,
    this.hint,
    this.initialValue,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.obscure = false,
    this.enabled = true,
    this.maxLines = 1,
    this.keyboardType,
    this.suffix,
    this.prefix,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label!,
              style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: controller,
          onChanged: onChanged,
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
          obscureText: obscure,
          enabled: enabled,
          maxLines: maxLines,
          keyboardType: keyboardType,
          style: TextStyle(color: c.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: c.textMuted, fontSize: 14),
            filled: true,
            fillColor: c.bgChild,
            prefixIcon: prefix,
            suffixIcon: suffix,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              borderSide: BorderSide(color: c.border, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              borderSide: BorderSide(color: c.accent, width: 1.5),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              borderSide:
                  BorderSide(color: c.border.withValues(alpha: 0.5), width: 1),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }
}

// ── AtlasDropdown ──────────────────────────────────────────────────

class AtlasDropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownItem<T>> items;
  final ValueChanged<T>? onChanged;
  final String? label;

  const AtlasDropdown({
    super.key,
    required this.value,
    required this.items,
    this.onChanged,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label!,
              style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: c.bgChild,
            borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
            border: Border.all(color: c.border, width: 1),
          ),
          child: DropdownButton<T>(
            value: value,
            onChanged: onChanged == null
                ? null
                : (v) => v != null ? onChanged!(v) : null,
            isExpanded: true,
            underline: const SizedBox(),
            style: TextStyle(color: c.textPrimary, fontSize: 14),
            dropdownColor: c.bgCard,
            items: items.map((item) {
              return DropdownMenuItem<T>(
                value: item.value,
                child: Text(item.label),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class DropdownItem<T> {
  final T value;
  final String label;
  const DropdownItem({required this.value, required this.label});
}

// ── AtlasSlider ────────────────────────────────────────────────────

class AtlasSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final String? label;

  const AtlasSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChanged,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label!,
              style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
        ],
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: c.accent,
            inactiveTrackColor: c.bgChild,
            thumbColor: c.accent,
            overlayColor: c.accent.withValues(alpha: 0.2),
            trackHeight: 4,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

// ── AtlasButton ─────────────────────────────────────────────────────

class AtlasButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  final IconData? icon;
  final bool loading;
  final double? width;

  const AtlasButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = false,
    this.danger = false,
    this.icon,
    this.loading = false,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final color = danger ? c.danger : (primary ? c.accent : c.textSecondary);
    final bgColor = danger
        ? c.danger.withValues(alpha: 0.1)
        : primary
            ? c.accent
            : c.bgChild;

    return SizedBox(
      width: width,
      child: TextButton(
        onPressed: loading ? null : onPressed,
        style: TextButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
            side: BorderSide(
              color: danger
                  ? c.danger.withValues(alpha: 0.3)
                  : (primary ? Colors.transparent : c.border),
            ),
          ),
        ),
        child: loading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: color))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16),
                    const SizedBox(width: 6)
                  ],
                  Text(label,
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
      ),
    );
  }
}
