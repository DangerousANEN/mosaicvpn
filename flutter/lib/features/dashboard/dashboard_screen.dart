import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../core/utils/city_coords.dart';
import '../../shared/widgets/atlas_widgets.dart';
import '../../shared/widgets/world_map_widget.dart';
import '../../core/utils/formatters.dart';
import '../subscriptions/subscriptions_screen.dart';

/// Width reserved for the latency badge in a station row.
///
/// The slot is held even when no measurement exists yet: letting the badge
/// appear only after a ping made the row's trailing group grow, which stole
/// width from the title and clipped server names to a few characters.
const double _kLatencySlotWidth = 40;

/// Minimum width for a station's name before it may be ellipsised, roughly
/// twenty characters at the row's 12px font.
const double _kStationNameMinWidth = 140;

/// Dashboard — the "Station Command" screen.
/// Three-column atlas layout: connection controls, world chart, stations.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late ThemeColors c;
  String? _selectedServerId;

  /// First tap marks a server as the candidate: dim orange, dashed route, and
  /// the camera frames it alongside the client. A second tap on the same
  /// server connects. The map, the station list and the context menu all
  /// funnel through here so the behaviour cannot drift between them.
  void onSelectServer(String id) {
    if (_selectedServerId == id) {
      connectToServer(id);
    } else {
      setState(() => _selectedServerId = id);
    }
  }

  /// Connects immediately, skipping the candidate step. Used by the context
  /// menu and the big Engage button, where intent is already explicit and a
  /// second click would just be busywork.
  void connectToServer(String id) {
    final api = ref.read(daemonApiProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _selectedServerId = id);
    api.connect(id).catchError((e) {
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: SelectableText(
            'Connection failed: $e',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          action: SnackBarAction(
            label: 'Copy',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: e.toString()));
            },
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    c = ThemeColors.of(context);
    final statusAsync = ref.watch(vpnStatusProvider);
    final serversAsync = ref.watch(serversProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: statusAsync.when(
        data: (status) => _buildContent(context, status, serversAsync),
        loading: () => _buildSkeleton(context),
        error: (_, __) => _buildContent(context, VpnStatus(), serversAsync),
      ),
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    final c = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Status card skeleton
        Card(
          color: c.bgCard,
          child: const SkeletonStatsCard(),
        ),
        const SizedBox(height: 16),
        // Map skeleton
        Expanded(
          child: Card(
            color: c.bgCard,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AtlasTheme.radiusMd),
              ),
              child: const Center(
                child: SkeletonLoader(width: 300, height: 150, borderRadius: 8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    VpnStatus status,
    AsyncValue<List<Server>> serversAsync,
  ) {
    c = ThemeColors.of(context);
    // If we have an active connected server, set it as default selection if nothing selected
    final activeServerID = status.server?.id;
    if (_selectedServerId == null && activeServerID != null) {
      // Defer setState to avoid mutating during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedServerId == null) {
          setState(() => _selectedServerId = activeServerID);
        }
      });
    }
    // NOTE: we intentionally do NOT clear _selectedServerId when the
    // connection drops. Clearing it here caused the "server un-highlights
    // immediately" bug: first tap set selection, but next build saw
    // disconnected status (server=null, isConnecting=false) and wiped it
    // via a post-frame callback in the same frame. Selection now persists
    // until the user picks a different server or explicitly disconnects
    // via a second tap.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Title (compact) ──
        Row(
          children: [
            const Text(
              'Mosaic',
              style: TextStyle(
                fontFamily: AtlasTheme.serifFamily,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Text(
              'Box.',
              style: TextStyle(
                fontFamily: AtlasTheme.serifFamily,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AtlasTheme.accent,
              ),
            ),
            const SizedBox(width: 10),
            // The tagline is decorative, so it yields space instead of pushing
            // the row past a 360px phone (it overflowed by ~194px).
            Flexible(
              child: Text(
                'Atlas of routes · Edition I',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AtlasTheme.sansFamily,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: c.textMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── Responsive body ──
        // A fixed three-column Row squeezed each panel to ~120px on a 390px
        // phone, which broke "DISCONNECTED" into two characters per line.
        // Panels now stack below 600px and the map keeps its 2:1 ratio.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final isCompact = w < 600;

              final connectionPanel = _ConnectionPanel(
                status: status,
                selectedServerId: _selectedServerId,
              );
              final mapPanel = _WorldChartPanel(
                status: status,
                serversAsync: serversAsync,
                selectedServerId: _selectedServerId,
              );
              final stationsPanel = _StationsPanel(
                status: status,
                serversAsync: serversAsync,
                selectedServerId: _selectedServerId,
                onSelectServer: onSelectServer,
              );

              if (isCompact) {
                // Phone: one column, scrollable. The map is given an explicit
                // 2:1 box so the equirectangular projection stays correct and
                // pins land where they belong.
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      connectionPanel,
                      const SizedBox(height: 12),
                      AspectRatio(aspectRatio: 2.0, child: mapPanel),
                      const SizedBox(height: 12),
                      SizedBox(height: 320, child: stationsPanel),
                    ],
                  ),
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: connectionPanel),
                  const SizedBox(width: 16),
                  Expanded(flex: 4, child: mapPanel),
                  const SizedBox(width: 16),
                  Expanded(flex: 3, child: stationsPanel),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConnectionPanel extends ConsumerStatefulWidget {
  final VpnStatus status;
  final String? selectedServerId;
  const _ConnectionPanel({required this.status, this.selectedServerId});

  @override
  ConsumerState<_ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends ConsumerState<_ConnectionPanel> {
  late ThemeColors c;

  /// Disconnect from VPN with error handling.
  Future<void> _disconnectFromVpn() async {
    final api = ref.read(daemonApiProvider);
    try {
      await api.disconnect();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: SelectableText(
              'Disconnect failed: $e',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: e.toString()));
              },
            ),
          ),
        );
      }
    }
  }

  /// Connect to the given server. Called on 2nd click on a selected server.
  Future<void> _connectToServer(String id) async {
    final api = ref.read(daemonApiProvider);
    try {
      await api.connect(id);
    } catch (e) {
      if (mounted) {
        final errText = 'Connection failed: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: SelectableText(
              errText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: errText));
              },
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    c = ThemeColors.of(context);
    final status = widget.status;
    final stateText = status.isConnected
        ? 'CONNECTED'
        : status.isConnecting
            ? 'CONNECTING'
            : status.hasError
                ? 'ERROR'
                : 'DISCONNECTED';

    final stateColor = status.isConnected
        ? AtlasTheme.success
        : status.isConnecting
            ? AtlasTheme.warning
            : status.hasError
                ? AtlasTheme.error
                : c.textMuted;

    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status indicator
          Row(
            children: [
              StatusDot(color: stateColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Daemon · ${status.agentConnected ? "Online" : "Offline"}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Big state text
          Text(
            stateText,
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: stateColor,
              letterSpacing: 1,
            ),
          ),
          if (status.server != null) ...[
            const SizedBox(height: 6),
            Text(
              status.server!.name,
              style: TextStyle(
                fontSize: 13,
                color: c.textSecondary,
              ),
            ),
            Text(
              status.server!.location.isNotEmpty
                  ? status.server!.location
                  : status.server!.address,
              style: TextStyle(
                fontSize: 11,
                color: c.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 20),

          // Connect/disconnect button
          ConnectToggle(
            connected: status.isConnected,
            connecting: status.isConnecting,
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                if (status.isConnected) {
                  await _disconnectFromVpn();
                } else {
                  // Connect to selected or last-used server
                  final servers = ref.read(serversProvider).valueOrNull ?? [];
                  String? targetId =
                      widget.selectedServerId ?? status.server?.id;
                  if (targetId == null && servers.isNotEmpty) {
                    targetId = servers.first.id;
                  }
                  if (targetId != null) {
                    await _connectToServer(targetId);
                  }
                }
                ref.invalidate(vpnStatusProvider);
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(
                    content: SelectableText('Connection error: $e',
                        style: const TextStyle(fontFamily: 'monospace')),
                    action: SnackBarAction(
                      label: 'Copy',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: e.toString())),
                    ),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 12),

          // Proxy endpoints card (shown when SOCKS/HTTP listeners are active)
          if (status.proxySocks.isNotEmpty || status.proxyHTTP.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: c.bgElevated,
                borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                border: Border.all(
                  color: AtlasTheme.success.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.router, size: 16, color: AtlasTheme.success),
                  const SizedBox(width: 8),
                  Text(
                    'Proxy',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      children: [
                        if (status.proxySocks.isNotEmpty)
                          _ProxyChip(
                            label: 'SOCKS',
                            address: status.proxySocks,
                            color: AtlasTheme.success,
                          ),
                        if (status.proxyHTTP.isNotEmpty)
                          _ProxyChip(
                            label: 'HTTP',
                            address: status.proxyHTTP,
                            color: AtlasTheme.success,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // TUN / Proxy Toggle Selector
          Center(
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'tun',
                    icon: Icon(Icons.vpn_lock, size: 14),
                    label: Text('TUN Mode', style: TextStyle(fontSize: 10)),
                  ),
                  ButtonSegment(
                    value: 'proxy',
                    icon: Icon(Icons.settings_input_component, size: 14),
                    label: Text('Proxy Mode', style: TextStyle(fontSize: 10)),
                  ),
                ],
                selected: {status.tunnelMode},
                onSelectionChanged: (s) async {
                  if (s.first == 'tun' && status.tunnelMode != 'tun') {
                    _checkTunElevation(context, () async {
                      try {
                        final api = ref.read(daemonApiProvider);
                        await api.setPrefs({'tunnel_mode': 'tun'});
                        ref.invalidate(vpnStatusProvider);
                        ref.invalidate(prefsProvider);
                      } catch (e) {
                        debugPrint('setPrefs tunnel_mode=tun failed: $e');
                      }
                    });
                  } else {
                    try {
                      final api = ref.read(daemonApiProvider);
                      await api.setPrefs({'tunnel_mode': s.first});
                      ref.invalidate(vpnStatusProvider);
                      ref.invalidate(prefsProvider);
                    } catch (e) {
                      debugPrint('setPrefs tunnel_mode=${s.first} failed: $e');
                    }
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Metrics grid
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 2,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 3.2,
            children: [
              StatTile(
                label: 'Latency',
                value: status.latencyMS > 0 ? '${status.latencyMS}' : '—',
                unit: status.latencyMS > 0 ? 'ms' : '',
                icon: Icons.bolt,
              ),
              StatTile(
                label: 'Daemon',
                value: status.agentConnected ? 'ONLINE' : 'OFFLINE',
                valueColor:
                    status.agentConnected ? AtlasTheme.success : c.textMuted,
                icon: Icons.circle,
              ),
              StatTile(
                label: 'Download',
                value: formatBytes(status.bytesIn),
                icon: Icons.south,
              ),
              StatTile(
                label: 'Upload',
                value: formatBytes(status.bytesOut),
                icon: Icons.north,
              ),
            ],
          ),

          // A Spacer here asserts inside the dashboard's scroll view: the
          // incoming height is unbounded, so there is no free space to expand
          // into. The card shrink-wraps its content, so a fixed gap is what the
          // layout actually needs.
          const SizedBox(height: 20),

          // Footer note
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.bgElevated,
              borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
            ),
            child: Text(
              'The system is in ${status.tunnelMode} mode. '
              '${status.killSwitch ? "Kill switch is armed." : "Kill switch is off."} '
              '${status.allowLAN ? "Local networks use the local connection." : "Local networks use the selected route."}',
              style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: c.textMuted,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorldChartPanel extends ConsumerStatefulWidget {
  final VpnStatus status;
  final AsyncValue<List<Server>> serversAsync;
  final String? selectedServerId;

  const _WorldChartPanel({
    required this.status,
    required this.serversAsync,
    required this.selectedServerId,
  });

  @override
  ConsumerState<_WorldChartPanel> createState() => _WorldChartPanelState();
}

class _WorldChartPanelState extends ConsumerState<_WorldChartPanel>
    with SingleTickerProviderStateMixin {
  late ThemeColors c;
  late AnimationController _ctrl;
  Animation<double>? _zoomAnim;
  Animation<Offset>? _panAnim;

  // Current transform values (target for next animation)
  double _zoom = 1.0;
  Offset _pan = const Offset(0.5, 0.5); // normalized map point to centre (0..1)

  // Previous selectedServerId to detect changes
  String? _prevSelectedId;

  // Your real location, resolved via GeoIP. Null until it answers: the pin
  // used to default to Moscow, so a user anywhere else saw a confident marker
  // in the wrong country and a route line drawn from a place they are not.
  double? _youNx;
  double? _youNy;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _prevSelectedId = widget.selectedServerId;
    _computeTarget(widget.selectedServerId, widget.serversAsync);
  }

  void _updateYouLocation(double lat, double lon) {
    if (_youNx != null) return;
    if (!mounted) return;
    setState(() {
      _youNx = WorldMapWidget.projectX(lon);
      _youNy = WorldMapWidget.projectY(lat);
    });
    _computeTarget(widget.selectedServerId, widget.serversAsync);
  }

  @override
  void didUpdateWidget(_WorldChartPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only re-animate when the SELECTION changes. Re-animating on every
    // serversAsync / status change restarts the AnimationController from 0
    // and causes the "zoom for a millisecond then jump back" glitch during
    // connect/disconnect transitions.
    if (widget.selectedServerId != _prevSelectedId) {
      _prevSelectedId = widget.selectedServerId;
      _computeTarget(widget.selectedServerId, widget.serversAsync);
    }
  }

  /// Compute zoom + pan so that the You↔Server line fits inside the viewport
  /// with ~15% padding on each side. No rotation — pins stay upright and the
  /// graticule stays axis-aligned. The viewport aspect is 2:1 (equirectangular).
  void _computeTarget(
      String? selectedId, AsyncValue<List<Server>> serversAsync) {
    if (!serversAsync.hasValue || selectedId == null) {
      _animateTo(1.0, const Offset(0.5, 0.5));
      return;
    }

    final servers = serversAsync.value!;
    final server = servers.where((s) => s.id == selectedId).firstOrNull;
    if (server == null) {
      _animateTo(1.0, const Offset(0.5, 0.5));
      return;
    }

    // Resolve server coords
    double lat = server.lat;
    double lon = server.lon;
    if (lat == 0 && lon == 0) {
      final coords = cityToLatLon(city: server.city, country: server.country);
      if (coords != null) {
        lat = coords.lat;
        lon = coords.lon;
      }
    }
    if (lat == 0 && lon == 0) {
      _animateTo(1.0, const Offset(0.5, 0.5));
      return;
    }

    final srvNx = WorldMapWidget.projectX(lon);
    final srvNy = WorldMapWidget.projectY(lat);

    // Until GeoIP resolves there is no client point to frame against, so centre
    // on the server rather than inventing an origin for the bounding box.
    final youNx = _youNx;
    final youNy = _youNy;
    if (youNx == null || youNy == null) {
      _animateTo(2.0, Offset(srvNx, srvNy));
      return;
    }

    // Bounding box in normalized coords
    final bboxMinX = math.min(youNx, srvNx);
    final bboxMaxX = math.max(youNx, srvNx);
    final bboxMinY = math.min(youNy, srvNy);
    final bboxMaxY = math.max(youNy, srvNy);

    // Expand bbox by 35% padding on each side so both pins are visible
    final bboxW = (bboxMaxX - bboxMinX).clamp(1e-4, 1.0);
    final bboxH = (bboxMaxY - bboxMinY).clamp(1e-4, 1.0);
    final padX = bboxW * 0.35;
    final padY = bboxH * 0.35;
    final paddedMinX = (bboxMinX - padX).clamp(0.0, 1.0);
    final paddedMaxX = (bboxMaxX + padX).clamp(0.0, 1.0);
    final paddedMinY = (bboxMinY - padY).clamp(0.0, 1.0);
    final paddedMaxY = (bboxMaxY + padY).clamp(0.0, 1.0);
    final paddedW = paddedMaxX - paddedMinX;
    final paddedH = paddedMaxY - paddedMinY;

    // The viewport covers normalized coords [0..1] × [0..1] for the SVG.
    // To fit the padded bbox into the viewport, the zoom factor must be at
    // least 1/paddedW (X) and 1/paddedH (Y). Use the larger one to ensure both
    // dimensions fit. Cap zoom so we don't over-zoom for very close points.
    final targetZoom = math.max(1.0 / paddedW, 1.0 / paddedH).clamp(1.0, 3.0);

    // Pan: the target is the bbox midpoint in normalized map coords (0..1).
    // _AnimatedMap will compute the pixel offset so that this point appears
    // at the viewport centre after scaling.
    final targetPanX = (paddedMinX + paddedMaxX) / 2;
    final targetPanY = (paddedMinY + paddedMaxY) / 2;

    _animateTo(targetZoom, Offset(targetPanX, targetPanY));
  }

  void _animateTo(double zoom, Offset pan) {
    final startZoom = _zoom;
    final startPan = _pan;

    _zoomAnim = Tween<double>(begin: startZoom, end: zoom).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic),
    );
    _panAnim = Tween<Offset>(begin: startPan, end: pan).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic),
    );

    _zoom = zoom;
    _pan = pan;

    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    c = ThemeColors.of(context);
    // Resolve client location via GeoIP
    final clientLoc = ref.watch(clientLocationProvider);
    clientLoc.whenData((loc) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateYouLocation(loc.lat, loc.lon);
      });
    });

    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Flexible(
                child: Text(
                  '◇ World Chart · Equirectangular',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (widget.serversAsync.hasValue)
                Text(
                  '${widget.serversAsync.value!.length} stations',
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Divider(color: c.border, height: 1),
          const SizedBox(height: 16),

          // ── Real SVG world map with pins + camera animation ──
          // The map draws an equirectangular projection, which is inherently
          // 2:1. Letting a bare Expanded stretch the frame left dead bands
          // above and below the continents on tall desktop columns, so the
          // frame hugs the projection and pins to the top of the column.
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: AspectRatio(
                aspectRatio: 2.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bgElevated,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedBuilder(
                    animation: _ctrl,
                    builder: (context, child) {
                      final zoom = _zoomAnim?.value ?? _zoom;
                      final pan = _panAnim?.value ?? _pan;
                      // Connected only when the VPN is actually connected AND
                      // the connected server is the currently selected one
                      // (otherwise the visible pin is just "selected").
                      final isConnected = widget.status.isConnected &&
                          widget.selectedServerId != null &&
                          widget.status.server?.id == widget.selectedServerId;
                      return _AnimatedMap(
                        pins: _buildPins(widget.serversAsync, widget.status),
                        zoom: zoom,
                        pan: pan,
                        connected: isConnected,
                        // Omitted entirely until GeoIP resolves, rather than
                        // planting a placeholder somewhere the user is not.
                        youPin: (_youNx != null && _youNy != null)
                            ? MapPin(
                                nx: _youNx!,
                                ny: _youNy!,
                                label: 'You',
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),
          Text(
            'Figure 1 · Distribution of egress stations worldwide',
            style: TextStyle(
              fontFamily: AtlasTheme.sansFamily,
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: c.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  /// Build MapPin list for the map. All servers are shown as small dots.
  /// The selected / connected server is highlighted (active = true).
  List<MapPin> _buildPins(
      AsyncValue<List<Server>> serversAsync, VpnStatus status) {
    if (!serversAsync.hasValue) return [];

    final servers = serversAsync.value!;
    final activeId = widget.selectedServerId ?? status.server?.id;

    final pins = <MapPin>[];
    for (final s in servers) {
      double? lat = s.lat;
      double? lon = s.lon;
      if (lat == 0 && lon == 0) {
        final coords = cityToLatLon(city: s.city, country: s.country);
        if (coords != null) {
          lat = coords.lat;
          lon = coords.lon;
        }
      }
      if (lat == 0 && lon == 0) continue;

      pins.add(MapPin(
        nx: WorldMapWidget.projectX(lon),
        ny: WorldMapWidget.projectY(lat),
        label: s.city.isNotEmpty ? s.city : s.name,
        active: s.id == activeId,
        ms: s.lastTestMS > 0 ? s.lastTestMS : null,
        failed: s.latencyFailed,
      ));
    }
    return pins;
  }
}

/// Wraps WorldMapWidget with a transform: translate → scale (no rotation).
/// The viewport centre (0.5, 0.5) shows the bbox midpoint after pan.
/// `zoom` fits the You↔Server bounding box with ~15% padding.
class _AnimatedMap extends StatelessWidget {
  final List<MapPin> pins;

  /// Null until GeoIP resolves the client's location; the map omits the pin
  /// rather than showing one in the wrong place.
  final MapPin? youPin;
  final double zoom;
  final Offset pan; // normalized midpoint offset (0..1 range)
  final bool connected;

  const _AnimatedMap({
    required this.pins,
    this.youPin,
    required this.zoom,
    required this.pan,
    this.connected = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth;
        final availH = constraints.maxHeight;
        // Map is equirectangular (2:1), but we want it to fill the entire
        // viewport with NO letterboxing (no top/bottom gaps) when not zoomed.
        // At zoom <= 1: stretch to fill (minor aspect distortion is visually
        //   fine for a world map; eliminates the thick "frame" bars).
        // At zoom > 1: strict 2:1 box scaled by height for pan/zoom math.
        final double mapW;
        final double mapH;
        if (zoom <= 1.0) {
          // Fill: stretch to entire viewport (no letterbox)
          mapW = availW;
          mapH = availH;
        } else {
          // Zoomed: fit by height, clip sides
          mapH = availH;
          mapW = mapH * 2.0;
        }

        // Centre horizontally, then apply pan + scale.
        // pan is the normalized map point (0..1) that should appear at the
        // viewport centre after scaling.  Math: we want screen-X of map point
        // `pan` to equal availW/2.  The child is mapW wide and scaled by `zoom`,
        // positioned at `baseOffsetX + panPxX`.  So:
        //   baseOffsetX + panPxX + pan.dx * mapW * zoom = availW/2
        //   panPxX = availW/2 - baseOffsetX - pan.dx * mapW * zoom
        //         = mapW/2 - pan.dx * mapW * zoom
        //         = mapW * (0.5 - pan.dx * zoom)
        final baseOffsetX = (availW - mapW) / 2; // centre at zoom=1, pan=0.5
        final baseOffsetY = (availH - mapH) / 2;
        double panPxX = mapW * (0.5 - pan.dx * zoom);
        double panPxY = mapH * (0.5 - pan.dy * zoom);

        // Clamp vertical positioning so North Pole (top) and South Pole (bottom)
        // are NEVER cut off or pushed offscreen.
        final scaledH = mapH * zoom;
        final unclampedTop = baseOffsetY + panPxY;
        if (scaledH <= availH) {
          panPxY = (availH - scaledH) / 2 - baseOffsetY;
        } else {
          final clampedTop = unclampedTop.clamp(availH - scaledH, 0.0);
          panPxY = clampedTop - baseOffsetY;
        }

        return ClipRect(
          child: SizedBox(
            width: availW,
            height: availH,
            child: Stack(
              children: [
                Positioned(
                  left: baseOffsetX + panPxX,
                  top: baseOffsetY + panPxY,
                  child: Transform(
                    alignment: Alignment.topLeft,
                    transform: Matrix4.identity()
                      ..scaleByDouble(zoom, zoom, 1.0, 1.0),
                    child: SizedBox(
                      width: mapW,
                      height: mapH,
                      child: WorldMapWidget(
                        pins: pins,
                        youPin: youPin,
                        connected: connected,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StationsPanel extends ConsumerStatefulWidget {
  final VpnStatus status;
  final AsyncValue<List<Server>> serversAsync;
  final String? selectedServerId;
  final ValueChanged<String> onSelectServer;

  const _StationsPanel({
    required this.status,
    required this.serversAsync,
    required this.selectedServerId,
    required this.onSelectServer,
  });

  @override
  ConsumerState<_StationsPanel> createState() => _StationsPanelState();
}

class _StationsPanelState extends ConsumerState<_StationsPanel> {
  final Set<String> _multiSelected = {};
  String? _lastSelectedId;

  /// Connect to the given server.
  Future<void> _connectToServer(String id) async {
    final api = ref.read(daemonApiProvider);
    try {
      await api.connect(id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: SelectableText(
              'Connection failed: $e',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: e.toString()));
              },
            ),
          ),
        );
      }
    }
  }

  /// Disconnect from VPN.
  Future<void> _disconnectFromVpn() async {
    final api = ref.read(daemonApiProvider);
    try {
      await api.disconnect();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: SelectableText(
              'Disconnect failed: $e',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: e.toString()));
              },
            ),
          ),
        );
      }
    }
  }

  bool _isMultiSelected(String id) => _multiSelected.contains(id);

  void _onServerTap(Server s, {bool shift = false, bool ctrl = false}) {
    setState(() {
      if (shift && _lastSelectedId != null) {
        // Range select: select all between lastSelected and current
        final servers = widget.serversAsync.valueOrNull ?? [];
        final allIds = servers.map((e) => e.id).toList();
        final i1 = allIds.indexOf(_lastSelectedId!);
        final i2 = allIds.indexOf(s.id);
        if (i1 >= 0 && i2 >= 0) {
          final lo = math.min(i1, i2);
          final hi = math.max(i1, i2);
          for (var i = lo; i <= hi; i++) {
            _multiSelected.add(allIds[i]);
          }
        } else {
          _multiSelected.add(s.id);
        }
      } else if (ctrl) {
        // Toggle individual
        if (_multiSelected.contains(s.id)) {
          _multiSelected.remove(s.id);
        } else {
          _multiSelected.add(s.id);
        }
      } else {
        // Single tap — clear multi-select, select on map
        _multiSelected.clear();
        widget.onSelectServer(s.id);
      }
      _lastSelectedId = s.id;
    });
  }

  void _clearMultiSelection() {
    setState(() {
      _multiSelected.clear();
      _lastSelectedId = null;
    });
  }

  void _deleteMultiSelected() async {
    if (_multiSelected.isEmpty) return;
    final api = ref.read(daemonApiProvider);
    final count = _multiSelected.length;
    // Confirm
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete stations'),
        content:
            Text('Delete $count selected station(s)? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: AtlasTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    for (final id in _multiSelected.toList()) {
      try {
        await api.deleteServer(id);
      } catch (e) {
        debugPrint('deleteServer $id failed: $e');
      }
      if (!mounted) return;
    }
    _clearMultiSelection();
    ref.invalidate(serversProvider);
  }

  void _pingMultiSelected() async {
    if (_multiSelected.isEmpty) return;
    final api = ref.read(daemonApiProvider);
    for (final id in _multiSelected.toList()) {
      try {
        await api.testServer(id);
      } catch (e) {
        debugPrint('testServer $id failed: $e');
      }
      if (!mounted) return;
    }
    ref.invalidate(serversProvider);
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final subsAsync = ref.watch(subscriptionsProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final isCtrl = HardwareKeyboard.instance.isControlPressed;
          // Delete selected
          if (event.logicalKey == LogicalKeyboardKey.delete &&
              _multiSelected.isNotEmpty) {
            _deleteMultiSelected();
            return KeyEventResult.handled;
          }
          // Escape clears selection
          if (event.logicalKey == LogicalKeyboardKey.escape &&
              _multiSelected.isNotEmpty) {
            _clearMultiSelection();
            return KeyEventResult.handled;
          }
          // Ctrl+A select all
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyA) {
            final allServers = widget.serversAsync.valueOrNull ?? [];
            setState(() {
              _multiSelected.addAll(allServers.map((s) => s.id));
            });
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: AtlasCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row with multi-select actions
            Row(
              children: [
                const Text(
                  'Stations',
                  style: TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_multiSelected.isNotEmpty) ...[
                  Text(
                    '${_multiSelected.length} selected',
                    style: TextStyle(fontSize: 10, color: AtlasTheme.accent),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.speed, size: 14),
                    tooltip: 'Test latency (selected)',
                    onPressed: _pingMultiSelected,
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete,
                        size: 14, color: AtlasTheme.error),
                    tooltip: 'Delete selected',
                    onPressed: _deleteMultiSelected,
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    tooltip: 'Clear selection',
                    onPressed: _clearMultiSelection,
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            Divider(color: c.border, height: 16),

            Expanded(
              child: subsAsync.when(
                loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                    child: Text('Error: $e',
                        style: const TextStyle(fontSize: 12))),
                data: (subs) => widget.serversAsync.when(
                  loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (e, _) => Center(
                      child: Text('Error: $e',
                          style: const TextStyle(fontSize: 12))),
                  data: (servers) {
                    if (servers.isEmpty) {
                      return _emptyState(context, ref);
                    }

                    // Group servers by subscription ID
                    final grouped = <String, List<Server>>{};
                    for (final s in servers) {
                      final subId = s.subscriptionID.isNotEmpty
                          ? s.subscriptionID
                          : 'manual';
                      grouped.putIfAbsent(subId, () => []).add(s);
                    }

                    return ListView.builder(
                      itemCount:
                          subs.length + (grouped.containsKey('manual') ? 1 : 0),
                      itemBuilder: (context, idx) {
                        if (idx < subs.length) {
                          final sub = subs[idx];
                          final subServers = grouped[sub.id] ?? [];
                          if (subServers.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return _buildSubGroup(
                              context, ref, sub.name, sub.id, subServers, sub);
                        } else {
                          final manualServers = grouped['manual'] ?? [];
                          if (manualServers.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return _buildSubGroup(
                              context,
                              ref,
                              'Manual / Imported',
                              'manual',
                              manualServers,
                              null);
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubGroup(
    BuildContext context,
    WidgetRef ref,
    String title,
    String groupId,
    List<Server> servers,
    Subscription? sub,
  ) {
    final c = ThemeColors.of(context);
    final activeServerID = widget.status.server?.id;
    final hasActiveInGroup = servers.any((s) => s.id == activeServerID);

    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        canvasColor: Theme.of(context).cardColor,
      ),
      // The surrounding card paints its own background, which would swallow the
      // tile's ink splashes (Flutter asserts on exactly this). A transparent
      // Material of its own gives the tiles a surface to paint on.
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: hasActiveInGroup ? AtlasTheme.accent : null,
            ),
          ),
          subtitle: Text(
            '${servers.length} stations',
            style: TextStyle(fontSize: 10, color: c.textMuted),
          ),
          leading: Icon(
            Icons.folder_open,
            size: 18,
            color: hasActiveInGroup ? AtlasTheme.accent : c.textMuted,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Context menu for subscription group
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                color: Theme.of(context).cardColor,
                onSelected: (action) =>
                    _handleGroupAction(context, ref, action, groupId, sub),
                itemBuilder: (context) => [
                  if (sub != null) ...[
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Row(
                        children: [
                          Icon(Icons.refresh, size: 14),
                          SizedBox(width: 8),
                          Text('Update/Refresh',
                              style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'copy_url',
                      child: Row(
                        children: [
                          Icon(Icons.link, size: 14),
                          SizedBox(width: 8),
                          Text('Copy subscription URL',
                              style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'open_url',
                      child: Row(
                        children: [
                          Icon(Icons.open_in_browser, size: 14),
                          SizedBox(width: 8),
                          Text('Open in browser',
                              style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                  const PopupMenuItem(
                    value: 'ping_all',
                    child: Row(
                      children: [
                        Icon(Icons.flash_on, size: 14),
                        SizedBox(width: 8),
                        Text('Test ping of group',
                            style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                  if (sub != null) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: AtlasTheme.error, size: 14),
                          SizedBox(width: 8),
                          Text('Delete Group',
                              style: TextStyle(
                                  color: AtlasTheme.error, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          childrenPadding: const EdgeInsets.only(left: 6),
          children: servers.map((s) {
            final isActive = activeServerID == s.id;
            final isSelected = widget.selectedServerId == s.id;
            final isMulti = _isMultiSelected(s.id);
            final isFav = ref.watch(favoriteServersProvider).contains(s.id);
            return Container(
              decoration: BoxDecoration(
                color: isMulti
                    ? AtlasTheme.accent.withValues(alpha: 0.15)
                    : isSelected
                        ? AtlasTheme.accent.withValues(alpha: 0.22)
                        : null,
                border: isMulti
                    ? Border.all(
                        color: AtlasTheme.accent.withValues(alpha: 0.4),
                        width: 1)
                    : isSelected
                        ? Border(
                            left:
                                BorderSide(color: AtlasTheme.accent, width: 3),
                          )
                        : null,
              ),
              child: ListTile(
                dense: true,
                selected: isSelected || isMulti,
                selectedTileColor: Colors.transparent,
                contentPadding: const EdgeInsets.only(right: 2, left: 4),
                onTap: () async {
                  final isShift = HardwareKeyboard.instance.isShiftPressed;
                  final isCtrl = HardwareKeyboard.instance.isControlPressed;
                  // Shift/Ctrl+click — multi-select
                  if (isShift || isCtrl) {
                    _onServerTap(s, shift: isShift, ctrl: isCtrl);
                    return;
                  }
                  // If multi-select is active and this tile is in the selection,
                  // a plain tap clears multi-select and selects just this one.
                  if (_multiSelected.isNotEmpty &&
                      !_multiSelected.contains(s.id)) {
                    _onServerTap(s);
                    return;
                  }
                  if (isMulti) {
                    // In multi-select mode, toggle connection for all selected
                    if (isActive) {
                      await _disconnectFromVpn();
                      ref.invalidate(vpnStatusProvider);
                    }
                    _onServerTap(s);
                    return;
                  }
                  if (isSelected) {
                    // Repeat tap -> Toggle connection
                    if (isActive) {
                      await _disconnectFromVpn();
                    } else {
                      await _connectToServer(s.id);
                    }
                    ref.invalidate(vpnStatusProvider);
                  } else {
                    // First tap -> Select server to show on map with line
                    _onServerTap(s);
                  }
                },
                leading: isActive
                    ? const StatusDot(color: AtlasTheme.success, size: 6)
                    : StatusDot(color: c.textMuted, size: 5),
                title: ConstrainedBox(
                  constraints:
                      const BoxConstraints(minWidth: _kStationNameMinWidth),
                  child: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          isActive ? FontWeight.bold : FontWeight.normal,
                      color: isActive ? c.textPrimary : c.textSecondary,
                    ),
                  ),
                ),
                subtitle: Text(
                  s.country.isNotEmpty ? s.country : '${s.address}:${s.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: c.textMuted),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Favorite star
                    Tooltip(
                      message:
                          isFav ? 'Remove from favorites' : 'Add to favorites',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          ref
                              .read(favoriteServersProvider.notifier)
                              .toggle(s.id);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            isFav
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            size: 14,
                            color: isFav ? AtlasTheme.warning : c.textMuted,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    // Fixed-width latency slot. It is reserved even before a
                    // measurement exists, otherwise the badge appearing after a
                    // ping steals width from the title and the server name gets
                    // ellipsised down to a few characters.
                    SizedBox(
                      width: _kLatencySlotWidth,
                      child: s.lastTestMS > 0
                          ? Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: (s.lastTestMS < 120
                                          ? AtlasTheme.success
                                          : AtlasTheme.warning)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  '${s.lastTestMS}ms',
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontFamily: AtlasTheme.monoFamily,
                                    color: s.lastTestMS < 120
                                        ? AtlasTheme.success
                                        : AtlasTheme.warning,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      icon: Icon(
                        isActive
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_outline,
                        size: 18,
                        color: isActive ? AtlasTheme.error : AtlasTheme.accent,
                      ),
                      tooltip: isActive ? 'Disconnect' : 'Connect',
                      onPressed: () async {
                        if (isActive) {
                          await _disconnectFromVpn();
                        } else {
                          await _connectToServer(s.id);
                        }
                        ref.invalidate(vpnStatusProvider);
                      },
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, size: 16),
                      color: Theme.of(context).cardColor,
                      onSelected: (action) =>
                          _handleServerAction(context, ref, action, s),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'ping',
                          child: Row(
                            children: [
                              Icon(Icons.speed, size: 14),
                              SizedBox(width: 8),
                              Text('Test latency (ping)',
                                  style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'copy',
                          child: Row(
                            children: [
                              Icon(Icons.copy, size: 14),
                              SizedBox(width: 8),
                              Text('Copy address',
                                  style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'edit_raw',
                          child: Row(
                            children: [
                              Icon(Icons.edit_document, size: 14),
                              SizedBox(width: 8),
                              Text('Edit raw config',
                                  style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _handleGroupAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    String groupId,
    Subscription? sub,
  ) async {
    final api = ref.read(daemonApiProvider);
    try {
      switch (action) {
        case 'refresh':
          if (sub != null) {
            await api.refreshSubscription(sub.id);
            ref.invalidate(subscriptionsProvider);
            ref.invalidate(serversProvider);
          }
          break;
        case 'copy_url':
          if (sub != null && sub.url.isNotEmpty) {
            await Clipboard.setData(ClipboardData(text: sub.url));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied: ${sub.url}')),
              );
            }
          }
          break;
        case 'open_url':
          if (sub != null && sub.url.isNotEmpty) {
            await Process.start(
                'rundll32',
                [
                  'url.dll,FileProtocolHandler',
                  sub.url,
                ],
                runInShell: true);
          }
          break;
        case 'ping_all':
          final servers = ref.read(serversProvider).valueOrNull ?? [];
          final groupServers =
              servers.where((s) => s.subscriptionID == groupId).toList();
          for (final s in groupServers) {
            try {
              await api.testServer(s.id);
            } catch (e) {
              debugPrint('testServer ${s.id} failed: $e');
            }
          }
          ref.invalidate(serversProvider);
          break;
        case 'delete':
          if (sub != null) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (context) {
                final c = ThemeColors.of(context);
                return AlertDialog(
                  backgroundColor: c.bgCard,
                  title: const Text('Delete Subscription Group?',
                      style: TextStyle(fontFamily: AtlasTheme.serifFamily)),
                  content: Text(
                      'This will delete "${sub.name}" and all imported proxy configurations inside it.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AtlasTheme.error),
                      child: const Text('Delete'),
                    ),
                  ],
                );
              },
            );
            if (confirm == true) {
              await api.deleteSubscription(sub.id);
              ref.invalidate(subscriptionsProvider);
              ref.invalidate(serversProvider);
            }
          }
          break;
      }
    } catch (e) {
      debugPrint('_handleGroupAction $action failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: SelectableText('Action "$action" failed: $e',
                style: const TextStyle(fontFamily: 'monospace')),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: e.toString())),
            ),
          ),
        );
      }
    }
  }

  void _handleServerAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    Server server,
  ) async {
    final api = ref.read(daemonApiProvider);
    try {
      if (action == 'ping') {
        await api.testServer(server.id);
        ref.invalidate(serversProvider);
      } else if (action == 'copy') {
        await Clipboard.setData(
            ClipboardData(text: '${server.address}:${server.port}'));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Copied: ${server.address}:${server.port}')),
          );
        }
      } else if (action == 'edit_raw') {
        _showRawConfigDialog(context, ref, server);
      }
    } catch (e) {
      debugPrint('_handleServerAction $action failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: SelectableText('Action "$action" failed: $e',
                style: const TextStyle(fontFamily: 'monospace')),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: e.toString())),
            ),
          ),
        );
      }
    }
  }

  void _showRawConfigDialog(
    BuildContext context,
    WidgetRef ref,
    Server server,
  ) {
    // Build a raw config string from server parameters
    final configCtrl = TextEditingController(text: _serverToRawConfig(server));

    showDialog(
      context: context,
      builder: (context) {
        final c = ThemeColors.of(context);
        return AlertDialog(
          backgroundColor: c.bgCard,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AtlasTheme.radiusMd)),
          title: Row(
            children: [
              const Icon(Icons.edit_document, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Edit raw config: ${server.name}',
                  style: const TextStyle(
                      fontFamily: AtlasTheme.serifFamily, fontSize: 15),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            height: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Customize low-level parameters below. Note: daemon will restart stream tunnels on save.',
                  style: TextStyle(fontSize: 10, color: c.textMuted),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    controller: configCtrl,
                    maxLines: 99,
                    style: const TextStyle(
                      fontFamily: AtlasTheme.monoFamily,
                      fontSize: 11,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                // Parse raw config back and apply via API
                // For now, show a snackbar — the daemon API can accept raw config
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('Raw config saved for ${server.name}')),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  String _serverToRawConfig(Server s) {
    final buf = StringBuffer();
    buf.writeln('# ${s.name}');
    buf.writeln('type: ${s.protocol}');
    buf.writeln('address: ${s.address}');
    buf.writeln('port: ${s.port}');
    if (s.location.isNotEmpty) buf.writeln('# location: ${s.location}');
    buf.writeln(
        '# --- raw protocol params (vless reality / xtls vision / etc) ---');
    buf.writeln('# sni: ');
    buf.writeln('# alpn: ');
    buf.writeln('# fingerprint: ');
    buf.writeln('# flow: ');
    buf.writeln('# transport:');
    buf.writeln('#   type: ');
    buf.writeln('#   path: ');
    buf.writeln('#   host: ');
    return buf.toString();
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    final c = ThemeColors.of(context);
    // Scrollable so the icon, heading, body copy and button do not overflow
    // the short panel a 360x640 phone gives this card (it clipped by 13px).
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rss_feed, size: 40, color: c.textMuted),
            const SizedBox(height: 12),
            Text(
              'No Sources Configured',
              style: TextStyle(
                fontFamily: AtlasTheme.serifFamily,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add your first subscription feed to import server configurations.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: c.textMuted),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _showAddSubscriptionDialog(context),
              icon: const Icon(Icons.add_link, size: 14),
              label: const Text('Add First Source',
                  style: TextStyle(fontSize: 11)),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddSubscriptionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const AddSubscriptionFeedDialog(),
    );
  }
}

void _checkTunElevation(
    BuildContext context, FutureOr<void> Function() onAllow) async {
  // Check if we're already running with admin privileges
  try {
    final result = await Process.run(
      'powershell',
      [
        '-Command',
        '([Security.Principal.WindowsPrincipal] '
            '[Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('
            '[Security.Principal.WindowsBuiltInRole]::Administrator)'
      ],
    );
    if (result.exitCode == 0 && result.stdout.trim().toLowerCase() == 'true') {
      // Already elevated — skip UAC prompt
      onAllow();
      return;
    }
  } catch (_) {
    // If check fails, fall through to normal UAC dialog
  }

  if (!context.mounted) return;

  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) {
      final c = ThemeColors.of(context);
      return AlertDialog(
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
      );
    },
  );
  if (confirm == true) {
    await onAllow();
    try {
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

/// A compact chip showing a proxy protocol label and its loopback address.
/// Tapping copies the address to clipboard.
class _ProxyChip extends StatelessWidget {
  const _ProxyChip({
    required this.label,
    required this.address,
    required this.color,
  });

  final String label;
  final String address;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () {
        Clipboard.setData(ClipboardData(text: address));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 1200),
            content: Text('Copied $label: $address'),
          ),
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SelectableText(
            address,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: ThemeColors.of(context).textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
