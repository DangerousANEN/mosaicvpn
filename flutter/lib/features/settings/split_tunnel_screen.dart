import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/services/android_vpn_service.dart';
import '../../core/theme/atlas_theme.dart';

class SplitTunnelScreen extends ConsumerStatefulWidget {
  const SplitTunnelScreen({super.key});

  @override
  ConsumerState<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends ConsumerState<SplitTunnelScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _installedApps = [];
  Set<String> _selectedPackages = {};
  String _mode = 'bypass'; // 'bypass' (exclude from vpn) | 'proxy' (only through vpn)
  bool _isLoading = true;
  bool _showSystemApps = false;
  String _filter = '';

  static const List<String> _kRussianBankPackages = [
    'ru.sberbankmobile',
    'com.idamob.tinkoff.android',
    'ru.vtb24.mobilebanking.android',
    'ru.alfabank.mobile.android',
    'ru.raiffeisennews',
    'ru.gazprombank.android.mobilebank.app',
    'ru.sngb.dbo.client.android',
    'ru.ftc.faktura.multibank',
    'ru.gosuslugi.gosexpress',
    'ru.rosneft.smarta',
    'ru.yandex.yandexmaps',
    'ru.yandex.taxi',
    'com.wildberries.wb',
    'ru.ozon.app.android',
    'com.avito.android',
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _filter = _searchController.text.trim().toLowerCase());
    });
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final apps = await AndroidVpnService.instance.getInstalledApps();
    try {
      final prefs = await ref.read(daemonApiProvider).getPrefs();
      _selectedPackages = prefs.bypassProcesses.toSet();
      if (prefs.proxyPackages.isNotEmpty) {
        _selectedPackages = prefs.proxyPackages.toSet();
        _mode = 'proxy';
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _installedApps = apps;
        _isLoading = false;
      });
    }
  }

  Future<void> _savePreferences() async {
    try {
      final api = ref.read(daemonApiProvider);
      final current = await api.getPrefs();
      final updated = current.copyWith(
        bypassProcesses: _mode == 'bypass' ? _selectedPackages.toList() : const [],
        proxyPackages: _mode == 'proxy' ? _selectedPackages.toList() : const [],
      );
      await api.setPrefs(updated.toJson());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Настройки разделения трафика сохранены'),
            backgroundColor: AtlasTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка сохранения: $e'),
            backgroundColor: AtlasTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _applyRussianPreset() {
    setState(() {
      _mode = 'bypass';
      _selectedPackages.addAll(_kRussianBankPackages);
    });
    _savePreferences();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final filtered = _installedApps.where((app) {
      if (!_showSystemApps && app['isSystem'] == true) return false;
      if (_filter.isEmpty) return true;
      final name = (app['name'] as String).toLowerCase();
      final pkg = (app['package'] as String).toLowerCase();
      return name.contains(_filter) || pkg.contains(_filter);
    }).toList();

    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(
        backgroundColor: c.bgElevated,
        elevation: 0,
        title: Text(
          'Разделение трафика',
          style: TextStyle(
            fontFamily: AtlasTheme.serifFamily,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_rounded),
            tooltip: 'Сохранить',
            onPressed: _savePreferences,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  color: c.bgElevated,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'РЕЖИМ МАРШРУТИЗАЦИИ ПРИЛОЖЕНИЙ',
                        style: TextStyle(
                          color: AtlasTheme.accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _ModeChip(
                              label: 'Исключить из VPN',
                              subtitle: 'Работают напрямую',
                              selected: _mode == 'bypass',
                              onTap: () {
                                setState(() => _mode = 'bypass');
                                _savePreferences();
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ModeChip(
                              label: 'Только через VPN',
                              subtitle: 'Остальные напрямую',
                              selected: _mode == 'proxy',
                              onTap: () {
                                setState(() => _mode = 'proxy');
                                _savePreferences();
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _applyRussianPreset,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AtlasTheme.accent.withValues(alpha: .12),
                          foregroundColor: AtlasTheme.accent,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: AtlasTheme.accent.withValues(alpha: .3),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.account_balance_rounded, size: 18),
                        label: const Text(
                          'Исключить банки РФ и Госуслуги в 1 клик',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              style: TextStyle(color: c.textPrimary, fontSize: 13.5),
                              decoration: InputDecoration(
                                hintText: 'Поиск приложений...',
                                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                                prefixIcon: Icon(Icons.search_rounded,
                                    size: 18, color: c.textMuted),
                                filled: true,
                                fillColor: c.bgCard,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: c.border),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: c.border),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilterChip(
                            label: const Text('Системные', style: TextStyle(fontSize: 11.5)),
                            selected: _showSystemApps,
                            onSelected: (val) => setState(() => _showSystemApps = val),
                            backgroundColor: c.bgCard,
                            selectedColor: AtlasTheme.accent.withValues(alpha: .2),
                            checkmarkColor: AtlasTheme.accent,
                            labelStyle: TextStyle(
                              color: _showSystemApps ? AtlasTheme.accent : c.textSecondary,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(color: c.border),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Выбрано: ${_selectedPackages.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.textMuted,
                        ),
                      ),
                      if (_selectedPackages.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setState(() => _selectedPackages.clear());
                            _savePreferences();
                          },
                          child: Text(
                            'Сбросить выбор',
                            style: TextStyle(fontSize: 12, color: AtlasTheme.accent),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final app = filtered[index];
                      final pkg = app['package'] as String;
                      final name = app['name'] as String;
                      final isSelected = _selectedPackages.contains(pkg);

                      return CheckboxListTile(
                        value: isSelected,
                        activeColor: AtlasTheme.accent,
                        checkColor: AtlasTheme.onAccent,
                        title: Text(
                          name.isEmpty ? pkg : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          pkg,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.textMuted),
                        ),
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selectedPackages.add(pkg);
                            } else {
                              _selectedPackages.remove(pkg);
                            }
                          });
                          _savePreferences();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Material(
      color: selected ? AtlasTheme.accent : c.bgCard,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AtlasTheme.accent : c.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? AtlasTheme.onAccent : c.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 10,
                  color: selected ? AtlasTheme.onAccent.withValues(alpha: .8) : c.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
