import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/qrcode.dart' hide QRCode;
import 'package:zxing_lib/zxing.dart';

import '../../core/models/manual_server_config.dart';
import '../../core/models/protocol.dart';
import '../../core/models/server.dart';
import '../../core/models/server_group.dart';

/// Top-level entry point: opens the modal Add Server dialog.
/// Returns a list of [Server] objects created fromManual/Clipboard/QR/File
/// import or from the wizard. Returns `null` if the user cancels.
Future<List<Server>?> showAddServerDialog(BuildContext context) {
  return showDialog<List<Server>?>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _AddServerDialog(),
  );
}

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog();

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

enum _ImportMethod { manual, clipboard, qr, file }

class _AddServerDialogState extends State<_AddServerDialog> {
  _ImportMethod? _method;
  List<Server> _parsed = const [];
  String? _parseError;
  bool _busy = false;

  // Wizard state (used only for manual)
  final ManualServerConfig _cfg = ManualServerConfig();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: SizedBox(
        width: 760,
        height: 640,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Add Server'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(null),
              ),
            ),
            body: Column(
              children: [
                // ── Method chooser ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Row(
                    children: [
                      _methodChip(
                          _ImportMethod.manual, Icons.edit_outlined, 'Manual'),
                      const SizedBox(width: 10),
                      _methodChip(_ImportMethod.clipboard, Icons.content_paste,
                          'Clipboard'),
                      const SizedBox(width: 10),
                      _methodChip(
                          _ImportMethod.qr, Icons.qr_code_scanner, 'QR'),
                      const SizedBox(width: 10),
                      _methodChip(_ImportMethod.file, Icons.file_open, 'File'),
                    ],
                  ),
                ),
                const Divider(height: 16),
                // ── Body ──
                Expanded(child: _bodyFor()),
              ],
            ),
            bottomNavigationBar: _bottomBar(),
          ),
        ),
      ),
    );
  }

  Widget _methodChip(_ImportMethod m, IconData icon, String label) {
    final selected = _method == m;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          _method = m;
          _parsed = const [];
          _parseError = null;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 22,
                  color:
                      selected ? Theme.of(context).colorScheme.primary : null),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyFor() {
    switch (_method) {
      case _ImportMethod.manual:
        return _ManualWizard(
          cfg: _cfg,
          onChanged: () => setState(() {}),
        );
      case _ImportMethod.clipboard:
        return _ClipboardImport(
          onParsed: (s, e) => setState(() {
            _parsed = s;
            _parseError = e;
          }),
          busy: _busy,
        );
      case _ImportMethod.qr:
        return _QrImport(
          onParsed: (s, e) => setState(() {
            _parsed = s;
            _parseError = e;
          }),
          busy: _busy,
          setBusy: (b) => setState(() => _busy = b),
        );
      case _ImportMethod.file:
        return _FileImport(
          onParsed: (s, e) => setState(() {
            _parsed = s;
            _parseError = e;
          }),
          busy: _busy,
          setBusy: (b) => setState(() => _busy = b),
        );
      case null:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_link,
                    size: 64, color: Theme.of(context).hintColor),
                const SizedBox(height: 16),
                Text(
                  'Choose an import method above',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Manual: step-by-step wizard\nClipboard: paste a share link (vless://, ss://, vmess://…)\nQR: pick a QR image\nFile: open a .txt/.yaml/.json config',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget? _bottomBar() {
    if (_method == null) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_parseError != null)
            Expanded(
              child: Text(
                _parseError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label:
                Text(_method == _ImportMethod.manual ? 'Add server' : 'Import'),
            onPressed: _canAdd() ? _onAdd : null,
          ),
        ],
      ),
    );
  }

  bool _canAdd() {
    if (_method == _ImportMethod.manual) return _cfg.isValid;
    return _parsed.isNotEmpty;
  }

  void _onAdd() {
    if (_method == _ImportMethod.manual) {
      final uri = _cfg.toUri();
      if (uri == null) {
        // Fallback: build directly from manual config
        final s = Server(
          id: '',
          name: _cfg.name.isEmpty
              ? '${_cfg.protocol.displayName} ${_cfg.address}'
              : _cfg.name,
          protocol: _cfg.protocol,
          address: _cfg.address,
          port: _cfg.port,
          groupId: ServerGroup.ungroupedId,
        );
        Navigator.of(context).pop([s]);
        return;
      }
      final parsed = Server.fromUri(uri);
      if (parsed != null) {
        if (_cfg.name.isNotEmpty) {
          Navigator.of(context).pop([
            Server(
              id: '',
              name: _cfg.name,
              protocol: parsed.protocol,
              address: parsed.address,
              port: parsed.port,
              groupId: ServerGroup.ungroupedId,
            )
          ]);
        } else {
          Navigator.of(context).pop([parsed]);
        }
      } else {
        setState(() => _parseError =
            'Could not build a valid config from the provided fields.');
      }
      return;
    }
    Navigator.of(context).pop(_parsed);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  MANUAL WIZARD — protocol choice → dynamic fields → preview
// ══════════════════════════════════════════════════════════════════════════════
class _ManualWizard extends StatefulWidget {
  final ManualServerConfig cfg;
  final VoidCallback onChanged;
  const _ManualWizard({required this.cfg, required this.onChanged});

  @override
  State<_ManualWizard> createState() => _ManualWizardState();
}

class _ManualWizardState extends State<_ManualWizard> {
  int _step = 0; // 0=protocol, 1=fields, 2=preview

  @override
  Widget build(BuildContext context) {
    return Stepper(
      currentStep: _step,
      type: StepperType.horizontal,
      onStepContinue: () {
        if (_step < 2) setState(() => _step++);
      },
      onStepCancel: () {
        if (_step > 0) setState(() => _step--);
      },
      onStepTapped: (i) => setState(() => _step = i),
      controlsBuilder: (ctx, details) {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              if (_step < 2)
                FilledButton(
                    onPressed: details.onStepContinue,
                    child: const Text('Next')),
              if (_step > 0) ...[
                const SizedBox(width: 8),
                TextButton(
                    onPressed: details.onStepCancel, child: const Text('Back')),
              ],
            ],
          ),
        );
      },
      steps: [
        Step(
          title: const Text('Protocol'),
          isActive: _step >= 0,
          state: _step > 0 ? StepState.complete : StepState.indexed,
          content: _ProtocolPicker(
            cfg: widget.cfg,
            onChanged: widget.onChanged,
          ),
        ),
        Step(
          title: const Text('Configuration'),
          isActive: _step >= 1,
          state: _step > 1 ? StepState.complete : StepState.indexed,
          content: _ConfigFields(cfg: widget.cfg, onChanged: widget.onChanged),
        ),
        Step(
          title: const Text('Preview'),
          isActive: _step >= 2,
          state: _step == 2 ? StepState.indexed : StepState.disabled,
          content: _Preview(cfg: widget.cfg),
        ),
      ],
    );
  }
}

