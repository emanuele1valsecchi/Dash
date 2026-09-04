import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:dash/services/claimed_area_repository.dart';
import 'package:dash/services/user_appearance_service.dart';
import 'package:dash/widgets/map/area_owner_bubbles_layer.dart';

import '../helpers/pump_app.dart';

/// The layer floats a face over each claimed area. Colour says *that* two
/// areas share an owner; the bubble says *who*. Most of what matters is where
/// it anchors and how it degrades in a crowded viewport.
void main() {
  final appearances = UserAppearanceService.instance;

  setUp(appearances.clearForTest);
  tearDown(appearances.clearForTest);

  ClaimedArea area({
    required String id,
    String userId = 'ada',
    required List<LatLng> outer,
    List<List<LatLng>> holes = const [],
  }) =>
      ClaimedArea(
        id: id,
        userId: userId,
        polygons: [AreaPolygonPiece(outer: outer, holes: holes)],
        contributions: const [],
        startLocality: null,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  /// A square with its top edge at [north], `size` degrees on a side.
  List<LatLng> square({
    required double north,
    double west = 9.19,
    double size = 0.01,
  }) =>
      [
        LatLng(north, west),
        LatLng(north, west + size),
        LatLng(north - size, west + size),
        LatLng(north - size, west),
      ];

  Future<void> pumpLayer(
    WidgetTester tester,
    List<ClaimedArea> areas, {
    bool visible = true,
  }) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(45.4642, 9.1900),
            initialZoom: 13,
          ),
          children: [
            AreaOwnerBubblesLayer(areas: areas, visible: visible),
          ],
        ),
        surfaceSize: const Size(800, 800),
      );
      await tester.pump();
    });
  }

  List<Marker> markers(WidgetTester tester) {
    final layers = tester.widgetList<MarkerLayer>(find.byType(MarkerLayer));
    return [for (final l in layers) ...l.markers];
  }

  group('visibility', () {
    testWidgets('draws nothing when the map is zoomed too far out',
        (tester) async {
      // The host screen decides this from the camera zoom; a wall of faces at
      // city scale is noise, not information.
      await pumpLayer(tester, [area(id: 'a', outer: square(north: 45.47))],
          visible: false);

      expect(find.byType(MarkerLayer), findsNothing);
    });

    testWidgets('draws a bubble per area when visible', (tester) async {
      await pumpLayer(tester, [
        area(id: 'a', outer: square(north: 45.47)),
        area(id: 'b', userId: 'bob', outer: square(north: 45.48, west: 9.21)),
      ]);

      expect(markers(tester), hasLength(2));
    });

    testWidgets('an empty map draws no bubbles', (tester) async {
      await pumpLayer(tester, []);

      expect(markers(tester), isEmpty);
    });
  });

  group('anchoring', () {
    testWidgets('sits on the northernmost boundary vertex', (tester) async {
      // Deliberately on the perimeter rather than the centre: a disc parked
      // in the middle hides the very thing being labelled — the claim's
      // shape. A centroid would also fall outside a concave polygon.
      await pumpLayer(tester, [area(id: 'a', outer: square(north: 45.47))]);

      expect(markers(tester).single.point.latitude, closeTo(45.47, 1e-9));
    });

    testWidgets('breaks a flat-top tie by longitude, deterministically',
        (tester) async {
      // Road-snapped claims often have a flat top edge along a straight
      // street. Without a tiebreak the bubble would jump between the two
      // corners depending on ring order, which is not stable across devices.
      await pumpLayer(tester, [
        area(id: 'a', outer: [
          const LatLng(45.47, 9.20),
          const LatLng(45.47, 9.19),
          const LatLng(45.46, 9.19),
        ]),
      ]);

      expect(markers(tester).single.point.longitude, closeTo(9.19, 1e-9));
    });

    testWidgets('labels the largest piece of a split area', (tester) async {
      // A steal can cut an area into a big remainder and a tiny sliver; the
      // label belongs on the part that reads as the territory.
      final split = ClaimedArea(
        id: 'a',
        userId: 'ada',
        polygons: [
          AreaPolygonPiece(outer: square(north: 45.60, size: 0.0005), holes: const []),
          AreaPolygonPiece(outer: square(north: 45.47, size: 0.02), holes: const []),
        ],
        contributions: const [],
        startLocality: null,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      await pumpLayer(tester, [split]);

      expect(markers(tester).single.point.latitude, closeTo(45.47, 1e-9),
          reason: 'the sliver is further north but is not the territory');
    });

    testWidgets('an area with no geometry is skipped, not crashed on',
        (tester) async {
      await pumpLayer(tester, [
        area(id: 'empty', outer: const []),
        area(id: 'real', outer: square(north: 45.47)),
      ]);

      expect(markers(tester), hasLength(1));
    });

    testWidgets('a degenerate two-point ring is skipped too', (tester) async {
      await pumpLayer(tester, [
        area(id: 'line', outer: const [LatLng(45.47, 9.19), LatLng(45.48, 9.20)]),
      ]);

      expect(markers(tester), isEmpty);
    });
  });

  group('a crowded viewport', () {
    testWidgets('caps how many faces are drawn', (tester) async {
      // Degrades to "the biggest claims are labelled" rather than a wall of
      // faces.
      final many = [
        for (var i = 0; i < 60; i++)
          area(
            id: 'a$i',
            userId: 'u$i',
            outer: square(north: 45.40 + i * 0.001, size: 0.0005),
          ),
      ];

      await pumpLayer(tester, many);

      expect(markers(tester), hasLength(AreaOwnerBubblesLayer.maxBubbles));
    });

    testWidgets('keeps the biggest claims when it has to choose',
        (tester) async {
      final areas = [
        for (var i = 0; i < 45; i++)
          area(
            id: 'small$i',
            userId: 'u$i',
            outer: square(north: 45.40 + i * 0.001, size: 0.0002),
          ),
        area(id: 'huge', userId: 'ada', outer: square(north: 45.30, size: 0.05)),
      ];

      await pumpLayer(tester, areas);

      final drawn = markers(tester);
      expect(drawn, hasLength(AreaOwnerBubblesLayer.maxBubbles));
      expect(
        drawn.any((m) => m.point.latitude.toStringAsFixed(2) == '45.30'),
        isTrue,
        reason: 'the largest claim must survive the cap',
      );
    });
  });

  group('appearances', () {
    testWidgets('a bubble renders before its owner is known', (tester) async {
      // Nothing ever blocks on the lookup: the layer draws immediately and
      // repaints when the appearance lands.
      await pumpLayer(tester, [area(id: 'a', outer: square(north: 45.47))]);

      expect(markers(tester), hasLength(1));
    });

    testWidgets('uses the owner\'s initial once it is known', (tester) async {
      appearances.seedForTest([
        const UserAppearance(
          uid: 'ada',
          username: 'ada',
          photoUrl: null,
          colorIndex: 3,
        ),
      ]);

      await pumpLayer(tester, [area(id: 'a', outer: square(north: 45.47))]);
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
    });
  });
}
