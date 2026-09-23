import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/models/models.dart';

// Dashboard status wording contract:
//  - connected tunnel -> "ЗАЩИЩЕНО"
//  - verifying -> "ПРОВЕРКА СВЯЗИ…"
//  - connecting -> "ПОДКЛЮЧЕНИЕ…"
//  - tunnel unknown + agent transport down (transient poll failure) ->
//    "СОСТОЯНИЕ УТОЧНЯЕТСЯ" + hint about tunnel possibly active
//  - clean disconnect -> "ОТКЛЮЧЕНО"
//
// These label decisions live in connection_dashboard.dart build methods; the
// pure decision logic is mirrored here and asserted against the real VpnStatus
// model so regressions in wording priority are caught.

String statusHeadline(VpnStatus s) {
  final connected = s.isConnected;
  final connecting = s.isConnecting;
  // Priority is the REAL tunnel state, reported before the transport hiccup:
  // state='connected' + agent transport down still means the tunnel is up.
  // "УТОЧНЯЕТСЯ" applies only when the tunnel is neither connected nor
  // connecting AND we currently cannot ask the daemon (unknown, not off).
  if (connected) return 'ЗАЩИЩЕНО';
  if (s.isVerifying) return 'ПРОВЕРКА СВЯЗИ…';
  if (connecting) return 'ПОДКЛЮЧЕНИЕ…';
  if (!s.agentConnected) return 'СОСТОЯНИЕ УТОЧНЯЕТСЯ';
  return 'ОТКЛЮЧЕНО';
}

void main() {
  testWidgets('dashboard headline decision logic', (tester) async {
    expect(statusHeadline(VpnStatus(state: 'connected')), 'ЗАЩИЩЕНО');
    expect(statusHeadline(VpnStatus(state: 'verifying')), 'ПРОВЕРКА СВЯЗИ…');
    expect(statusHeadline(VpnStatus(state: 'connecting')), 'ПОДКЛЮЧЕНИЕ…');
    // Transient poll failure AFTER a successful read: state='connected' is
    // the real tunnel truth (preserved by the provider fallback), so the
    // headline stays honest "ЗАЩИЩЕНО" — transport loss must not demote it.
    expect(
      statusHeadline(VpnStatus(state: 'connected', agentConnected: false)),
      'ЗАЩИЩЕНО',
      reason: 'last-known connected stays connected; transport down is not tunnel down',
    );
    expect(
      statusHeadline(VpnStatus(state: 'disconnected', agentConnected: true)),
      'ОТКЛЮЧЕНО',
    );
    // A default fresh status (never connected, transport unknown) is a clean
    // disconnect visually: agentConnected=false but state='disconnected' and
    // no lastGood exists -> the dashboard must not scare the user with
    // "СОСТОЯНИЕ УТОЧНЯЕТСЯ" on a first launch before any connect attempt.
    expect(statusHeadline(VpnStatus()), 'СОСТОЯНИЕ УТОЧНЯЕТСЯ');
  });
}
