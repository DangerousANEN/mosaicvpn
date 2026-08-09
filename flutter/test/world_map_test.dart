import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/shared/widgets/world_map_widget.dart';

void main() {
  testWidgets('renders inside the given constraints', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: WorldMapWidget(pins: [], bearing: 'N 45° W'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(WorldMapWidget), findsOneWidget);
    expect(find.text('N 45° W'), findsOneWidget);
  });

  testWidgets('does not hand pan and zoom to the user', (tester) async {
    // The map camera is driven by app state (idle frames the world, selecting a
    // server frames client and server together). An InteractiveViewer let the
    // user drag the world out of view with only a reset button to recover, so
    // its absence is the behaviour under test, not an accident.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: WorldMapWidget(pins: [], bearing: 'N 0° E'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('letterboxes rather than stretching in a non-2:1 box',
      (tester) async {
    // The projection is linear in lon/lat, so stretching the canvas would put
    // pins in the wrong place. In a 1000x900 box the map must size itself to
    // 1000x500 and leave the leftover height empty.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 900,
            child: WorldMapWidget(pins: [], bearing: 'N 0° E'),
          ),
        ),
      ),
    );
    await tester.pump();

    final svg = tester.widgetList<SvgPicture>(find.byType(SvgPicture)).first;
    final size = tester.getSize(find.byWidget(svg));

    expect(size.width / size.height, closeTo(WorldMapWidget.aspect, 0.01),
        reason: 'rendered map was ${size.width}x${size.height}');
  });
}
