import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/api/android_hosted_daemon_api.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ru.mosaicvpn.mosaic_vpn/android_vpn');
  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('Android status preserves native network epoch across handover', () async {
    var fingerprint = 'session-a:1';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return {'state': 'disconnected', 'network_fingerprint': fingerprint};
      }
      return null;
    });
    final api = AndroidHostedDaemonApi.instance;
    expect((await api.getStatus()).networkFingerprint, 'session-a:1');
    fingerprint = 'session-a:2';
    expect((await api.getStatus()).networkFingerprint, 'session-a:2');
  });
}
