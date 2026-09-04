import 'package:dash/services/claimed_area_repository.dart';
import 'package:dash/widgets/map/area_details_sheet.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mockito/mockito.dart';

import '../helpers/pump_app.dart';
import '../mocks.mocks.dart';

/// The sheet that opens when you tap someone's territory on the Explore map.
///
/// It is the only place on the map where a stranger's identity is spelled out,
/// and the only route into their profile — so the owner's name and the
/// contributions list are the parts that matter.
///
/// **The Duke badge is not asserted as present anywhere below.** It renders
/// only when *both* the badge-progress read and the badge image URL resolve,
/// and the image goes through Firebase Storage, which is unreachable here.
/// Per the widget's own design an unresolved badge renders nothing — the same
/// as "not a Duke" — so a test can only ever see it absent. That is a real
/// limitation of this layer, not a gap worth papering over.
void main() {
  late MockProfileService profiles;
  late FakeFirebaseFirestore db;

  AreaContribution contribution({
    String sessionId = 'run-1',
    int durationMs = 1440000,
    double? avgPaceMinPerKm = 5.7,
    DateTime? on,
  }) =>
      AreaContribution(
        sessionId: sessionId,
        durationMs: durationMs,
        avgPaceMinPerKm: avgPaceMinPerKm,
        conquestDate: on ?? DateTime(2026, 3, 14),
      );

  /// A roughly 1 km square, so the area figure is a real number.
  ClaimedArea area({
    String id = 'a1',
    String userId = 'runner-1',
    List<AreaContribution>? contributions,
    List<AreaPolygonPiece>? polygons,
  }) =>
      ClaimedArea(
        id: id,
        userId: userId,
        polygons: polygons ??
            const [
              AreaPolygonPiece(
                outer: [
                  LatLng(45.650, 9.200),
                  LatLng(45.659, 9.200),
                  LatLng(45.659, 9.213),
                  LatLng(45.650, 9.213),
                ],
                holes: [],
              ),
            ],
        contributions: contributions ?? [contribution()],
        startLocality: 'Seregno',
        createdAt: DateTime(2026, 3, 14),
        updatedAt: DateTime(2026, 3, 14),
      );

  setUp(() {
    profiles = MockProfileService();
    db = FakeFirebaseFirestore();
    when(profiles.fetchUsername(any)).thenAnswer((_) async => 'speedy');
  });

  Future<void> pumpSheet(WidgetTester tester, ClaimedArea subject) =>
      pumpDashWidget(
        tester,
        AreaDetailsSheet(
          area: subject,
          profileService: profiles,
          firestore: db,
        ),
        surfaceSize: const Size(500, 1000),
      );

  group('the owner', () {
    testWidgets('is looked up and named', (tester) async {
      await pumpSheet(tester, area(userId: 'runner-1'));
      await tester.pump();

      verify(profiles.fetchUsername('runner-1')).called(1);
      expect(find.text('speedy'), findsOneWidget);
    });

    testWidgets('renders before the name resolves', (tester) async {
      // The lookup is a network round trip; the sheet must draw immediately
      // rather than waiting on it.
      await pumpSheet(tester, area());

      expect(tester.takeException(), isNull);
      expect(find.text('Total area'), findsOneWidget);
    });

    testWidgets('an unresolvable name does not break the sheet',
        (tester) async {
      // Account deletion removes the profile, but the territory survives — so
      // a null username is a normal state, not a failure.
      when(profiles.fetchUsername(any)).thenAnswer((_) async => null);

      await pumpSheet(tester, area());
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Total area'), findsOneWidget);
    });

    testWidgets('a failed lookup does not break the sheet', (tester) async {
      // A rejected Future, not a synchronous throw: the real service returns
      // a Future, and `thenThrow` would blow up in the field initializer
      // rather than in the FutureBuilder where the sheet handles it.
      when(profiles.fetchUsername(any))
          .thenAnswer((_) async => throw Exception('denied'));

      await pumpSheet(tester, area());
      await tester.pump();

      expect(find.text('Total area'), findsOneWidget);
    });
  });

  group('the area figure', () {
    testWidgets('is shown', (tester) async {
      await pumpSheet(tester, area());
      await tester.pump();

      expect(find.text('Total area'), findsOneWidget);
    });

    testWidgets('sums a multi-piece area rather than showing one piece',
        (tester) async {
      // A steal can split someone's territory into disconnected pieces;
      // reporting only the first would understate what they hold.
      final oneSquare = area();
      final twoSquares = area(
        polygons: const [
          AreaPolygonPiece(
            outer: [
              LatLng(45.650, 9.200),
              LatLng(45.659, 9.200),
              LatLng(45.659, 9.213),
              LatLng(45.650, 9.213),
            ],
            holes: [],
          ),
          AreaPolygonPiece(
            outer: [
              LatLng(45.700, 9.200),
              LatLng(45.709, 9.200),
              LatLng(45.709, 9.213),
              LatLng(45.700, 9.213),
            ],
            holes: [],
          ),
        ],
      );

      expect(twoSquares.totalAreaM2, greaterThan(oneSquare.totalAreaM2 * 1.9));
    });

    testWidgets('an empty polygon renders as zero rather than throwing',
        (tester) async {
      await pumpSheet(tester, area(polygons: const []));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('the contributions list', () {
    testWidgets('counts a single run in the singular', (tester) async {
      await pumpSheet(tester, area(contributions: [contribution()]));
      await tester.pump();

      expect(find.text('Built from 1 run'), findsOneWidget);
    });

    testWidgets('counts several runs in the plural', (tester) async {
      await pumpSheet(
        tester,
        area(contributions: [
          contribution(sessionId: 'run-1'),
          contribution(sessionId: 'run-2'),
          contribution(sessionId: 'run-3'),
        ]),
      );
      await tester.pump();

      expect(find.text('Built from 3 runs'), findsOneWidget);
    });

    testWidgets('lists every contributing run', (tester) async {
      // Merges concatenate contribution lists and a split duplicates them
      // onto both pieces, so this list is how the ground is accounted for.
      await pumpSheet(
        tester,
        area(contributions: [
          contribution(sessionId: 'run-1', on: DateTime(2026, 3, 14)),
          contribution(sessionId: 'run-2', on: DateTime(2026, 4, 2)),
        ]),
      );
      await tester.pump();

      // 'Mar 14' twice: the area's own conquest date in the header, and the
      // first contribution's row. 'Apr 2' belongs only to the second run, so
      // finding it proves the whole list is rendered rather than just the
      // first entry.
      expect(find.textContaining('Mar 14, 2026'), findsWidgets);
      expect(find.textContaining('Apr 2, 2026'), findsOneWidget);
    });

    testWidgets('an area with no contributions still renders', (tester) async {
      await pumpSheet(tester, area(contributions: []));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Total area'), findsOneWidget);
    });

    testWidgets('a contribution with no pace recorded still renders',
        (tester) async {
      // `avgPaceMinPerKm` is nullable — an older claim may not carry it.
      await pumpSheet(
        tester,
        area(contributions: [contribution(avgPaceMinPerKm: null)]),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('the Duke badge', () {
    testWidgets('reads the badge state from badge_progress', (tester) async {
      // `badge_progress` is signed-in-readable precisely so achievements can
      // be shown beside someone else's name.
      await db
          .collection('profiles')
          .doc('runner-1')
          .collection('badge_progress')
          .doc('duke')
          .set({'unlocked': true, 'progress': 1.0});

      await pumpSheet(tester, area(userId: 'runner-1'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a non-Duke owner renders no badge and no gap',
        (tester) async {
      // Absence must be indistinguishable from a pending or failed lookup —
      // an empty box beside a name reads as a bug.
      await pumpSheet(tester, area());
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('speedy'), findsOneWidget);
    });
  });

  group('showAreaDetailsSheet', () {
    Future<void> pumpOpener(
      WidgetTester tester,
      List<ClaimedArea> areas,
      String areaId,
    ) async {
      await pumpDashWidget(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAreaDetailsSheet(
              context,
              areas,
              areaId,
              profileService: profiles,
              firestore: db,
            ),
            child: const Text('open'),
          ),
        ),
        surfaceSize: const Size(500, 1000),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('opens the sheet for a matching id', (tester) async {
      await pumpOpener(tester, [area(id: 'a1')], 'a1');

      expect(find.byType(AreaDetailsSheet), findsOneWidget);
    });

    testWidgets('picks the right area out of several', (tester) async {
      await pumpOpener(
        tester,
        [
          area(id: 'a1', userId: 'runner-1'),
          area(id: 'a2', userId: 'someone-else'),
        ],
        'a2',
      );

      verify(profiles.fetchUsername('someone-else')).called(1);
    });

    testWidgets('opens nothing for an id that is not in the list',
        (tester) async {
      // Should never happen — ids come from a hit test against these same
      // polygons — but a stale id must be a no-op, not a crash.
      await pumpOpener(tester, [area(id: 'a1')], 'gone');

      expect(find.byType(AreaDetailsSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens nothing for an empty area list', (tester) async {
      await pumpOpener(tester, [], 'a1');

      expect(find.byType(AreaDetailsSheet), findsNothing);
    });
  });
}