class _ProtocolPicker extends StatelessWidget {
  final ManualServerConfig cfg;
  final VoidCallback onChanged;
  const _ProtocolPicker({required this.cfg, required this.onChanged});

  static const _groups = <(String, List<Protocol>)>[
    (
      'Xray / Core',
      [
        Protocol.vless,
        Protocol.vmess,
        Protocol.trojan,
        Protocol.shadowsocks,
        Protocol.shadowsocks2022,
        Protocol.shadowsocksR,
        Protocol.shadowTLS,
        Protocol.anyTLS,
        Protocol.naive,
        Protocol.wireguard,
      ]
    ),
    (
      'sing-box only',
      [
        Protocol.hysteria2,
        Protocol.tuic,
        Protocol.juicity,
        Protocol.mieru,
        Protocol.http3,
        Protocol.trustTunnel,
      ]
    ),
    (
      'Basic tunnel',
      [
        Protocol.socks,
        Protocol.http,
        Protocol.ssh,
        Protocol.custom,
      ]
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in _groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(g.$1,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(letterSpacing: 0.5)),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final p in g.$2)
                ChoiceChip(
                  label: Text(p.displayName),
                  selected: cfg.protocol == p,
                  onSelected: (sel) {
                    if (sel) {
                      cfg.protocol = p;
                      onChanged();
                    }
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── Common input helpers ─────────────────────────────────────────────────────
Widget _tf(String label, String? value, ValueChanged<String> onChg,
        {bool obscure = false, TextInputType? keyboardType, String? hint}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        initialValue: value,
        onChanged: onChg,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );

class _ConfigFields extends StatelessWidget {
  final ManualServerConfig cfg;
  final VoidCallback onChanged;
  const _ConfigFields({required this.cfg, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─ Name (optional, always) ─
          _tf('Display name (optional)', cfg.name.isEmpty ? null : cfg.name,
              (v) {
            cfg.name = v;
            onChanged();
          }, hint: 'Auto-generated if left blank'),
          // ─ Address + port ─
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  flex: 3,
                  child: _tf(
                      'Address', cfg.address.isEmpty ? null : cfg.address, (v) {
                    cfg.address = v;
                    onChanged();
                  }, hint: 'example.com')),
              const SizedBox(width: 10),
              Expanded(
                  flex: 1,
                  child: _tf('Port', cfg.port == 0 ? null : cfg.port.toString(),
                      (v) {
                    final n = int.tryParse(v);
                    if (n != null) {
                      cfg.port = n;
                      onChanged();
                    }
                  }, keyboardType: TextInputType.number)),
            ],
          ),
          // ─ Protocol-specific fields ─
          ..._protocolFields(context),
        ],
      ),
    );
  }

  List<Widget> _protocolFields(BuildContext context) {
    final p = cfg.protocol;
    switch (p) {
      case Protocol.vless:
      case Protocol.vmess:
        return [
          _tf(p == Protocol.vmess ? 'UUID' : 'UUID / password',
              cfg.uuid.isEmpty ? null : cfg.uuid, (v) {
            cfg.uuid = v;
            onChanged();
          }),
          if (p == Protocol.vmess)
            _dropdown(
                'Encryption', ['auto', 'none', 'aes-128-gcm'], cfg.encryption,
                (v) {
              cfg.encryption = v;
              onChanged();
            }),
          _dropdown(
              'Transport',
              ['tcp', 'ws', 'grpc', 'h2', 'httpupgrade', 'xhttp'],
              cfg.network, (v) {
            cfg.network = v;
            onChanged();
          }),
          if (cfg.network != 'tcp') ...[
            _tf('Path', cfg.path.isEmpty ? null : cfg.path, (v) {
              cfg.path = v;
              onChanged();
            }, hint: '/path'),
            _tf('Host header', cfg.hostHeader.isEmpty ? null : cfg.hostHeader,
                (v) {
              cfg.hostHeader = v;
              onChanged();
            }),
          ],
          SwitchListTile(
            dense: true,
            title: const Text('TLS'),
            value: cfg.tls,
            onChanged: (v) {
              cfg.tls = v;
              onChanged();
            },
          ),
          if (cfg.tls) ...[
            _tf('SNI', cfg.sni.isEmpty ? null : cfg.sni, (v) {
              cfg.sni = v;
              onChanged();
            }),
            _tf('ALPN', cfg.alpn.isEmpty ? null : cfg.alpn, (v) {
              cfg.alpn = v;
              onChanged();
            }, hint: 'h2,http/1.1'),
            _dropdown(
                'uTLS Fingerprint',
                ['chrome', 'firefox', 'safari', 'edge', 'random', 'none'],
                cfg.fingerprint, (v) {
              cfg.fingerprint = v;
              onChanged();
            }),
            if (p == Protocol.vless)
              _tf('Flow (optional)', cfg.flow.isEmpty ? null : cfg.flow, (v) {
                cfg.flow = v;
                onChanged();
              }, hint: 'xtls-rprx-vision'),
            SwitchListTile(
              dense: true,
              title: const Text('Allow insecure (skip cert verify)'),
              value: cfg.allowInsecure,
              onChanged: (v) {
                cfg.allowInsecure = v;
                onChanged();
              },
            ),
          ],
        ];
      case Protocol.trojan:
        return [
          _tf('Password', cfg.uuid.isEmpty ? null : cfg.uuid, (v) {
            cfg.uuid = v;
            onChanged();
          }, obscure: true),
          _dropdown('Transport', ['tcp', 'ws', 'grpc', 'h2'], cfg.network, (v) {
            cfg.network = v;
            onChanged();
          }),
          if (cfg.network != 'tcp')
            _tf('Path', cfg.path.isEmpty ? null : cfg.path, (v) {
              cfg.path = v;
              onChanged();
            }),
          _tf('SNI', cfg.sni.isEmpty ? null : cfg.sni, (v) {
            cfg.sni = v;
            onChanged();
          }),
          _tf('ALPN', cfg.alpn.isEmpty ? null : cfg.alpn, (v) {
            cfg.alpn = v;
            onChanged();
          }, hint: 'h2,http/1.1'),
          _dropdown(
              'uTLS Fingerprint',
              ['chrome', 'firefox', 'safari', 'edge', 'random', 'none'],
              cfg.fingerprint, (v) {
            cfg.fingerprint = v;
            onChanged();
          }),
        ];
      case Protocol.shadowsocks:
        return [
          _dropdown(
              'Cipher',
              [
                'aes-256-gcm',
                'aes-128-gcm',
                'chacha20-ietf-poly1305',
                'aes-256-cfb',
                'aes-128-cfb',
                'rc4-md5',
              ],
              cfg.ssMethod, (v) {
            cfg.ssMethod = v;
            onChanged();
          }),
          _tf('Password', cfg.ssPassword.isEmpty ? null : cfg.ssPassword, (v) {
            cfg.ssPassword = v;
            onChanged();
          }, obscure: true),
          _dropdown('Plugin (optional)', ['', 'obfs-local', 'v2ray-plugin'],
              cfg.ssPlugin, (v) {
            cfg.ssPlugin = v;
            onChanged();
          }),
          if (cfg.ssPlugin.isNotEmpty)
            _tf('Plugin opts',
                cfg.ssPluginOpts.isEmpty ? null : cfg.ssPluginOpts, (v) {
              cfg.ssPluginOpts = v;
              onChanged();
            }),
        ];
      case Protocol.shadowsocks2022:
        return [
          _dropdown(
              'Cipher (SS2022)',
              [
                '2022-blake3-aes-128-gcm',
                '2022-blake3-aes-256-gcm',
                '2022-blake3-chacha20-poly1305',
                '2022-blake3-chacha8-poly1305',
              ],
              cfg.ssMethod, (v) {
            cfg.ssMethod = v;
            onChanged();
          }),
          _tf('Password (base64 key)',
              cfg.ssPassword.isEmpty ? null : cfg.ssPassword, (v) {
            cfg.ssPassword = v;
            onChanged();
          },
              obscure: true,
              hint: '32-char base64 for aes-128, 64-char for aes-256'),
        ];
      case Protocol.shadowsocksR:
        return [
          _dropdown(
              'Cipher',
              [
                'aes-256-cfb',
                'aes-128-cfb',
                'aes-192-cfb',
                'chacha20-ietf',
                'rc4-md5',
                'none',
              ],
              cfg.ssrMethod, (v) {
            cfg.ssrMethod = v;
            onChanged();
          }),
          _tf('Password', cfg.ssrPassword.isEmpty ? null : cfg.ssrPassword,
              (v) {
            cfg.ssrPassword = v;
            onChanged();
          }, obscure: true),
          _dropdown(
              'Obfs',
              [
                'plain',
                'http_simple',
                'tls1.2_ticket_auth',
                'tls1.2_ticket_fastauth'
              ],
              cfg.ssrObfs, (v) {
            cfg.ssrObfs = v;
            onChanged();
          }),
          _dropdown(
              'Protocol',
              [
                'origin',
                'auth_sha1_v4',
                'auth_aes128_md5',
                'auth_aes128_sha1',
                'auth_chain_a'
              ],
              cfg.ssrProtocol, (v) {
            cfg.ssrProtocol = v;
            onChanged();
          }),
          if (cfg.ssrProtocol != 'origin')
            _tf('Protocol param',
                cfg.ssrProtocolParam.isEmpty ? null : cfg.ssrProtocolParam,
                (v) {
              cfg.ssrProtocolParam = v;
              onChanged();
            }),
        ];
      case Protocol.shadowTLS:
        return [
          _dropdown('Version', ['3', '2'], cfg.shadowTlsVersion.toString(),
              (v) {
            cfg.shadowTlsVersion = int.tryParse(v) ?? 3;
            onChanged();
          }),
          _tf('Password',
              cfg.shadowTlsPassword.isEmpty ? null : cfg.shadowTlsPassword,
              (v) {
            cfg.shadowTlsPassword = v;
            onChanged();
          }, obscure: true),
          _tf('SNI (for TLS handshake)', cfg.sni.isEmpty ? null : cfg.sni, (v) {
            cfg.sni = v;
            onChanged();
          }),
        ];
      case Protocol.anyTLS:
        return [
          _tf('Password',
              cfg.anytlsPassword.isEmpty ? null : cfg.anytlsPassword, (v) {
            cfg.anytlsPassword = v;
            onChanged();
          }, obscure: true),
          _tf('SNI', cfg.sni.isEmpty ? null : cfg.sni, (v) {
            cfg.sni = v;
            onChanged();
          }),
          _dropdown(
              'Fingerprint',
              ['chrome', 'firefox', 'safari', 'edge', 'random'],
              cfg.anytlsFingerprint, (v) {
            cfg.anytlsFingerprint = v;
            onChanged();
          }),
        ];
      case Protocol.hysteria2:
        return [
          _tf('Auth password', cfg.auth.isEmpty ? null : cfg.auth, (v) {
            cfg.auth = v;
            onChanged();
          }, obscure: true),
          _tf('SNI', cfg.sni.isEmpty ? null : cfg.sni, (v) {
            cfg.sni = v;
            onChanged();
          }),
          _dropdown('Obfs', ['', 'salamander'], cfg.obfs, (v) {
            cfg.obfs = v;
            onChanged();
          }),
          if (cfg.obfs == 'salamander')
            _tf('Obfs password',
                cfg.obfsPassword.isEmpty ? null : cfg.obfsPassword, (v) {
              cfg.obfsPassword = v;
              onChanged();
            }, obscure: true),
          Row(
            children: [
              Expanded(
                  child: _tf('Up Mbps (0=∞)',
                      cfg.upMbps == 0 ? null : cfg.upMbps.toString(), (v) {
                final n = int.tryParse(v);
                if (n != null) {
                  cfg.upMbps = n;
                  onChanged();
                }
              }, keyboardType: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(
                  child: _tf('Down Mbps (0=∞)',
                      cfg.downMbps == 0 ? null : cfg.downMbps.toString(), (v) {
                final n = int.tryParse(v);
                if (n != null) {
                  cfg.downMbps = n;
                  onChanged();
                }
              }, keyboardType: TextInputType.number)),
            ],
          ),
          SwitchListTile(
            dense: true,
            title: const Text('0-RTT handshake'),
            value: cfg.zeroRttHandshake,
            onChanged: (v) {
              cfg.zeroRttHandshake = v;
              onChanged();
            },
          ),
        ];
      case Protocol.tuic:
      case Protocol.juicity:
        return [
          _tf('Auth (uuid:password)', cfg.auth.isEmpty ? null : cfg.auth, (v) {
            cfg.auth = v;
            onChanged();
          }, obscure: true),
          _tf('SNI', cfg.sni.isEmpty ? null : cfg.sni, (v) {
            cfg.sni = v;
            onChanged();
          }),
          _dropdown('Congestion', ['bbr', 'cubic', 'new_reno'],
              ['bbr', 'cubic', 'new_reno'][cfg.congestionControl], (v) {
            cfg.congestionControl = ['bbr', 'cubic', 'new_reno'].indexOf(v);
            onChanged();
          }),
          if (p == Protocol.tuic)
            _dropdown('UDP relay mode', ['native', 'quic'],
                ['native', 'quic'][cfg.udpRelayMode], (v) {
              cfg.udpRelayMode = ['native', 'quic'].indexOf(v);
              onChanged();
            }),
          SwitchListTile(
            dense: true,
            title: const Text('0-RTT handshake'),
            value: cfg.zeroRttHandshake,
            onChanged: (v) {
              cfg.zeroRttHandshake = v;
              onChanged();
            },
          ),
          if (p == Protocol.juicity)
            SwitchListTile(
              dense: true,
              title: const Text('Heartbeat'),
              value: cfg.heartbeat,
              onChanged: (v) {
                cfg.heartbeat = v;
                onChanged();
              },
            ),
        ];
      case Protocol.naive:
        return [
          _tf('Username', cfg.http3User.isEmpty ? null : cfg.http3User, (v) {
            cfg.http3User = v;
            onChanged();
          }),
          _tf('Password', cfg.http3Password.isEmpty ? null : cfg.http3Password,
              (v) {
            cfg.http3Password = v;
            onChanged();
          }, obscure: true),
          _tf('SNI', cfg.sni.isEmpty ? null : cfg.sni, (v) {
            cfg.sni = v;
            onChanged();
          }),
        ];
      case Protocol.mieru:
        return [
          _tf('Username', cfg.auth.isEmpty ? null : cfg.auth, (v) {
            cfg.auth = v;
            onChanged();
          }),
          _tf('Password', cfg.socksPassword.isEmpty ? null : cfg.socksPassword,
              (v) {
            cfg.socksPassword = v;
            onChanged();
          }, obscure: true),
        ];
      case Protocol.wireguard:
        return [
          _tf('Private key (base64)',
              cfg.wgPrivateKey.isEmpty ? null : cfg.wgPrivateKey, (v) {
            cfg.wgPrivateKey = v;
            onChanged();
          }, obscure: true),
          _tf('Peer public key (base64)',
              cfg.wgPeerPublicKey.isEmpty ? null : cfg.wgPeerPublicKey, (v) {
            cfg.wgPeerPublicKey = v;
            onChanged();
          }),
          _tf('Pre-shared key (optional)',
              cfg.wgPreSharedKey.isEmpty ? null : cfg.wgPreSharedKey, (v) {
            cfg.wgPreSharedKey = v;
            onChanged();
          }, obscure: true),
          _tf('Endpoint', cfg.wgEndpoint.isEmpty ? null : cfg.wgEndpoint, (v) {
            cfg.wgEndpoint = v;
            onChanged();
          }),
          _tf('MTU', cfg.wgMtu.toString(), (v) {
            final n = int.tryParse(v);
            if (n != null) {
              cfg.wgMtu = n;
              onChanged();
            }
          }, keyboardType: TextInputType.number),
        ];
      case Protocol.amneziaWG:
        return [
          _tf('Private key (base64)',
              cfg.wgPrivateKey.isEmpty ? null : cfg.wgPrivateKey, (v) {
            cfg.wgPrivateKey = v;
            onChanged();
          }, obscure: true),
          _tf('Peer public key (base64)',
              cfg.wgPeerPublicKey.isEmpty ? null : cfg.wgPeerPublicKey, (v) {
            cfg.wgPeerPublicKey = v;
            onChanged();
          }),
          _tf('Endpoint', cfg.wgEndpoint.isEmpty ? null : cfg.wgEndpoint, (v) {
            cfg.wgEndpoint = v;
            onChanged();
          }),
        ];
      case Protocol.http3:
        return [
          _tf('Username', cfg.http3User.isEmpty ? null : cfg.http3User, (v) {
            cfg.http3User = v;
            onChanged();
          }),
          _tf('Password', cfg.http3Password.isEmpty ? null : cfg.http3Password,
              (v) {
            cfg.http3Password = v;
            onChanged();
          }, obscure: true),
          _tf('SNI', cfg.trustTlsSni.isEmpty ? null : cfg.trustTlsSni, (v) {
            cfg.trustTlsSni = v;
            onChanged();
          }),
        ];
      case Protocol.trustTunnel:
        return [
          _tf('Password',
              cfg.anytlsPassword.isEmpty ? null : cfg.anytlsPassword, (v) {
            cfg.anytlsPassword = v;
            onChanged();
          }, obscure: true),
          _tf('SNI', cfg.trustTlsSni.isEmpty ? null : cfg.trustTlsSni, (v) {
            cfg.trustTlsSni = v;
            onChanged();
          }),
        ];
      case Protocol.socks:
        return [
          _tf('Username (optional)',
              cfg.socksUser.isEmpty ? null : cfg.socksUser, (v) {
            cfg.socksUser = v;
            onChanged();
          }),
          _tf('Password (optional)',
              cfg.socksPassword.isEmpty ? null : cfg.socksPassword, (v) {
            cfg.socksPassword = v;
            onChanged();
          }, obscure: true),
        ];
      case Protocol.http:
        return [
          _tf('Username (optional)',
              cfg.http3User.isEmpty ? null : cfg.http3User, (v) {
            cfg.http3User = v;
            onChanged();
          }),
          _tf('Password (optional)',
              cfg.http3Password.isEmpty ? null : cfg.http3Password, (v) {
            cfg.http3Password = v;
            onChanged();
          }, obscure: true),
        ];
      case Protocol.ssh:
        return [
          _tf('User', cfg.sshUser.isEmpty ? null : cfg.sshUser, (v) {
            cfg.sshUser = v;
            onChanged();
          }),
          _tf('Password (optional)',
              cfg.sshPassword.isEmpty ? null : cfg.sshPassword, (v) {
            cfg.sshPassword = v;
            onChanged();
          }, obscure: true),
          _tf('Private key (OpenSSH base64, optional)',
              cfg.sshPrivateKey.isEmpty ? null : cfg.sshPrivateKey, (v) {
            cfg.sshPrivateKey = v;
            onChanged();
          }, obscure: true),
        ];
      case Protocol.custom:
      case Protocol.chain:
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'Custom / Chain configs are not supported by the wizard. Use Clipboard → paste the raw URI, or import a config file.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ];
    }
  }

  Widget _dropdown(String label, List<String> items, String current,
      ValueChanged<String> onChg) {
    final fixed = items.contains(current)
        ? current
        : items.isNotEmpty
            ? items.first
            : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String>(
        initialValue: fixed,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final v in items)
            DropdownMenuItem(value: v, child: Text(v.isEmpty ? '— none —' : v))
        ],
        onChanged: (v) {
          if (v != null) onChg(v);
        },
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final ManualServerConfig cfg;
  const _Preview({required this.cfg});

  @override
  Widget build(BuildContext context) {
    final uri = cfg.toUri();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Summary', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _kv('Protocol', cfg.protocol.displayName),
          _kv('Address', '${cfg.address}:${cfg.port}'),
          _kv('Name', cfg.name.isEmpty ? '(auto)' : cfg.name),
          const SizedBox(height: 16),
          Text('Share link', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              uri ??
                  '(no URI representation — config will be stored as raw entry)',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cfg.isValid
                  ? Colors.green.withValues(alpha: 0.15)
                  : Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(cfg.isValid ? Icons.check_circle : Icons.error_outline,
                    color: cfg.isValid ? Colors.green : Colors.orange,
                    size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cfg.isValid
                        ? 'Ready to add'
                        : 'Some required fields are missing',
                    style: TextStyle(
                        color: cfg.isValid
                            ? Colors.green.shade800
                            : Colors.orange.shade800),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            SizedBox(
                width: 90,
                child: Text(k,
                    style: const TextStyle(color: Colors.grey, fontSize: 12))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
//  CLIPBOARD IMPORT — paste share-link(s) and parse them
// ══════════════════════════════════════════════════════════════════════════════
class _ClipboardImport extends StatefulWidget {
  final void Function(List<Server>, String?) onParsed;
  final bool busy;
  const _ClipboardImport({required this.onParsed, required this.busy});

  @override
  State<_ClipboardImport> createState() => _ClipboardImportState();
}

class _ClipboardImportState extends State<_ClipboardImport> {
  final TextEditingController _ctrl = TextEditingController();
  List<Server> _parsed = const [];
  String? _err;

  @override
  void initState() {
    super.initState();
    // Auto-paste from clipboard on open
    _pasteFromClipboard();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.isNotEmpty) {
      _ctrl.text = data.text!;
      _reparse();
    }
  }

  void _reparse() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      setState(() {
        _parsed = const [];
        _err = null;
      });
      widget.onParsed(const [], null);
      return;
    }
    final (servers, err) = _UriParser.parseMulti(text);
    setState(() {
      _parsed = servers;
      _err = err;
    });
    widget.onParsed(servers, err);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Paste URI(s) below',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.content_paste, size: 18),
                tooltip: 'Paste now',
                onPressed: _pasteFromClipboard,
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _ctrl,
            minLines: 4,
            maxLines: 8,
            onChanged: (_) => _reparse(),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'vless://...\nss://...\nvmess://...',
            ),
          ),
          const SizedBox(height: 12),
          if (_parsed.isNotEmpty)
            Text('Found ${_parsed.length} server(s) ✓',
                style: TextStyle(
                    color: Colors.green.shade700, fontWeight: FontWeight.w600))
          else if (_err != null)
            Text(_err!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else
            const Text('Waiting for input...'),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _parsed.length,
              itemBuilder: (_, i) {
                final s = _parsed[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.dns, size: 18),
                  title: Text(s.name),
                  subtitle: Text('${s.protocol} · ${s.address}:${s.port}'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  QR IMPORT — pick a QR image, decode with zxing_lib (pure Dart, works on Windows)
// ══════════════════════════════════════════════════════════════════════════════
class _QrImport extends StatefulWidget {
  final void Function(List<Server>, String?) onParsed;
  final bool busy;
  final void Function(bool) setBusy;
  const _QrImport(
      {required this.onParsed, required this.busy, required this.setBusy});

  @override
  State<_QrImport> createState() => _QrImportState();
}

class _QrImportState extends State<_QrImport> {
  String? _pickedPath;
  String? _status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pick a QR image containing a share-link',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Center(
            child: Icon(Icons.qr_code_2,
                size: 240, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              icon: const Icon(Icons.image),
              label: const Text('Choose image...'),
              onPressed: widget.busy ? null : _pickImage,
            ),
          ),
          if (_pickedPath != null) ...[
            const SizedBox(height: 8),
            Text('Picked: $_pickedPath',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 20),
          const Text(
            'Tip: QR decoding uses a pure-Dart port of ZXing — no native '
            'dependencies required. Works with vmess://, vless://, ss://, '
            'trojan://, ssr:// share-links.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// Picks an image file and attempts QR decode via zxing_lib.
  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;

    setState(() {
      _pickedPath = path;
      _status = 'Decoding…';
    });
    widget.setBusy(true);

    String? decoded;
    String? err;
    try {
      final bytes = await File(path).readAsBytes();
      // zxing_lib can decode directly from an image Uint8List via decodeImageData
      // But the simplest cross-platform path: use the `image` package to load,
      // then hand zxing a luminance source built from pixel data.
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        err = 'Unsupported image format';
      } else {
        // Resize very large images to keep decode fast (~≤1024px on the long edge).
        final longEdge = decodedImage.width > decodedImage.height
            ? decodedImage.width
            : decodedImage.height;
        img.Image source = decodedImage;
        if (longEdge > 1024) {
          source = img.copyResize(decodedImage, width: 1024);
        }
        final luminances = _extractLuminances(source);
        final sourceMatrix = RGBLuminanceSource(
          source.width,
          source.height,
          luminances,
        );
        final bitmap = BinaryBitmap(HybridBinarizer(sourceMatrix));
        final reader = QRCodeReader();
        try {
          final result = reader.decode(bitmap);
          decoded = result.text;
        } on NotFoundException catch (_) {
          // QR not found in this image
          err = 'No QR code found in the image. '
              'Make sure the QR is sharp, well-lit, and occupies most of the frame.';
        }
      }
    } catch (e) {
      err = 'Decode failed: $e';
    } finally {
      widget.setBusy(false);
    }

    if (decoded != null && decoded.isNotEmpty) {
      final trimmed = decoded.trim();
      final server = Server.fromUri(trimmed);
      if (server != null) {
        setState(() => _status = 'Parsed 1 server(s) from QR');
        // Also reflect the link in the clipboard tab for traceability
        await Clipboard.setData(ClipboardData(text: trimmed));
        widget.onParsed([server], null);
      } else {
        setState(
            () => _status = 'QR decoded but the payload is not a recognised '
                'share-link: "$trimmed"');
        widget.onParsed(const [], 'Unrecognised QR payload: $trimmed');
      }
    } else {
      setState(() => _status = err ?? 'No QR code detected');
      widget.onParsed(const [], err);
    }
  }

  /// Builds a flat Uint8List of 8-bit luminance values, row-major, from [src].
  Uint8List _extractLuminances(img.Image src) {
    final w = src.width;
    final h = src.height;
    final out = Uint8List(w * h);
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = src.getPixel(x, y);
        // Standard CCIR 601: 0.299R + 0.587G + 0.114B
        final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
        out[i++] = lum.clamp(0, 255).toInt();
      }
    }
    return out;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  FILE IMPORT — open .txt/.json/.yaml with share-links
// ══════════════════════════════════════════════════════════════════════════════
class _FileImport extends StatefulWidget {
  final void Function(List<Server>, String?) onParsed;
  final bool busy;
  final void Function(bool) setBusy;
  const _FileImport(
      {required this.onParsed, required this.busy, required this.setBusy});

  @override
  State<_FileImport> createState() => _FileImportState();
}

class _FileImportState extends State<_FileImport> {
  String? _path;
  String? _status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Open a config file (.txt, .yaml, .json)',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Center(
            child: Icon(Icons.file_present,
                size: 240, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              icon: const Icon(Icons.file_open),
              label: const Text('Open file...'),
              onPressed: widget.busy ? null : _pickFile,
            ),
          ),
          if (_path != null) ...[
            const SizedBox(height: 8),
            Text('File: $_path',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'yaml', 'yml', 'json', 'conf', 'list'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() {
      _path = path;
      _status = 'Reading...';
    });
    try {
      final content = await File(path).readAsString();
      final (servers, err) = _UriParser.parseMulti(content);
      setState(() {
        _status = 'Parsed ${servers.length} server(s)'
            '${err != null ? ' ($err)' : ''}';
      });
      widget.onParsed(servers, err);
    } catch (e) {
      setState(() => _status = 'Read error: $e');
      widget.onParsed(const [], 'Read error: $e');
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  URI PARSER — supports vless/ss/trojan/vmess/ssr/hysteria2/tuic/juicity/...
// ══════════════════════════════════════════════════════════════════════════════
class _UriParser {
  /// Parses one or more URI share-links (separated by newlines) into [Server]s.
  /// Lines that don't match are silently skipped; if nothing matches an error
  /// is returned in the second tuple element.
  static (List<Server>, String?) parseMulti(String input) {
    final lines = input
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    final servers = <Server>[];
    for (final line in lines) {
      // Decode base64 payload if line is a "scheme://base64" with no @
      final s = _maybeDecodeBase64(line);
      final srv = Server.fromUri(s);
      if (srv != null) servers.add(srv);
    }
    if (servers.isEmpty && lines.isNotEmpty) {
      return (const [], 'No recognized share-links found');
    }
    return (servers, null);
  }

  /// If the line looks like `scheme://base64stuff` (no @ and no query), and the
  /// base64 part decodes to another URI, return the decoded URI — useful for
  /// `vmess://` and base64-encoded `ss://` payload forms.
  static String _maybeDecodeBase64(String line) {
    final m =
        RegExp(r'^([a-z0-9+\-]+)://([A-Za-z0-9+/=_\-]+)$').firstMatch(line);
    if (m == null) return line;
    final payload = m.group(2)!;
    try {
      final norm = payload.replaceAll('-', '+').replaceAll('_', '/');
      final padded = norm + '=' * ((4 - norm.length % 4) % 4);
      final decoded = utf8.decode(base64.decode(padded));
      if (decoded.contains('://')) return decoded;
    } catch (_) {}
    return line;
  }
}
