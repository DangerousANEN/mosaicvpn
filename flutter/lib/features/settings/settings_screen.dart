import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/models.dart';
import '../../core/services/tray_service.dart';
import '../../core/services/autostart_service.dart';
import '../../core/config/app_config.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/skeleton_loader.dart';

/// Settings screen — tunnel, proxy, DNS, startup, MCP configuration.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Preferences? _localPrefs;

  // WARP state (loaded from daemon; separate from Preferences)
  bool _warpEnabled = false;
  String _warpMode = 'warp';
  String _warpLicenseKey = '';
  bool _warpLoaded = false;

  Future<void> _ensureWarpLoaded() async {
    if (_warpLoaded) return;
    try {
      final api = ref.read(daemonApiProvider);
      final warp = await api.getWARP();
      _warpEnabled = warp.enabled;
      _warpMode = warp.mode.isNotEmpty ? warp.mode : 'warp';
      _warpLicenseKey = warp.licenseKey;
      _warpLoaded = true;
    } catch (_) {
      _warpLoaded = true; // fail silently
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(prefsProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: prefsAsync.when(
        data: (remotePrefs) {
          if (!_warpLoaded) _ensureWarpLoaded();
          final prefs = _localPrefs ?? remotePrefs;
          return _buildSettings(context, prefs);
        },
        loading: () => _localPrefs != null
            ? _buildSettings(context, _localPrefs!)
            : ListView.builder(
                itemCount: 6,
                itemBuilder: (_, __) => const Card(child: SkeletonServerRow())),
        error: (_, __) => _buildSettings(context, _localPrefs ?? Preferences()),
      ),
    );
  }

  Widget _buildSettings(BuildContext context, Preferences prefs) {
    final c = ThemeColors.of(context);
    final s = AppStrings.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
              title: s.t('settings'), subtitle: s.t('daemon_configuration')),

          const SizedBox(height: 24),

          // ── Tunnel ──
          _SettingsGroup(
            title: 'Tunnel',
            children: [
              // Tunnel mode
              _SettingTile(
                label: 'Tunnel Mode',
                description: 'TUN (system-wide) or Proxy (SOCKS/HTTP only)',
                tooltip:
                    'TUN mode captures all system traffic through a virtual network adapter (requires admin). Proxy mode only routes apps configured to use the local SOCKS/HTTP proxy.',
                difficulty: 2,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'tun', label: Text('TUN')),
                    ButtonSegment(value: 'proxy', label: Text('Proxy')),
                  ],
                  selected: {prefs.tunnelMode},
                  onSelectionChanged: (s) {
                    if (s.first == 'tun' && prefs.tunnelMode != 'tun') {
                      _checkTunElevation(context, () {
                        _update(prefs, tunnelMode: 'tun');
                      });
                    } else {
                      _update(prefs, tunnelMode: s.first);
                    }
                  },
                ),
              ),
              // MTU (TUN only)
              if (prefs.tunnelMode == 'tun')
                _SettingTile(
                  label: 'MTU',
                  description: 'Maximum transmission unit for the TUN device',
                  tooltip:
                      'Larger MTU = more throughput but may cause fragmentation on some networks. 1420 is safe for most VPNs. Lower to 1280 if you experience packet loss.',
                  difficulty: 3,
                  child: SizedBox(
                    width: 120,
                    child: TextFormField(
                      initialValue: prefs.mtu.toString(),
                      decoration: const InputDecoration(suffix: Text('bytes')),
                      onChanged: (v) =>
                          _update(prefs, mtu: int.tryParse(v) ?? 1420),
                    ),
                  ),
                ),
              // Mixed port (proxy only)
              if (prefs.tunnelMode == 'proxy')
                _SettingTile(
                  label: 'Mixed Port',
                  description: 'Single port for both SOCKS5 and HTTP proxy',
                  tooltip:
                      'The local port that SOCKS5 and HTTP proxy listeners share. Change if another app occupies 2080.',
                  difficulty: 1,
                  child: SizedBox(
                    width: 120,
                    child: TextFormField(
                      initialValue: prefs.mixedPort.toString(),
                      decoration: const InputDecoration(suffix: Text('port')),
                      onChanged: (v) =>
                          _update(prefs, mixedPort: int.tryParse(v) ?? 2080),
                    ),
                  ),
                ),
              // Kill switch (TUN only)
              if (prefs.tunnelMode == 'tun')
                _SettingTile(
                  label: 'Kill Switch',
                  description:
                      'Block all traffic when the tunnel is not connected',
                  tooltip:
                      'When enabled, all network traffic is blocked the moment the VPN disconnects, preventing data leaks. Recommended for privacy-sensitive use.',
                  difficulty: 1,
                  child: Switch(
                    value: prefs.killSwitch,
                    onChanged: (v) => _update(prefs, killSwitch: v),
                  ),
                ),
              // Allow LAN (TUN only)
              if (prefs.tunnelMode == 'tun')
                _SettingTile(
                  label: 'Allow LAN',
                  description: 'Bypass local network traffic from the tunnel',
                  tooltip:
                      'Excludes traffic to 192.168.x.x, 10.x.x.x, and 172.16-31.x.x from the VPN tunnel. Needed for printers, NAS, local file sharing.',
                  difficulty: 2,
                  child: Switch(
                    value: prefs.allowLAN,
                    onChanged: (v) => _update(prefs, allowLAN: v),
                  ),
                ),
              // Block IPv6 (TUN only)
              if (prefs.tunnelMode == 'tun')
                _SettingTile(
                  label: 'Block IPv6',
                  description: 'Disable IPv6 traffic through the tunnel',
                  tooltip:
                      'Some VPN providers lack IPv6 support. Blocking IPv6 prevents leaks when the tunnel is active, but disables IPv6-only services.',
                  difficulty: 2,
                  child: Switch(
                    value: prefs.blockIPv6,
                    onChanged: (v) => _update(prefs, blockIPv6: v),
                  ),
                ),
              // TUN Stack (TUN only) — gvisor / mixed / system
              if (prefs.tunnelMode == 'tun')
                _SettingTile(
                  label: 'TUN Stack',
                  description: 'Network stack for the virtual adapter',
                  tooltip:
                      'system — uses the OS network stack (best compatibility, may need admin).\ngvisor — userspace stack from Google, no admin needed, good isolation.\nmixed — gvisor for TCP + system for UDP (recommended for most users).',
                  difficulty: 3,
                  child: DropdownButton<String>(
                    value: prefs.tunStack,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(
                      fontFamily: AtlasTheme.monoFamily,
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                    underline: const SizedBox(),
                    isDense: true,
                    items: const [
                      DropdownMenuItem(value: 'system', child: Text('System')),
                      DropdownMenuItem(value: 'gvisor', child: Text('gVisor')),
                      DropdownMenuItem(value: 'mixed', child: Text('Mixed')),
                    ],
                    onChanged: (v) {
                      if (v != null) _update(prefs, tunStack: v);
                    },
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Proxy ──
          _SettingsGroup(
            title: 'Proxy',
            children: [
              _SettingTile(
                label: 'SOCKS5 Address',
                description: 'Local SOCKS5 proxy endpoint',
                tooltip:
                    'The address apps use to connect through the SOCKS5 proxy. Usually 127.0.0.1:1080 for local, or 0.0.0.0:1080 to allow LAN.',
                difficulty: 2,
                child: SizedBox(
                  width: 200,
                  child: TextFormField(
                    initialValue: prefs.socksAddr,
                    onChanged: (v) => _update(prefs, socksAddr: v),
                  ),
                ),
              ),
              _SettingTile(
                label: 'HTTP Proxy Address',
                description: 'Local HTTP proxy endpoint',
                tooltip:
                    'The address apps use to connect through the HTTP proxy. Usually 127.0.0.1:2080 for local, or 0.0.0.0:2080 to allow LAN.',
                difficulty: 2,
                child: SizedBox(
                  width: 200,
                  child: TextFormField(
                    initialValue: prefs.httpAddr,
                    onChanged: (v) => _update(prefs, httpAddr: v),
                  ),
                ),
              ),
              _SettingTile(
                label: 'Share Proxies in LAN',
                description: 'Allow other local network devices to connect',
                tooltip:
                    'Lets other devices on your local network use this machine as a proxy gateway. Disable on untrusted networks.',
                difficulty: 2,
                child: Switch(
                  value: prefs.shareLAN,
                  onChanged: (v) => _update(prefs, shareLAN: v),
                ),
              ),
              if (prefs.shareLAN)
                _SettingTile(
                  label: 'LAN Listen Address',
                  description: 'IP and port to listen for LAN traffic',
                  child: SizedBox(
                    width: 200,
                    child: TextFormField(
                      initialValue: prefs.shareAddr,
                      onChanged: (v) => _update(prefs, shareAddr: v),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // ── DNS ──
          _SettingsGroup(
            title: 'DNS',
            children: [
              _SettingTile(
                label: 'DNS Mode',
                description: 'fake-ip (recommended), real-ip, or disabled',
                tooltip:
                    'Fake-IP returns synthetic IPs for DNS queries, routing them through the tunnel. Faster and more private. Real-IP resolves directly, needed for apps that check DNS separately.',
                difficulty: 3,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'fake-ip', label: Text('Fake-IP')),
                    ButtonSegment(value: 'real-ip', label: Text('Real-IP')),
                  ],
                  selected: {prefs.dnsMode},
                  onSelectionChanged: (s) => _update(prefs, dnsMode: s.first),
                ),
              ),
              _SettingTile(
                label: 'Proxied DNS',
                description: 'Upstream DNS for proxy traffic',
                tooltip:
                    'DNS server used to resolve domains that go through the VPN tunnel. Use DoH (https://...) for encrypted DNS. Examples: https://dns.google/dns-query, tls://8.8.8.8',
                difficulty: 3,
                child: SizedBox(
                  width: 240,
                  child: TextFormField(
                    initialValue: prefs.dnsProxied,
                    onChanged: (v) => _update(prefs, dnsProxied: v),
                  ),
                ),
              ),
              _SettingTile(
                label: 'Direct DNS',
                description: 'Upstream DNS for direct traffic',
                tooltip:
                    'DNS server for domains that bypass the tunnel (e.g. local domains). Usually your router or a public resolver like 1.1.1.1.',
                difficulty: 3,
                child: SizedBox(
                  width: 240,
                  child: TextFormField(
                    initialValue: prefs.dnsDirect,
                    onChanged: (v) => _update(prefs, dnsDirect: v),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── WARP (Cloudflare) ──
          _SettingsGroup(
            title: 'Cloudflare WARP',
            children: [
              _SettingTile(
                label: 'Enable WARP',
                description: 'Prepend Cloudflare WARP outbound to the chain',
                tooltip:
                    'When enabled, all traffic first goes through Cloudflare WARP before reaching your VPN server. This can help bypass ISP throttling and improve routing. WARP+ requires a license key.',
                difficulty: 2,
                child: Switch(
                  value: _warpEnabled,
                  onChanged: (v) async {
                    final api = ref.read(daemonApiProvider);
                    try {
                      await api.setWARP({
                        'enabled': v,
                        'mode': _warpMode,
                        'license_key': _warpLicenseKey,
                      });
                      setState(() => _warpEnabled = v);
                    } catch (e) {
                      _showSnack('WARP update failed: $e');
                    }
                  },
                ),
              ),
              _SettingTile(
                label: 'WARP Mode',
                description: 'Standard WARP or WARP+ (requires key)',
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'warp', label: Text('WARP')),
                    ButtonSegment(value: 'warp+', label: Text('WARP+')),
                  ],
                  selected: {_warpMode},
                  onSelectionChanged: (s) async {
                    final api = ref.read(daemonApiProvider);
                    try {
                      await api.setWARP({
                        'enabled': _warpEnabled,
                        'mode': s.first,
                        'license_key': _warpLicenseKey,
                      });
                      setState(() => _warpMode = s.first);
                    } catch (e) {
                      _showSnack('WARP update failed: $e');
                    }
                  },
                ),
              ),
              _SettingTile(
                label: 'WARP+ License Key',
                description: 'Optional — only needed for WARP+ mode',
                child: SizedBox(
                  width: 250,
                  child: TextFormField(
                    initialValue: _warpLicenseKey,
                    decoration: const InputDecoration(
                      hintText: 'e.g. abc123...',
                      isDense: true,
                    ),
                    onChanged: (v) => _warpLicenseKey = v,
                    onFieldSubmitted: (v) async {
                      final api = ref.read(daemonApiProvider);
                      try {
                        await api.setWARP({
                          'enabled': _warpEnabled,
                          'mode': _warpMode,
                          'license_key': v,
                        });
                      } catch (e) {
                        _showSnack('WARP update failed: $e');
                      }
                    },
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Startup ──
          _SettingsGroup(
            title: 'Startup',
            children: [
              _SettingTile(
                label: 'Auto-start',
                description: 'How the daemon starts with the system',
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'service', label: Text('Service')),
                    ButtonSegment(value: 'user', label: Text('User')),
                    ButtonSegment(value: 'manual', label: Text('Manual')),
                  ],
                  selected: {prefs.autoStart},
                  onSelectionChanged: (s) => _update(prefs, autoStart: s.first),
                ),
              ),
              _SettingTile(
                label: 'Auto-connect',
                description: 'Connect automatically when daemon starts',
                child: Switch(
                  value: prefs.autoConnect,
                  onChanged: (v) => _update(prefs, autoConnect: v),
                ),
              ),
              _SettingTile(
                label: 'Show on Launch',
                description: 'Open the UI automatically on launch',
                child: Switch(
                  value: prefs.showOnLaunch,
                  onChanged: (v) => _update(prefs, showOnLaunch: v),
                ),
              ),
              _SettingTile(
                label: 'Advanced Mode (Продвинутый режим)',
                description:
                    'Show advanced tabs (Profiles, Routes, Egresses, Activity, Stats, Cores, Logs)',
                tooltip:
                    'When disabled (default), MosaicBox hides complex developer tools and keeps a clean 4-tab layout (Dashboard, Stations, Subscriptions, Settings).',
                child: Switch(
                  value: prefs.advancedMode,
                  onChanged: (v) => _update(prefs, advancedMode: v),
                ),
              ),
              _SettingTile(
                label: 'Show Raw Nodes (Expert Mode)',
                description:
                    'Show individual raw servers instead of Smart Virtual Groups',
                tooltip:
                    'When disabled (default), MosaicBox displays clean Smart Presets (Fastest Latency, Whitelist Evader 🛡, Countries). Enable to see raw VLESS/Hysteria2 nodes.',
                child: Switch(
                  value: prefs.showRawNodes,
                  onChanged: (v) => _update(prefs, showRawNodes: v),
                ),
              ),
              _SettingTile(
                label: 'Run as Administrator',
                description: 'Always prompt UAC elevation on startup',
                tooltip:
                    'Required for TUN mode. When enabled, Windows will show a UAC prompt each time MosaicBox starts. Disable if you only use Proxy mode.',
                difficulty: 1,
                child: Switch(
                  value: prefs.alwaysRunAsAdmin,
                  onChanged: (v) => _update(prefs, alwaysRunAsAdmin: v),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Appearance (q8) ──
          _SettingsGroup(
            title: s.t('appearance'),
            children: [
              _SettingTile(
                label: s.t('theme'),
                description: s.t('theme_description'),
                child: Consumer(builder: (context, ref, _) {
                  final themeMode = ref.watch(themeModeProvider);
                  return SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                          value: 'dark',
                          icon: const Icon(Icons.dark_mode, size: 16),
                          label: Text(s.t('dark_theme'))),
                      ButtonSegment(
                          value: 'light',
                          icon: const Icon(Icons.light_mode, size: 16),
                          label: Text(s.t('light_theme'))),
                      ButtonSegment(
                          value: 'system',
                          icon: const Icon(Icons.settings_brightness, size: 16),
                          label: Text(s.t('system_theme'))),
                    ],
                    selected: {themeMode},
                    onSelectionChanged: (s) =>
                        ref.read(themeModeProvider.notifier).set(s.first),
                  );
                }),
              ),
              _SettingTile(
                label: s.t('language'),
                description: s.t('language_description'),
                child: Consumer(builder: (context, ref, _) {
                  final language = ref.watch(languageProvider);
                  return SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                          value: 'system', label: Text(s.t('system_default'))),
                      ButtonSegment(value: 'en', label: Text(s.t('english'))),
                      ButtonSegment(value: 'ru', label: Text(s.t('russian'))),
                    ],
                    selected: {language},
                    onSelectionChanged: (value) =>
                        ref.read(languageProvider.notifier).set(value.first),
                  );
                }),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Tray (q9) ──
          _SettingsGroup(
            title: 'System Tray',
            children: [
              _SettingTile(
                label: 'Minimize to Tray',
                description: 'Hide to system tray instead of closing',
                child: Switch(
                  value: prefs.minimizeToTray,
                  onChanged: (v) => _update(prefs, minimizeToTray: v),
                ),
              ),
              _SettingTile(
                label: 'Auto-connect Egresses',
                description: 'Start egresses marked AUTO on launch',
                child: Switch(
                  value: prefs.autoConnectEgresses,
                  onChanged: (v) => _update(prefs, autoConnectEgresses: v),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Testing ──
          _SettingsGroup(
            title: 'Testing & Diagnostics',
            children: [
              _SettingTile(
                label: 'Latency Test URL',
                description: 'HTTP URL used to test connection ping/latency',
                child: SizedBox(
                  width: 250,
                  child: TextFormField(
                    initialValue: prefs.testUrl,
                    onChanged: (v) => _update(prefs, testUrl: v),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ─── MCP ──
          _SettingsGroup(
            title: 'MCP (Model Context Protocol)',
            children: [
              _SettingTile(
                label: 'Enable MCP',
                description: 'Remote control API for automation',
                tooltip:
                    'MCP lets AI assistants (Claude, GPT, etc.) and scripts control MosaicBox remotely — connect, switch servers, view status, manage egresses. Disable if you don\'t use AI automation.',
                difficulty: 2,
                child: Switch(
                  value: prefs.mcpEnabled,
                  onChanged: (v) => _update(prefs, mcpEnabled: v),
                ),
              ),
              _SettingTile(
                label: 'MCP Address',
                description: 'Listen address for MCP server',
                tooltip:
                    'Address the MCP server listens on. 127.0.0.1:9090 = local only. 0.0.0.0:9090 = accept from LAN. Use 127.0.0.1 unless you need remote access.',
                difficulty: 3,
                child: SizedBox(
                  width: 200,
                  child: TextFormField(
                    initialValue: prefs.mcpAddr,
                    onChanged: (v) => _update(prefs, mcpAddr: v),
                  ),
                ),
              ),
              _SettingTile(
                label: 'MCP Permission',
                description: 'read (view) · connect (view+connect) · full',
                tooltip:
                    'Read = AI can only view status. Connect = AI can connect/disconnect servers. Full = AI can change settings, manage egresses, edit subscriptions.',
                difficulty: 3,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'read', label: Text('Read')),
                    ButtonSegment(value: 'connect', label: Text('Connect')),
                    ButtonSegment(value: 'full', label: Text('Full')),
                  ],
                  selected: {prefs.mcpPermission},
                  onSelectionChanged: (s) =>
                      _update(prefs, mcpPermission: s.first),
                ),
              ),
              _SettingTile(
                label: 'Confirm Actions',
                description: 'Require UI confirmation for MCP actions',
                tooltip:
                    'When enabled, MosaicBox shows a dialog before executing any MCP command (connect, egress change, etc.). Click Allow or Deny. Recommended for Full permission mode.',
                difficulty: 1,
                child: Switch(
                  value: prefs.mcpConfirm,
                  onChanged: (v) => _update(prefs, mcpConfirm: v),
                ),
              ),
              // ── MCP Guide ──
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: ExpansionTile(
                  // Keep the header ListTile on a Material layer while the
                  // section background animates, preserving visible ink feedback.
                  shape: const RoundedRectangleBorder(),
                  collapsedShape: const RoundedRectangleBorder(),
                  tilePadding: EdgeInsets.zero,
                  title: Row(
                    children: [
                      Icon(Icons.menu_book, size: 16, color: AtlasTheme.accent),
                      const SizedBox(width: 8),
                      const Text('MCP Guide',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 0, vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('What is MCP?',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary)),
                          const SizedBox(height: 4),
                          Text(
                            'Model Context Protocol (MCP) is an open standard for AI assistants to interact with external tools. MosaicBox exposes an MCP server that lets AI agents (Claude Desktop, Cursor, etc.) and automation scripts control your VPN connection programmatically.',
                            style: TextStyle(
                                fontSize: 11,
                                color: c.textSecondary,
                                height: 1.5),
                          ),
                          const SizedBox(height: 12),
                          Text('Quick Setup',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary)),
                          const SizedBox(height: 4),
                          Text(
                            '1. Enable MCP above\n'
                            '2. Set MCP Address (default: 127.0.0.1:9090)\n'
                            '3. Choose a permission level:\n'
                            '   • Read — AI can check status only\n'
                            '   • Connect — AI can connect/switch servers\n'
                            '   • Full — AI can change all settings\n'
                            '4. Keep "Confirm Actions" ON for safety',
                            style: TextStyle(
                                fontSize: 11,
                                color: c.textSecondary,
                                height: 1.6),
                          ),
                          const SizedBox(height: 12),
                          Text('Connecting from Claude Desktop',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary)),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: c.bgElevated,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: c.border, width: 1),
                            ),
                            child: SelectableText(
                              '{\n'
                              '  "mcpServers": {\n'
                              '    "mosaicbox": {\n'
                              '      "url": "http://127.0.0.1:9090"\n'
                              '    }\n'
                              '  }\n'
                              '}',
                              style: const TextStyle(
                                  fontFamily: 'JetBrains Mono, monospace',
                                  fontSize: 11,
                                  color: AtlasTheme.accent),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text('Connecting from a script',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary)),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: c.bgElevated,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: c.border, width: 1),
                            ),
                            child: SelectableText(
                              'curl http://127.0.0.1:9090/status\n\n'
                              '# Connect to a server:\n'
                              'curl -X POST http://127.0.0.1:9090/connect \\\n'
                              '  -H "Content-Type: application/json" \\\n'
                              '  -d \'{"server_id": "uuid-here"}\'',
                              style: const TextStyle(
                                  fontFamily: 'JetBrains Mono, monospace',
                                  fontSize: 11,
                                  color: AtlasTheme.success),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AtlasTheme.warning.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color:
                                      AtlasTheme.warning.withValues(alpha: 0.3),
                                  width: 1),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.warning_amber,
                                    size: 16, color: AtlasTheme.warning),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Security: binding to 0.0.0.0 exposes MCP to your LAN. Only do this on trusted networks. Use a firewall to restrict access.',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: c.textSecondary,
                                        height: 1.5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Phase 2: Routing & DPI Bypass ──
          _SettingsGroup(
            title: 'Routing & DPI Bypass',
            children: [
              _SettingTile(
                label: 'Routing Mode',
                description: 'Active: ${prefs.routingMode.toUpperCase()}',
                tooltip:
                    'Managed via Routes tab. Global: all traffic via VPN. Rule: route by GeoIP/GeoSite rules. Direct: bypass VPN.',
                difficulty: 2,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: c.bgElevated,
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                    border: Border.all(color: c.border),
                  ),
                  child: Text(
                    'Mode: ${prefs.routingMode.toUpperCase()}',
                    style: TextStyle(
                      fontFamily: AtlasTheme.monoFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AtlasTheme.accent,
                    ),
                  ),
                ),
              ),
              _SettingTile(
                label: 'TLS Fingerprint',
                description: 'uTLS fingerprint used for TLS handshakes',
                tooltip:
                    'Camouflages the TLS ClientHello to mimic a real browser. "chrome" is the safest default.',
                difficulty: 3,
                child: DropdownButton<String>(
                  value: prefs.tlsFingerprint,
                  dropdownColor: Theme.of(context).cardColor,
                  items: const [
                    DropdownMenuItem(value: 'chrome', child: Text('Chrome')),
                    DropdownMenuItem(value: 'firefox', child: Text('Firefox')),
                    DropdownMenuItem(value: 'safari', child: Text('Safari')),
                    DropdownMenuItem(value: 'edge', child: Text('Edge')),
                    DropdownMenuItem(value: 'random', child: Text('Random')),
                    DropdownMenuItem(value: 'none', child: Text('None')),
                  ],
                  onChanged: (v) =>
                      v == null ? null : _update(prefs, tlsFingerprint: v),
                ),
              ),
              _SettingTile(
                label: 'TCP Fast Open',
                description: 'Send data in the SYN packet (reduces RTT)',
                tooltip:
                    'Requires server + kernel support. Off when unreliable.',
                difficulty: 3,
                child: Switch(
                  value: prefs.tcpFastOpen == 1,
                  onChanged: (v) => _update(prefs, tcpFastOpen: v ? 1 : 0),
                ),
              ),
              _SettingTile(
                label: 'TCP Keep-Alive',
                description: 'Send keep-alive probes on idle connections',
                child: Switch(
                  value: prefs.tcpKeepAlive,
                  onChanged: (v) => _update(prefs, tcpKeepAlive: v),
                ),
              ),
              _SettingTile(
                label: 'Fragmentation (DPI Defense)',
                description:
                    'Split TLS ClientHello to evade SNI-based blocking',
                tooltip:
                    'Size-based: splits at a random byte in [min,max]. TLS-SNI: splits at the SNI field. Disable if your DPI only checks HTTP.',
                difficulty: 4,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Off')),
                    ButtonSegment(value: 1, label: Text('Size')),
                    ButtonSegment(value: 2, label: Text('TLS-SNI')),
                  ],
                  selected: {prefs.fragmentStrategy},
                  onSelectionChanged: (s) =>
                      _update(prefs, fragmentStrategy: s.first),
                ),
              ),
              if (prefs.fragmentStrategy == 1)
                _SettingTile(
                  label: 'Fragment Size Range',
                  description: 'Random split offset between min and max bytes',
                  child: SizedBox(
                    width: 240,
                    child: TextFormField(
                      initialValue:
                          '${prefs.fragmentSizeMin}-${prefs.fragmentSizeMax}',
                      decoration:
                          const InputDecoration(hintText: 'min-max e.g. 1-100'),
                      onChanged: (v) {
                        final parts = v.split('-');
                        if (parts.length == 2) {
                          final mn = int.tryParse(parts[0].trim());
                          final mx = int.tryParse(parts[1].trim());
                          if (mn != null && mx != null) {
                            _update(prefs,
                                fragmentSizeMin: mn, fragmentSizeMax: mx);
                          }
                        }
                      },
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Phase 2: MUX ──
          _SettingsGroup(
            title: 'Multiplexing (MUX)',
            children: [
              _SettingTile(
                label: 'Enable MUX',
                description:
                    'Multiplex multiple connections over a single TCP channel',
                tooltip:
                    'Can reduce latency on fast connections but break some protocols. Off = each conn = new TCP.',
                difficulty: 3,
                child: Switch(
                  value: prefs.muxEnabled,
                  onChanged: (v) => _update(prefs, muxEnabled: v),
                ),
              ),
              if (prefs.muxEnabled)
                _SettingTile(
                  label: 'Concurrency',
                  description: 'Number of multiplexed streams (0 = auto)',
                  child: SizedBox(
                    width: 200,
                    child: TextFormField(
                      initialValue: prefs.muxConcurrency.toString(),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '0 = auto'),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null) _update(prefs, muxConcurrency: n);
                      },
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Phase 2: Split Tunneling ──
          _SettingsGroup(
            title: 'Split Tunneling',
            children: [
              _SettingTile(
                label: 'Mode',
                description:
                    'Exclude or include specific apps/domains from VPN',
                tooltip:
                    'Exclude: listed items bypass VPN. Include: only listed items go through VPN.',
                difficulty: 2,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'off', label: Text('Off')),
                    ButtonSegment(value: 'exclude', label: Text('Exclude')),
                    ButtonSegment(value: 'include', label: Text('Include')),
                  ],
                  selected: {prefs.splitTunnelMode},
                  onSelectionChanged: (s) =>
                      _update(prefs, splitTunnelMode: s.first),
                ),
              ),
              if (prefs.splitTunnelMode != 'off')
                _SettingTile(
                  label: 'Excluded Apps',
                  description:
                      'Process names (comma-separated), e.g. chrome.exe,firefox.exe',
                  child: SizedBox(
                    width: 300,
                    child: TextFormField(
                      initialValue: prefs.splitTunnelApps.join(', '),
                      onChanged: (v) => _update(
                        prefs,
                        splitTunnelApps: v
                            .split(',')
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toList(),
                      ),
                    ),
                  ),
                ),
              if (prefs.splitTunnelMode != 'off')
                _SettingTile(
                  label: 'Excluded Domains',
                  description:
                      'Domain names (comma-separated), e.g. example.com,*.local',
                  child: SizedBox(
                    width: 300,
                    child: TextFormField(
                      initialValue: prefs.splitTunnelDomains.join(', '),
                      onChanged: (v) => _update(
                        prefs,
                        splitTunnelDomains: v
                            .split(',')
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toList(),
                      ),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Phase 2: Network & Speed Test ──
          _SettingsGroup(
            title: 'Network & Speed Test',
            children: [
              _SettingTile(
                label: 'Ping Method',
                description: 'How server latency is measured',
                tooltip:
                    'URL: HTTP HEAD timing (most compatible). TCP: raw socket connect (faster, no HTTP). ICMP: ping packet (most accurate, needs admin).',
                difficulty: 2,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'url', label: Text('HTTP')),
                    ButtonSegment(value: 'tcp', label: Text('TCP')),
                    ButtonSegment(value: 'icmp', label: Text('ICMP')),
                  ],
                  selected: {prefs.pingMethod},
                  onSelectionChanged: (s) =>
                      _update(prefs, pingMethod: s.first),
                ),
              ),
              _SettingTile(
                label: 'Core Engine',
                description: 'Active VPN backend: ${prefs.coreEngine}',
                tooltip:
                    'Managed via Cores & Engines tab. sing-box: modern, all-protocol support. xray-core: legacy, proven.',
                difficulty: 2,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: c.bgElevated,
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                    border: Border.all(color: c.border),
                  ),
                  child: Text(
                    'Active: ${prefs.coreEngine}',
                    style: TextStyle(
                      fontFamily: AtlasTheme.monoFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AtlasTheme.accent,
                    ),
                  ),
                ),
              ),
              _SettingTile(
                label: 'DNS-over-HTTPS/TLS',
                description: 'Custom DNS provider URL (empty = system default)',
                tooltip:
                    'e.g. https://cloudflare-dns.com/dns-query (DoH) or tls://dns.google (DoT)',
                difficulty: 2,
                child: SizedBox(
                  width: 280,
                  child: TextFormField(
                    initialValue: prefs.dnsProvider,
                    decoration: const InputDecoration(
                        hintText: 'https://... or tls://...'),
                    onChanged: (v) => _update(prefs, dnsProvider: v),
                  ),
                ),
              ),
              _SettingTile(
                label: 'Connect Timeout',
                description: 'Seconds to wait before dial fails',
                child: SizedBox(
                  width: 120,
                  child: TextFormField(
                    initialValue: prefs.connectTimeout.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n > 0) _update(prefs, connectTimeout: n);
                    },
                  ),
                ),
              ),
              _SettingTile(
                label: 'Max Retries',
                description: 'Dial retries before giving up',
                child: SizedBox(
                  width: 120,
                  child: TextFormField(
                    initialValue: prefs.maxRetries.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n >= 0) _update(prefs, maxRetries: n);
                    },
                  ),
                ),
              ),
              _SettingTile(
                label: 'Concurrent Dials',
                description: 'Parallel dial attempts for multi-IP servers',
                tooltip:
                    '1 = sequential (safe). 4 = race all IPs, use the winner (Happy Eyeballs).',
                difficulty: 3,
                child: SizedBox(
                  width: 120,
                  child: TextFormField(
                    initialValue: prefs.concurrentDials.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n >= 1) {
                        _update(prefs, concurrentDials: n);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Phase 2: Interface & Geo ──
          _SettingsGroup(
            title: 'Interface & Geo',
            children: [
              _SettingTile(
                label: 'Language',
                description: 'UI display language',
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('System')),
                    ButtonSegment(value: 'en', label: Text('EN')),
                    ButtonSegment(value: 'ru', label: Text('RU')),
                  ],
                  selected: {prefs.language},
                  onSelectionChanged: (s) => _update(prefs, language: s.first),
                ),
              ),
              _SettingTile(
                label: 'Compact Mode',
                description: 'Denser UI for small displays',
                child: Switch(
                  value: prefs.compactMode,
                  onChanged: (v) => _update(prefs, compactMode: v),
                ),
              ),
              _SettingTile(
                label: 'Auto-update GeoIP/GeoSite',
                description: 'Download latest routing rule sets weekly',
                child: Switch(
                  value: prefs.autoUpdateGeo,
                  onChanged: (v) => _update(prefs, autoUpdateGeo: v),
                ),
              ),
            ],
          ),

          // ── Phase 2.5: Backup & Restore ──
          _SettingsGroup(
            title: 'Backup & Restore',
            children: [
              _SettingTile(
                label: 'Auto-backup',
                description: 'Periodically save config snapshot',
                child: Switch(
                  value: prefs.backupEnabled,
                  onChanged: (v) => _update(prefs, backupEnabled: v),
                ),
              ),
              _SettingTile(
                label: 'Backup folder',
                description: prefs.backupPath.isEmpty
                    ? 'Choose where snapshots are saved'
                    : prefs.backupPath,
                child: TextButton.icon(
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('Pick'),
                  onPressed: () async {
                    final picked = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Backup folder',
                    );
                    if (picked != null) {
                      _update(prefs, backupPath: picked);
                    }
                  },
                ),
              ),
              _SettingTile(
                label: 'Auto-backup interval',
                description: '0 = off, hours between snapshots',
                child: SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: prefs.autoBackupInterval.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(suffixText: 'h'),
                    onChanged: (v) {
                      final n = int.tryParse(v) ?? 0;
                      _update(prefs, autoBackupInterval: n);
                    },
                  ),
                ),
              ),
              _SettingTile(
                label: 'Include subscription URLs',
                description: 'Off = strip remote feed URLs from export',
                child: Switch(
                  value: prefs.includeSubscriptions,
                  onChanged: (v) => _update(prefs, includeSubscriptions: v),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('Export config'),
                        onPressed: () => _exportConfig(prefs),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.upload_outlined),
                        label: const Text('Import config'),
                        onPressed: _importConfig,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── About ──
          _SettingsGroup(
            title: 'About',
            children: [
              _SettingTile(
                label: 'MosaicBox',
                description: 'v${AppConfig.appVersion}',
                child: IconButton(
                  icon: const Icon(Icons.info_outline, size: 20),
                  onPressed: () => _showAboutDialog(context),
                ),
              ),
              _SettingTile(
                label: 'Daemon Status',
                description: 'Check daemon connection and version',
                child: IconButton(
                  icon: const Icon(Icons.router_outlined, size: 20),
                  onPressed: () => _showDaemonInfo(context),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _update(Preferences prefs,
      {String? tunnelMode,
      String? tunStack,
      String? socksAddr,
      String? httpAddr,
      int? mixedPort,
      int? mtu,
      bool? killSwitch,
      bool? allowLAN,
      bool? blockIPv6,
      String? dnsMode,
      String? dnsProxied,
      String? dnsDirect,
      String? autoStart,
      bool? autoConnect,
      bool? showOnLaunch,
      bool? showRawNodes,
      bool? advancedMode,
      bool? mcpEnabled,
      String? mcpAddr,
      String? mcpPermission,
      bool? mcpConfirm,
      bool? minimizeToTray,
      bool? autoConnectEgresses,
      String? themeMode,
      String? testUrl,
      bool? alwaysRunAsAdmin,
      bool? shareLAN,
      String? shareAddr,
      // ── Phase 2 fields ──
      String? pingMethod,
      String? routingMode,
      String? tlsFingerprint,
      bool? muxEnabled,
      int? muxConcurrency,
      bool? tcpKeepAlive,
      int? tcpFastOpen,
      int? fragmentStrategy,
      int? fragmentSizeMin,
      int? fragmentSizeMax,
      bool? fragmentationDefense,
      List<String>? splitTunnelApps,
      List<String>? splitTunnelDomains,
      String? splitTunnelMode,
      String? dnsProvider,
      String? coreEngine,
      String? language,
      bool? compactMode,
      bool? autoUpdateGeo,
      int? connectTimeout,
      int? readTimeout,
      int? writeTimeout,
      int? maxRetries,
      int? concurrentDials,
      // ── Phase 2.5: Backup / Restore ──
      bool? backupEnabled,
      String? backupPath,
      int? autoBackupInterval,
      bool? includeSubscriptions}) async {
    final updated = prefs.copyWith(
      tunnelMode: tunnelMode,
      tunStack: tunStack,
      socksAddr: socksAddr,
      httpAddr: httpAddr,
      mixedPort: mixedPort,
      mtu: mtu,
      killSwitch: killSwitch,
      allowLAN: allowLAN,
      blockIPv6: blockIPv6,
      dnsMode: dnsMode,
      dnsProxied: dnsProxied,
      dnsDirect: dnsDirect,
      autoStart: autoStart,
      autoConnect: autoConnect,
      showOnLaunch: showOnLaunch,
      showRawNodes: showRawNodes,
      advancedMode: advancedMode,
      mcpEnabled: mcpEnabled,
      mcpAddr: mcpAddr,
      mcpPermission: mcpPermission,
      mcpConfirm: mcpConfirm,
      minimizeToTray: minimizeToTray,
      autoConnectEgresses: autoConnectEgresses,
      themeMode: themeMode,
      testUrl: testUrl,
      alwaysRunAsAdmin: alwaysRunAsAdmin,
      shareLAN: shareLAN,
      shareAddr: shareAddr,
      pingMethod: pingMethod,
      routingMode: routingMode,
      tlsFingerprint: tlsFingerprint,
      muxEnabled: muxEnabled,
      muxConcurrency: muxConcurrency,
      tcpKeepAlive: tcpKeepAlive,
      tcpFastOpen: tcpFastOpen,
      fragmentStrategy: fragmentStrategy,
      fragmentSizeMin: fragmentSizeMin,
      fragmentSizeMax: fragmentSizeMax,
      fragmentationDefense: fragmentationDefense,
      splitTunnelApps: splitTunnelApps,
      splitTunnelDomains: splitTunnelDomains,
      splitTunnelMode: splitTunnelMode,
      dnsProvider: dnsProvider,
      coreEngine: coreEngine,
      language: language,
      compactMode: compactMode,
      autoUpdateGeo: autoUpdateGeo,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      writeTimeout: writeTimeout,
      maxRetries: maxRetries,
      concurrentDials: concurrentDials,
      backupEnabled: backupEnabled,
      backupPath: backupPath,
      autoBackupInterval: autoBackupInterval,
      includeSubscriptions: includeSubscriptions,
    );

    // Optimistically update local state for 0ms visual toggle latency
    if (mounted) {
      setState(() => _localPrefs = updated);
    }

    // Save prefs to daemon and invalidate provider
    try {
      final api = ref.read(daemonApiProvider);
      await api.setPrefs(updated.toJson());
      ref.invalidate(prefsProvider);
    } catch (e) {
      // Keep optimistic UI value, log for diagnostics
      debugPrint('setPrefs failed: $e');
    }

    // ── Wire desktop services ──
    if (minimizeToTray != null) {
      TrayService.instance.configure(minimizeToTray: minimizeToTray);
    }
    if (autoStart != null) {
      // 'service' or 'user' → enable OS autostart; 'manual' → disable
      AutostartService.instance.setEnabled(autoStart != 'manual');
    }
  }

  // ── Phase 2.5: Backup / Restore handlers ───────────────────────────
  Future<void> _exportConfig(Preferences prefs) async {
    final api = ref.read(daemonApiProvider);
    String json;
    try {
      json = await api.exportConfig(
          includeSubscriptions: prefs.includeSubscriptions);
    } catch (e) {
      _showSnack('Export failed: $e');
      return;
    }
    final now = DateTime.now().toLocal();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final defaultName = 'mosaicbox-backup-$stamp.json';

    String? outPath;
    if (prefs.backupPath.isNotEmpty) {
      // Auto-pick path from preferences if user has chosen one.
      final dir = prefs.backupPath;
      outPath = '$dir\\$defaultName';
      try {
        await File(outPath).writeAsString(json);
      } catch (_) {
        outPath = (await FilePicker.platform.saveFile(
          dialogTitle: 'Save backup as',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: const ['json'],
        ));
        if (outPath != null) {
          await File(outPath).writeAsString(json);
        }
      }
    } else {
      outPath = (await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup as',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      ));
      if (outPath != null) {
        await File(outPath).writeAsString(json);
      }
    }

    if (outPath == null) {
      _showSnack('Export cancelled');
      return;
    }
    _showSnack('Saved backup to $outPath');
  }

  Future<void> _importConfig() async {
    final pick = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose MosaicBox backup file',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (pick == null || pick.files.single.path == null) {
      _showSnack('Import cancelled');
      return;
    }
    final path = pick.files.single.path!;
    String content;
    try {
      content = await File(path).readAsString();
    } catch (e) {
      _showSnack('Cannot read file: $e');
      return;
    }

    final mode = await _importModeDialog();
    if (mode == null) return;

    final api = ref.read(daemonApiProvider);
    try {
      await api.importConfig(content, mode: mode);
    } catch (e) {
      _showSnack('Import failed: $e');
      return;
    }

    // Refresh providers so mutated state appears in the UI immediately.
    ref.invalidate(serversProvider);
    ref.invalidate(subscriptionsProvider);
    ref.invalidate(serverGroupsProvider);
    ref.invalidate(prefsProvider);

    _showSnack(mode == 'replace'
        ? 'Imported and replaced existing config'
        : 'Merged backup into existing config');
  }

  /// Asks user to pick between "merge" and "replace" import modes.
  /// Returns null if the user cancelled the dialog.
  Future<String?> _importModeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import mode'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Merge: adds only non-conflicting items (safest).'),
            SizedBox(height: 8),
            Text('Replace: wipes existing servers/groups/subscriptions/rules '
                'before loading the backup.'),
            SizedBox(height: 4),
            Text('Preferences are always overwritten.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop('merge'),
            child: const Text('Merge'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('replace'),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
  }

  void _checkTunElevation(
      BuildContext context, FutureOr<void> Function() onAllow) async {
    final c = ThemeColors.of(context);
    // Check if we're already running with admin privileges
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          '([Security.Principal.WindowsPrincipal]'
              '[Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('
              '[Security.Principal.WindowsBuiltInRole]::Administrator)'
        ],
      );
      if (result.stdout.toString().trim().toLowerCase() == 'true') {
        // Already admin — no UAC needed
        onAllow();
        return;
      }
    } catch (_) {
      // If check fails, fall through to prompt
    }

    if (!context.mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: const Text('Administrator Privileges Required',
            style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
        content: const Text(
          'TUN mode requires administrative privileges to configure virtual network adapters and routing tables.\n\nMosaicBox will restart with elevated credentials.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      // Save prefs first, then restart with elevation
      try {
        await onAllow();
        // Small delay to let the API call reach the daemon
        await Future.delayed(const Duration(milliseconds: 300));
        final exePath = Platform.resolvedExecutable;
        await Process.start(
          'powershell',
          ['-Command', 'Start-Process -FilePath "$exePath" -Verb RunAs'],
          runInShell: true,
        );
        exit(0);
      } catch (_) {
        // Fallback
      }
    }
  }

  void _showAboutDialog(BuildContext context) {
    final c = ThemeColors.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: const Text('About MosaicBox',
            style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version: v${AppConfig.appVersion}',
                style: TextStyle(
                    color: c.textPrimary, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'MosaicBox is a cross-platform VPN client built with Flutter and Go.',
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showDaemonInfo(BuildContext context) {
    final c = ThemeColors.of(context);
    final api = ref.read(daemonApiProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
        title: const Text('Daemon Status',
            style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
        content: FutureBuilder<VpnStatus>(
          future: api.getStatus(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 60,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Connection Status: Offline / Error',
                      style: TextStyle(
                          color: c.error, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Error: ${snapshot.error}',
                      style: TextStyle(color: c.textSecondary, fontSize: 12)),
                ],
              );
            }
            final status = snapshot.data;
            final isConnected = status?.agentConnected ?? false;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Daemon API: ${AppConfig.daemonBaseUrl}',
                    style: TextStyle(color: c.textPrimary, fontSize: 13)),
                const SizedBox(height: 8),
                Text(
                  'Status: ${isConnected ? "Online" : "Offline"}',
                  style: TextStyle(
                    color: isConnected ? c.success : c.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(height: 4),
                  Text('Tunnel Mode: ${status.tunnelMode}',
                      style: TextStyle(color: c.textSecondary, fontSize: 12)),
                  Text('State: ${status.state}',
                      style: TextStyle(color: c.textSecondary, fontSize: 12)),
                ],
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Divider(color: c.border, height: 1),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final String label;
  final String description;
  final Widget child;
  final String? tooltip;
  final int difficulty; // 0=none, 1=beginner, 2=intermediate, 3=advanced

  const _SettingTile({
    required this.label,
    required this.description,
    required this.child,
    this.tooltip,
    this.difficulty = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final difficultyStars =
        difficulty > 0 ? ' ${'★' * difficulty}${'☆' * (3 - difficulty)}' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Tooltip(
              message: tooltip ?? description,
              waitDuration: const Duration(milliseconds: 500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                      if (difficulty > 0)
                        Tooltip(
                          message: difficulty == 1
                              ? 'Beginner — safe to change'
                              : difficulty == 2
                                  ? 'Intermediate — may affect connectivity'
                                  : 'Advanced — requires networking knowledge',
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              difficultyStars,
                              style: TextStyle(
                                fontSize: 9,
                                color: difficulty == 1
                                    ? AtlasTheme.success
                                    : difficulty == 2
                                        ? AtlasTheme.warning
                                        : AtlasTheme.accent,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11,
                      color: c.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          child,
        ],
      ),
    );
  }
}
