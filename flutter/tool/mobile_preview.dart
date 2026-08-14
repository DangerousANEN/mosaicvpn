import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/theme/atlas_theme.dart';
import 'package:mosaic_vpn/features/account/account_screen.dart';
import 'package:mosaic_vpn/features/more/more_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mock = MockDaemonApi();
  await mock.redeemLinkCode(MockDaemonApi.mockValidLinkCode);
  runApp(ProviderScope(
    overrides: [
      daemonApiProvider.overrideWithValue(mock),
      vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AtlasTheme.themeData,
      darkTheme: AtlasTheme.darkThemeData,
      home: const _PreviewShell(),
    ),
  ));
}

class _PreviewShell extends StatefulWidget {
  const _PreviewShell();
  @override State<_PreviewShell> createState() => _PreviewShellState();
}

class _PreviewShellState extends State<_PreviewShell> {
  int index = 0;
  @override Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: index, children: const [AccountScreen(), MoreScreen()]),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) => setState(() => index = value),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Аккаунт'),
        NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Ещё'),
      ],
    ),
  );
}
