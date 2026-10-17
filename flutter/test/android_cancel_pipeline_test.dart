import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/android_hosted_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:mosaic_vpn/core/services/android_mosaic_account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const vpnChannel = MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(secure, (call) async => null);
  });
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(vpnChannel, null);
    messenger.setMockMethodCallHandler(secure, null);
  });

  for (final delayedStage in ['prepare', 'validateConfig']) {
    test('disconnect during $delayedStage prevents any late native start', () async {
      final entered = Completer<void>();
      final release = Completer<bool>();
      var starts = 0;
      var stops = 0;
      messenger.setMockMethodCallHandler(vpnChannel, (call) async {
        if (call.method == delayedStage) {
          if (!entered.isCompleted) entered.complete();
          return release.future;
        }
        if (call.method == 'prepare' || call.method == 'validateConfig') return true;
        if (call.method == 'status') return {'state': 'disconnected'};
        if (call.method == 'stop') {
          stops++;
          return {'state': 'disconnected'};
        }
        if (call.method == 'start') {
          starts++;
          return {'state': 'connected'};
        }
        return null;
      });
      final api = AndroidHostedDaemonApi.withAccount(AndroidMosaicAccountService.instance);
      await api.addServer(Server(
        id: 'cancel-fixture', name: 'Cancellation fixture', protocol: Protocol.vless,
        importUri: 'vless://e619d9bd-2950-4098-bcf2-e943fd6b5647@198.51.100.22:443?encryption=none#Fixture',
      ));
      final connect = api.connect('cancel-fixture');
      await entered.future.timeout(const Duration(seconds: 5));
      await api.disconnect();
      // Attach the error listener before releasing asynchronous native work.
      final cancelled = expectLater(connect, throwsA(isA<StateError>().having(
        (e) => e.message, 'cancellation', contains('Connection cancelled'),
      )));
      release.complete(true);
      await cancelled;
      expect(stops, 1);
      expect(starts, 0, reason: 'stop must revoke permission to start a new native tunnel');
      expect(api.activeRoute, isNull);
    });
  }
}
