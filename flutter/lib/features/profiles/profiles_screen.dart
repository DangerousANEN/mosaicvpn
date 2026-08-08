import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';

/// Profiles screen — Throne-style profile management.
/// Each profile is a named configuration bundle: server + tunnel mode +
/// DNS + routing rules + kill switch.
class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Profiles',
            subtitle: 'Named configurations with server, DNS, and routing',
            action: ElevatedButton.icon(
              onPressed: () => _showEditDialog(context, ref, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Profile'),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: profilesAsync.when(
              data: (profiles) {
                if (profiles.isEmpty) {
                  return _emptyState(context, ref);
                }
                return GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 2.8,
                  children: profiles
                      .map((p) => _ProfileCard(
                            profile: p,
                            ref: ref,
                            onEdit: () => _showEditDialog(context, ref, p),
                          ))
                      .toList(),
                );
              },
              loading: () => ListView.builder(
                  itemCount: 4,
                  itemBuilder: (_, __) =>
                      const Card(child: SkeletonServerRow())),
              error: (_, __) => _emptyState(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune, size: 48, color: c.textMuted),
          const SizedBox(height: 16),
          Text(
            'No profiles yet.',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 18,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a profile to bundle server, DNS, and routing settings.',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => _showEditDialog(context, ref, null),
            icon: const Icon(Icons.add),
            label: const Text('New Profile'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, Profile? existing) {
    final c = ThemeColors.of(context);
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final iconCtrl = TextEditingController(text: existing?.icon ?? '🛡');
    final colorCtrl = TextEditingController(text: existing?.color ?? '#6366F1');
    final tunnelMode = ValueNotifier<String>(existing?.tunnelMode ?? 'tun');
    final killSwitch = ValueNotifier<bool>(existing?.killSwitch ?? true);
    final allowLAN = ValueNotifier<bool>(existing?.allowLAN ?? true);
    final autoConnect = ValueNotifier<bool>(existing?.autoConnect ?? false);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: Text(
          existing == null ? 'New Profile' : 'Edit Profile',
          style: const TextStyle(fontFamily: AtlasTheme.serifFamily),
        ),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 60,
                      child: TextField(
                        controller: iconCtrl,
                        decoration: const InputDecoration(labelText: 'Icon'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(labelText: 'Name'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: colorCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Color (hex)',
                    hintText: '#6366F1',
                  ),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<String>(
                  valueListenable: tunnelMode,
                  builder: (_, v, __) => SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'tun', label: Text('TUN')),
                      ButtonSegment(value: 'proxy', label: Text('Proxy')),
                    ],
                    selected: {v},
                    onSelectionChanged: (s) => tunnelMode.value = s.first,
                  ),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<bool>(
                  valueListenable: killSwitch,
                  builder: (_, v, __) => SwitchListTile(
                    title: const Text('Kill Switch'),
                    value: v,
                    onChanged: (n) => killSwitch.value = n,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: allowLAN,
                  builder: (_, v, __) => SwitchListTile(
                    title: const Text('Allow LAN'),
                    value: v,
                    onChanged: (n) => allowLAN.value = n,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: autoConnect,
                  builder: (_, v, __) => SwitchListTile(
                    title: const Text('Auto-connect on startup'),
                    value: v,
                    onChanged: (n) => autoConnect.value = n,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.isEmpty) return;
              final api = ref.read(daemonApiProvider);
              final data = {
                'name': nameCtrl.text,
                'icon': iconCtrl.text,
                'color': colorCtrl.text,
                'tunnel_mode': tunnelMode.value,
                'kill_switch': killSwitch.value,
                'allow_lan': allowLAN.value,
                'auto_connect': autoConnect.value,
              };
              if (existing == null) {
                await api.createProfile(data);
              } else {
                await api.updateProfile(existing.id, data);
              }
              ref.invalidate(profilesProvider);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(existing == null ? 'Create' : 'Save'),
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final Profile profile;
  final WidgetRef ref;
  final VoidCallback? onEdit;

  const _ProfileCard({
    required this.profile,
    required this.ref,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              // Icon avatar
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _parseColor(profile.color).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  border: Border.all(
                    color: _parseColor(profile.color).withValues(alpha: 0.3),
                  ),
                ),
                child: Center(
                  child: Text(
                    profile.icon,
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: const TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${profile.tunnelMode.toUpperCase()} · '
                      '${profile.killSwitch ? "Kill SW" : "No Kill"} · '
                      '${profile.ruleIDs.length} rules',
                      style: TextStyle(
                        fontSize: 10,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // Actions
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) async {
                  final api = ref.read(daemonApiProvider);
                  switch (v) {
                    case 'activate':
                      await api.activateProfile(profile.id);
                      ref.invalidate(profilesProvider);
                      ref.invalidate(vpnStatusProvider);
                    case 'edit':
                      onEdit?.call();
                      break;
                    case 'delete':
                      await api.deleteProfile(profile.id);
                      ref.invalidate(profilesProvider);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'activate', child: Text('Activate')),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Config badges
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _configBadge('DNS: ${profile.dns.mode}', AtlasTheme.info),
              if (profile.autoConnect) _configBadge('Auto', AtlasTheme.success),
              if (profile.allowLAN) _configBadge('LAN', AtlasTheme.accent),
            ],
          ),
        ],
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return AtlasTheme.accent;
    }
  }

  Widget _configBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}
