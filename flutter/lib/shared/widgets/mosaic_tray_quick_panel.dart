import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/theme/atlas_theme.dart';

/// Branded desktop control surface opened by a primary click on the tray icon.
///
/// Native tray context menus are rendered by the operating system and cannot
/// reliably use Mosaic icons, cards or theme colors. This compact panel keeps
/// the native menu as a dependable right-click fallback while making the main
/// tray interaction recognizably MosaicVPN.
class MosaicTrayQuickPanel extends StatelessWidget {
  const MosaicTrayQuickPanel({
    super.key,
    required this.connected,
    required this.routeLabel,
    required this.onConnect,
    required this.onDisconnect,
    required this.onChooseRoute,
    required this.onOpenApp,
    required this.onDismiss,
  });

  final bool connected;
  final String routeLabel;
  final FutureOr<void> Function() onConnect;
  final FutureOr<void> Function() onDisconnect;
  final FutureOr<void> Function() onChooseRoute;
  final VoidCallback onOpenApp;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    final statusColor = connected ? AtlasTheme.success : AtlasTheme.warning;
    final statusText =
        connected ? s.t('tray_connected') : s.t('tray_disconnected');
    final statusHint =
        connected ? s.t('tray_protected_hint') : s.t('tray_ready_hint');

    return Semantics(
      container: true,
      label: s.t('tray_control_center'),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 344,
          decoration: BoxDecoration(
            color: c.bgInk,
            borderRadius: BorderRadius.circular(AtlasTheme.radiusLg),
            border: Border.all(color: c.borderInk),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 28,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AtlasTheme.accent,
                        borderRadius:
                            BorderRadius.circular(AtlasTheme.radiusMd),
                      ),
                      child: const Icon(Icons.shield_rounded,
                          color: AtlasTheme.onAccent, size: 23),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'MosaicVPN',
                            style: TextStyle(
                              color: AtlasTheme.textOnInk,
                              fontFamily: AtlasTheme.serifFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                            ),
                          ),
                          Text(
                            s.t('tray_control_center'),
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 11,
                              letterSpacing: .2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: s.t('close'),
                      onPressed: onDismiss,
                      icon: Icon(Icons.close_rounded,
                          color: c.textSecondary, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
                    border:
                        Border.all(color: statusColor.withValues(alpha: .36)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: statusColor.withValues(alpha: .45),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusText,
                              style: const TextStyle(
                                color: AtlasTheme.textOnInk,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              statusHint,
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _RouteRow(
                  label: routeLabel.isEmpty
                      ? s.t('tray_route_not_selected')
                      : routeLabel,
                  onPressed: () async {
                    await onChooseRoute();
                    onDismiss();
                  },
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 46,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          connected ? AtlasTheme.error : AtlasTheme.accent,
                      foregroundColor: AtlasTheme.onAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AtlasTheme.radiusMd),
                      ),
                    ),
                    onPressed: () async {
                      if (connected) {
                        await onDisconnect();
                      } else {
                        await onConnect();
                      }
                    },
                    icon: Icon(connected
                        ? Icons.power_settings_new_rounded
                        : Icons.shield_rounded),
                    label: Text(connected
                        ? s.t('disconnect_action')
                        : s.t('connect_action')),
                  ),
                ),
                const SizedBox(height: 7),
                TextButton.icon(
                  onPressed: onOpenApp,
                  icon: const Icon(Icons.open_in_new_rounded, size: 17),
                  label: Text(s.t('tray_open_app')),
                  style: TextButton.styleFrom(
                    foregroundColor: AtlasTheme.textOnInk,
                    alignment: Alignment.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({required this.label, required this.onPressed});

  final String label;
  final FutureOr<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
      onTap: () async => onPressed(),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: c.bgElevated,
          borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.route_outlined,
                color: AtlasTheme.accentHover, size: 19),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.t('routes').toUpperCase(),
                      style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .9)),
                  const SizedBox(height: 2),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AtlasTheme.textOnInk,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      )),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}
