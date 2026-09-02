import 'package:flutter/material.dart';
import '../../core/models/models.dart';
import '../../core/theme/atlas_theme.dart';
import '../../core/utils/formatters.dart';

class DashboardFacts extends StatelessWidget {
  final VpnStatus status;
  final List<Object> routes;

  const DashboardFacts({super.key, required this.status, required this.routes});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final route = status.server?.name ??
        (status.activeGroupId.isEmpty ? 'Не выбран' : status.activeGroupId);
    final session = status.connectedSince == null
        ? '—'
        : formatDuration(DateTime.now().difference(status.connectedSince!));
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: c.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: c.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Сводка подключения',
            style:
                TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary)),
        const SizedBox(height: 14),
        _fact(c, Icons.route_outlined, 'Маршрут', route),
        _fact(c, Icons.network_ping_outlined, 'Задержка',
            status.latencyMS > 0 ? '${status.latencyMS} мс' : 'Не проверена'),
        _fact(c, Icons.swap_vert_rounded, 'Трафик',
            '${formatBytes(status.bytesIn + status.bytesOut)} за сессию'),
        _fact(c, Icons.timer_outlined, 'Сессия', session),
        _fact(
            c,
            status.tunnelMode == 'tun'
                ? Icons.vpn_lock_outlined
                : Icons.settings_input_component,
            'Режим',
            status.tunnelMode == 'tun' ? 'TUN' : 'Прокси'),
        _fact(c, Icons.shield_outlined, 'Защита утечек',
            status.killSwitch ? 'Включена' : 'Выключена'),
      ]),
    );
  }

  Widget _fact(ThemeColors c, IconData icon, String label, String value) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Icon(icon, size: 17, color: c.accent),
          const SizedBox(width: 9),
          Expanded(
              child: Text(label,
                  style: TextStyle(color: c.textSecondary, fontSize: 12))),
          Text(value,
              style: TextStyle(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12))
        ]),
      );
}
