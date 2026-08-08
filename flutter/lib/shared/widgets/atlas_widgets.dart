import 'package:flutter/material.dart';
import '../../core/theme/atlas_theme.dart';

/// Atlas-style card container — aged parchment with faded map border.
class AtlasCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? height;
  final Color? backgroundColor;
  final bool elevated;

  const AtlasCard({
    super.key,
    required this.child,
    this.padding,
    this.height,
    this.backgroundColor,
    this.elevated = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: backgroundColor ?? c.bgCard,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
        border: Border.all(color: c.border),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: c.textPrimary.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// Dark ink panel — used for action buttons, headers, status indicators.
class InkPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? height;

  const InkPanel({
    super.key,
    required this.child,
    this.padding,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: c.bgInk,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
      ),
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// Atlas section header — serif text with decorative underline.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ),
            if (action != null) action!,
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: TextStyle(
              fontFamily: AtlasTheme.sansFamily,
              fontSize: 12,
              color: c.textMuted,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Container(
          height: 1,
          decoration: BoxDecoration(
            color: c.border,
          ),
        ),
      ],
    );
  }
}

/// Stat tile — metric in atlas style.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData? icon;
  final Color? valueColor;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit = '',
    this.icon,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.bgCard,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 9, color: c.textMuted),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                    color: c.textMuted,
                  ),
                ),
              ),
            ],
          ),
          Text(
            '$value${unit.isNotEmpty ? ' $unit' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AtlasTheme.monoFamily,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: valueColor ?? c.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Atlas-style status dot.
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;

  const StatusDot({
    super.key,
    required this.color,
    this.size = 10,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 2,
        ),
      ),
    );
  }
}

/// Latency indicator with color coding.
class LatencyBadge extends StatelessWidget {
  final int latencyMS;
  final bool failed;

  const LatencyBadge({
    super.key,
    required this.latencyMS,
    this.failed = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    if (failed) {
      return _badge('—', AtlasTheme.error, AtlasTheme.errorDim);
    }
    if (latencyMS <= 0) {
      return _badge('—', c.textMuted, c.bgHover);
    }
    Color color;
    Color bg;
    if (latencyMS < 80) {
      color = AtlasTheme.success;
      bg = AtlasTheme.successDim;
    } else if (latencyMS < 200) {
      color = AtlasTheme.warning;
      bg = AtlasTheme.warningDim;
    } else {
      color = AtlasTheme.error;
      bg = AtlasTheme.errorDim;
    }
    return _badge('${latencyMS}ms', color, bg);
  }

  Widget _badge(String text, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AtlasTheme.monoFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// Connection state toggle button — atlas style.
class ConnectToggle extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final VoidCallback onTap;

  const ConnectToggle({
    super.key,
    required this.connected,
    this.connecting = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final label = connecting
        ? 'Connecting…'
        : connected
            ? 'Disconnect'
            : 'Engage Tunnel »';

    final bgColor = connecting
        ? AtlasTheme.warning
        : connected
            ? AtlasTheme.error
            : c.bgInk;

    return GestureDetector(
      onTap: connecting ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
          border: Border.all(
            color: bgColor == c.bgInk ? c.borderInk : bgColor,
          ),
        ),
        child: Center(
          child: connecting
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.textOnInk,
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    fontFamily: AtlasTheme.sansFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: c.textOnInk,
                  ),
                ),
        ),
      ),
    );
  }
}
