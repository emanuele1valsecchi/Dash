import 'package:dash/widgets/run_results_dialog.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../helpers/pump_app.dart';

/// The popup shown after every saved run.
///
/// Its whole design turns on one split: **stats the client already knows are
/// shown immediately, while XP and area wait on the Cloud Function.** Distance,
/// time, pace, calories and elevation are all computed on the device, so making
/// the user stare at a spinner for them would be gratuitous; area and XP cannot
/// be known until `onRunningSessionCreateClaimedAreas` has run.
///
/// The flag it waits on is `pointsProcessed`, **not** `pointsEarned` — a
/// negligible run can legitimately earn 0 XP, which would be indistinguishable
/// from "not calculated yet".
void main() {
  late FakeFirebaseFirestore db;

  const path = [LatLng(45.65, 9.20), LatLng(45.66, 9.21)];

  setUp(() {
    db = FakeFirebaseFirestore();
  });

  /// Writes the Cloud Function's result onto the session document — the same
  /// shape `awardSessionPoints` produces.
  Future<void> serverFinishes({
    int pointsEarned = 420,
    double totalAreaM2 = 120000,
    double xpFromDistance = 420,
    double xpFromArea = 120,
    double xpFromStolenArea = 0,
    String? territoryCity = 'Milano',
    String? startLocality = 'Seregno',
  }) =>
      db.collection('runningSessions').doc('s1').set({
        'pointsProcessed': true,
        'pointsEarned': pointsEarned,
        'totalAreaM2': totalAreaM2,
        'xpFromDistance': xpFromDistance,
        'xpFromArea': xpFromArea,
        'xpFromStolenArea': xpFromStolenArea,
        'territoryCity': territoryCity,
        'startLocality': startLocality,
      });

  Future<void> openDialog(WidgetTester tester) async {
    await pumpDashWidget(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showRunResultsDialog(
            context: context,
            sessionId: 's1',
            firestore: db,
            path: path,
            distanceMeters: 4200,
            duration: const Duration(minutes: 24, seconds: 30),
            caloriesBurned: 294,
            elevationDifferenceMeters: 32,
          ),
          child: const Text('open'),
        ),
      ),
      surfaceSize: const Size(500, 1200),
    );

    await tester.tap(find.text('open'));
    // Not `pumpAndSettle`: the dialog holds a locked map whose tile requests
    // never go idle, so settling would time out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('what is known immediately', () {
    // All computed on the device, so none of these should wait on the server.
    testWidgets('shows the client-side stats without waiting', (tester) async {
      await openDialog(tester);

      expect(find.text('Run results'), findsOneWidget);
      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('Calories'), findsOneWidget);
      expect(find.text('Elevation'), findsOneWidget);
    });

    testWidgets('formats the duration as mm:ss under an hour',
        (tester) async {
      await openDialog(tester);

      expect(find.text('24:30'), findsOneWidget);
    });

    testWidgets('offers Done straight away', (tester) async {
      // The user must never be trapped waiting on the server to leave.
      await openDialog(tester);

      expect(find.text('Done'), findsOneWidget);
    });
  });

  group('while the server is still calculating', () {
    testWidgets('says so rather than showing a wrong number', (tester) async {
      await openDialog(tester);

      expect(find.text('Calculating your score…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('area is a placeholder, not zero', (tester) async {
      // Showing "0 km2" before the claim function has run would read as "you
      // claimed nothing", which is a different and wrong statement.
      await openDialog(tester);

      expect(find.text('…'), findsOneWidget);
    });

    testWidgets('an unprocessed document does not end the wait',
        (tester) async {
      // The session doc exists from the moment the client writes it; only
      // `pointsProcessed` means the server has finished.
      await db.collection('runningSessions').doc('s1').set({
        'pointsEarned': 0,
        'distanceMeters': 4200,
      });

      await openDialog(tester);

      expect(find.text('Calculating your score…'), findsOneWidget);
    });
  });

  group('when the score arrives', () {
    testWidgets('replaces the spinner with the XP', (tester) async {
      await openDialog(tester);
      expect(find.text('Calculating your score…'), findsOneWidget);

      await serverFinishes(pointsEarned: 420);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Calculating your score…'), findsNothing);
      expect(find.text('420 XP'), findsOneWidget);
    });

    testWidgets('fills in the claimed area', (tester) async {
      await openDialog(tester);

      await serverFinishes(totalAreaM2: 120000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('…'), findsNothing);
      // 'Area' twice on purpose: the stat tile and the XP breakdown row.
      expect(find.text('Area'), findsWidgets);
    });

    testWidgets('names the locality, not the metro territory',
        (tester) async {
      // `displayLocalityForSession`: showing "Milano" for a run in Seregno
      // reads as though the app lost track of where you were.
      await openDialog(tester);

      await serverFinishes(startLocality: 'Seregno', territoryCity: 'Milano');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Seregno'), findsOneWidget);
    });

    testWidgets('falls back to the territory when there is no locality',
        (tester) async {
      await openDialog(tester);

      await serverFinishes(startLocality: null, territoryCity: 'Milano');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Milano'), findsOneWidget);
    });

    testWidgets('zero XP is shown as a real result, not as still-waiting',
        (tester) async {
      // The exact case `pointsProcessed` exists for: a negligible run rounds
      // to 0 XP, and that is an answer.
      await openDialog(tester);

      await serverFinishes(
        pointsEarned: 0,
        xpFromDistance: 0,
        xpFromArea: 0,
        totalAreaM2: 0,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Calculating your score…'), findsNothing);
      expect(find.text('0 XP'), findsOneWidget);
    });

    testWidgets('shows the XP breakdown', (tester) async {
      // Renamed from "XP BREAKDOWN (DEBUG)" — it is a real feature, not a
      // developer aid.
      await openDialog(tester);

      await serverFinishes();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('XP BREAKDOWN'), findsOneWidget);
      expect(find.textContaining('DEBUG'), findsNothing);
      expect(find.text('Straight line (distance)'), findsOneWidget);
      expect(find.text('Area'), findsWidgets);
      expect(find.text('Stolen area'), findsOneWidget);
    });

    testWidgets('a score arriving before the dialog opens is picked up',
        (tester) async {
      // The Cloud Function can win the race on a fast connection; the first
      // snapshot then already carries the result.
      await serverFinishes(pointsEarned: 999);

      await openDialog(tester);

      expect(find.text('999 XP'), findsOneWidget);
      expect(find.text('Calculating your score…'), findsNothing);
    });
  });

  group('when the server never answers', () {
    testWidgets('gives up after the timeout instead of spinning forever',
        (tester) async {
      // Bounded on purpose: this is a one-time async computation, not a feed.
      // A permanent spinner would leave the user unsure whether to wait.
      await openDialog(tester);
      expect(find.text('Calculating your score…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 21));

      expect(find.text('Calculating your score…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Done still works after a timeout', (tester) async {
      await openDialog(tester);
      await tester.pump(const Duration(seconds: 21));

      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Run results'), findsNothing);
    });
  });

  group('dismissal', () {
    testWidgets('Done closes the dialog', (tester) async {
      await openDialog(tester);

      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Run results'), findsNothing);
    });

    testWidgets('cancels its listener and timer on close', (tester) async {
      // Both are cancelled in `dispose`; a leaked timer would fail the test
      // with "A Timer is still pending after the widget tree was disposed".
      await openDialog(tester);

      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
    });
  });

  group('degenerate runs', () {
    testWidgets('a run with no path still renders', (tester) async {
      await pumpDashWidget(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showRunResultsDialog(
              context: context,
              sessionId: 's1',
              firestore: db,
              path: const [],
              distanceMeters: 0,
              duration: Duration.zero,
              caloriesBurned: 0,
              elevationDifferenceMeters: 0,
            ),
            child: const Text('open'),
          ),
        ),
        surfaceSize: const Size(500, 1200),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Run results'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero-duration run shows no rate rather than dividing by 0',
        (tester) async {
      await pumpDashWidget(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showRunResultsDialog(
              context: context,
              sessionId: 's1',
              firestore: db,
              path: path,
              distanceMeters: 100,
              duration: Duration.zero,
              caloriesBurned: 7,
              elevationDifferenceMeters: 0,
            ),
            child: const Text('open'),
          ),
        ),
        surfaceSize: const Size(500, 1200),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('--'), findsOneWidget);
      expect(find.textContaining('Infinity'), findsNothing);
      expect(find.textContaining('NaN'), findsNothing);
    });
  });
}
