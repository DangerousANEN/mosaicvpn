import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../shared/widgets/atlas_widgets.dart';

import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';

/// Cores screen — manage VPN engine binaries (sing-box, xray, etc.).
class CoresScreen extends ConsumerStatefulWidget {
  const CoresScreen({super.key});

  @override
  ConsumerState<CoresScreen> createState() => _CoresScreenState();
}

class _CoresScreenState extends ConsumerState<CoresScreen> {
  final _cores = <_CoreEntry>[
    _CoreEntry(
      name: 'sing-box',
      version: '1.11.4',
      path: '/usr/local/bin/sing-box',
      active: true,
    ),
    _CoreEntry(
      name: 'xray-core',
      version: '25.7.14',
      path: '/usr/local/bin/xray',
      active: false,
    ),
    _CoreEntry(
      name: 'hysteria2',
      version: '2.6.3',
      path: '/usr/local/bin/hysteria',
      active: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final prefs = ref.watch(prefsProvider).valueOrNull;
    final activeEngine = prefs?.coreEngine ?? 'sing-box';

    // Sync active state from preferences
    for (final entry in _cores) {
      entry.active = (entry.name.toLowerCase() == activeEngine.toLowerCase());
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Cores & Engines',
            subtitle: 'VPN engine binaries managed by the daemon',
            action: ElevatedButton.icon(
              onPressed: _showAddDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Core'),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: _cores.length,
              separatorBuilder: (_, __) => Divider(color: c.border, height: 1),
              itemBuilder: (context, i) => _CoreTile(
                core: _cores[i],
                onActivate: () async {
                  setState(() {
                    for (final item in _cores) {
                      item.active = false;
                    }
                    _cores[i].active = true;
                  });
                  final current = prefs ?? Preferences();
                  final updated = current.copyWith(coreEngine: _cores[i].name);
                  try {
                    await ref.read(daemonApiProvider).setPrefs(updated.toJson());
                    ref.invalidate(prefsProvider);
                  } catch (e) {
                    debugPrint('core engine switch failed: $e');
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddDialog() {
    final c = ThemeColors.of(context);
    final nameCtrl = TextEditingController();
    final pathCtrl = TextEditingController();

    void disposeCtrls() {
      nameCtrl.dispose();
      pathCtrl.dispose();
    }

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: const Text(
          'Add Core Binary',
          style: TextStyle(fontFamily: AtlasTheme.serifFamily),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Core Name',
                  hintText: 'sing-box',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pathCtrl,
                decoration: const InputDecoration(
                  labelText: 'Binary Path',
                  hintText: '/usr/local/bin/sing-box',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              nameCtrl.dispose();
              pathCtrl.dispose();
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.isEmpty) return;
              setState(() {
                _cores.add(_CoreEntry(
                  name: nameCtrl.text,
                  version: '—',
                  path: pathCtrl.text,
                  active: false,
                ));
              });
              nameCtrl.dispose();
              pathCtrl.dispose();
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ).whenComplete(disposeCtrls);
  }
}

class _CoreEntry {
  String name;
  String version;
  String path;
  bool active;

  _CoreEntry({
    required this.name,
    required this.version,
    required this.path,
    required this.active,
  });
}

class _CoreTile extends StatelessWidget {
  final _CoreEntry core;
  final VoidCallback onActivate;

  const _CoreTile({required this.core, required this.onActivate});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AtlasCard(
      child: Row(
        children: [
          // Icon
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: core.active ? AtlasTheme.successDim : c.bgElevated,
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
              border: Border.all(
                color: core.active
                    ? AtlasTheme.success.withValues(alpha: 0.3)
                    : c.border,
              ),
            ),
            child: Icon(
              Icons.memory,
              color: core.active ? AtlasTheme.success : c.textMuted,
            ),
          ),
          const SizedBox(width: 16),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      core.name,
                      style: const TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (core.active)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AtlasTheme.successDim,
                          borderRadius:
                              BorderRadius.circular(AtlasTheme.radiusSm),
                        ),
                        child: const Text(
                          'ACTIVE',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: AtlasTheme.success,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'v${core.version}',
                  style: TextStyle(
                    fontFamily: AtlasTheme.monoFamily,
                    fontSize: 11,
                    color: c.textSecondary,
                  ),
                ),
                Text(
                  core.path,
                  style: TextStyle(
                    fontFamily: AtlasTheme.monoFamily,
                    fontSize: 10,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),

          // Activate button
          if (!core.active)
            ElevatedButton(
              onPressed: onActivate,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('Activate'),
            ),
        ],
      ),
    );
  }
}
