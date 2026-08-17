import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/services/daemon_launcher.dart';

void main() {
  group('DaemonLauncher candidate paths', () {
    test('Windows release paths never contain a developer-specific directory',
        () {
      final paths = DaemonLauncher.candidateExecutablePathsFor(
        appExecutable: r'C:\Program Files\MosaicVPN\MosaicVPN.exe',
        isWindows: true,
        environment: const {},
      );

      expect(paths, contains(r'C:\Program Files\MosaicVPN\mosaicd.exe'));
      expect(paths, contains(r'C:\Program Files\MosaicVPN\bin\mosaicd.exe'));
      expect(
          paths.where((path) => path.contains(r'\Users\')).toList(), isEmpty);
    });

    test('portable and DEB daemon paths remain discoverable on Linux', () {
      final paths = DaemonLauncher.candidateExecutablePathsFor(
        appExecutable: '/tmp/MosaicVPN/mosaicvpn',
        isWindows: false,
        environment: const {},
      );

      expect(paths.first, '/tmp/MosaicVPN/mosaicd');
      expect(paths, contains('/tmp/MosaicVPN/bin/mosaicd'));
      expect(paths, contains('/opt/mosaicvpn/mosaicd'));
    });

    test('portable marker resolves data directory beside the executable',
        () async {
      final root = await Directory.systemTemp.createTemp('mosaic-portable-');
      addTearDown(() => root.delete(recursive: true));
      File('${root.path}${Platform.pathSeparator}portable.mode').createSync();

      final data = DaemonLauncher.instance.portableDataDirectory(
        appExecutable: '${root.path}${Platform.pathSeparator}MosaicVPN',
        environment: const {},
      );

      expect(data, '${root.path}${Platform.pathSeparator}data');
    });

    test('an absolute explicit daemon path is preferred', () {
      final paths = DaemonLauncher.candidateExecutablePathsFor(
        appExecutable: '/tmp/MosaicVPN/mosaicvpn',
        isWindows: false,
        environment: const {'MOSAIC_DAEMON_PATH': '/srv/mosaic/mosaicd'},
      );

      expect(paths.first, '/srv/mosaic/mosaicd');
    });

    test('a relative override is ignored', () {
      final paths = DaemonLauncher.candidateExecutablePathsFor(
        appExecutable: '/tmp/MosaicVPN/mosaicvpn',
        isWindows: false,
        environment: const {'MOSAIC_DAEMON_PATH': 'mosaicd'},
      );

      expect(paths.first, '/tmp/MosaicVPN/mosaicd');
      expect(paths, isNot(contains('mosaicd')));
    });
  });
}
