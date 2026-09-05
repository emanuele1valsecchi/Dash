import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late RunSessionRepository repo;

  http.Client geocoderReturning(String body, {int status = 200}) =>
      MockClient((_) async => http.Response(body, status));

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'runner-1'),
    );
    repo = RunSessionRepository.withDependencies(
      db: db,
      auth: auth,
      httpClient: geocoderReturning('{"address":{"town":"Seregno"}}'),
    );
  });

  /// A short straight run. Points are ~11 m apart, comfortably above the 5 m
  /// simplification tolerance, so nothing is dropped unless a test wants it.
  const path = [
    LatLng(45.6500, 9.2000),
    LatLng(45.6501, 9.2000),
    LatLng(45.6502, 9.2000),
  ];

  Future<String> save({
    String name = 'Morning run',
    List<LatLng> runPath = path,
    List<List<LatLng>> loops = const [],
    int? avgHeartRateBpm,
    int? maxHeartRateBpm,
  }) =>
      repo.saveSession(
        name: name,
        distanceMeters: 4200,
        duration: const Duration(minutes: 24),
        avgPaceMinPerKm: 5.7,
        elevationDifferenceMeters: 32,
        loopsCompleted: loops.length,
        path: runPath,
        closedLoops: loops,
        avgHeartRateBpm: avgHeartRateBpm,
        maxHeartRateBpm: maxHeartRateBpm,
      );

  Future<Map<String, dynamic>> session(String id) async =>
      (await db.collection('runningSessions').doc(id).get()).data()!;

  /// The private metrics slot for [id], addressed by the **owner's uid** —
  /// which is what stops one user occupying another's. A fixed document ID
  /// used to let any signed-in user write into anyone's session and lock the
  /// real owner out of their own heart rate; see `firestore.rules` and
  /// `test/rules/running_sessions.test.js`.
  Future<DocumentSnapshot<Map<String, dynamic>>> privateDoc(
    String id, {
    String uid = 'runner-1',
  }) =>
      db
          .collection('runningSessions')
          .doc(id)
          .collection('private')
          .doc(uid)
          .get();

  group('saveSession', () {
    test('writes the run under the signed-in user', () async {
      expect((await session(await save()))['userId'], 'runner-1');
    });

    test('returns the new document id', () async {
      final id = await save();

      expect(id, isNotEmpty);
      expect((await db.collection('runningSessions').doc(id).get()).exists,
          isTrue);
    });

    test('falls back to a placeholder for an empty name', () async {
      expect((await session(await save(name: '  ')))['name'], 'Untitled run');
    });

    group('server-owned fields', () {
      test('pointsEarned is written as zero, never a client guess', () async {
        // firestore.rules requires `pointsEarned == 0` on create; XP is the
        // Cloud Function's to decide.
        expect((await session(await save()))['pointsEarned'], 0);
      });

      test('no server-only scoring fields are written by the client',
          () async {
        // `noServerOnlyFields` in firestore.rules rejects the create outright
        // if any of these are present.
        final data = await session(await save());

        for (final field in const [
          'totalAreaM2',
          'stolenAreaM2',
          'xpFromDistance',
          'xpFromArea',
          'xpFromStolenArea',
          'territoryCity',
          'territoryBroad',
          'pointsProcessed',
        ]) {
          expect(data.containsKey(field), isFalse, reason: '$field must be absent');
        }
      });
    });

    group('privacy boundary', () {
      // runningSessions docs are readable by every signed-in user, and
      // Firestore cannot hide individual fields of a readable document. So
      // these two assertions are the privacy boundary, not a style choice.
      test('heart rate never lands on the public session document', () async {
        final data = await session(
          await save(avgHeartRateBpm: 152, maxHeartRateBpm: 178),
        );

        expect(data.containsKey('avgHeartRateBpm'), isFalse);
        expect(data.containsKey('maxHeartRateBpm'), isFalse);
      });

      test('heart rate goes to the owner-only private subcollection',
          () async {
        final id = await save(avgHeartRateBpm: 152, maxHeartRateBpm: 178);

        final metrics = await privateDoc(id);
        expect(metrics.exists, isTrue);
        expect(metrics.data()!['avgHeartRateBpm'], 152);
        expect(metrics.data()!['maxHeartRateBpm'], 178);
      });

      test('the metrics document is addressed by the owner uid', () async {
        // The security property: a client can only ever name its own slot, so
        // no user's write can collide with another's.
        final id = await save(avgHeartRateBpm: 152);

        expect((await privateDoc(id, uid: 'runner-1')).exists, isTrue);
        expect((await privateDoc(id, uid: 'someone-else')).exists, isFalse);
      });

      test('the private doc denormalizes userId so its rule needs no get()',
          () async {
        // A get() inside a security rule is a billed read on every evaluation.
        final id = await save(avgHeartRateBpm: 152);

        expect((await privateDoc(id)).data()!['userId'], 'runner-1');
      });

      test('a phone-only run writes no private document at all', () async {
        // Absence reads the same as "no watch" - an empty doc would be a
        // write for nothing.
        expect((await privateDoc(await save())).exists, isFalse);
      });

      test('calories are never stored, in either document', () async {
        // Energy is distance * 70, derived on read. A stored copy could only
        // drift, and it is a body metric on a world-readable document.
        final id = await save(avgHeartRateBpm: 152);

        expect((await session(id)).containsKey('caloriesBurned'), isFalse);
        expect((await privateDoc(id)).data()!.containsKey('caloriesBurned'),
            isFalse);
      });
    });

    group('path storage', () {
      test('stores the path as GeoPoints', () async {
        final stored =
            ((await session(await save()))['path'] as List).cast<GeoPoint>();

        expect(stored.first.latitude, closeTo(45.6500, 1e-9));
      });

      test('simplifies a dense path before storing it', () async {
        // The live stream records a breadcrumb every 2 m - tuned for a smooth
        // dot, not for archival. A long run's raw path grows toward the 1 MiB
        // document ceiling.
        final dense = [
          for (var i = 0; i < 400; i++) LatLng(45.65 + i * 0.00002, 9.20),
        ];

        final stored =
            ((await session(await save(runPath: dense)))['path'] as List);

        expect(stored.length, lessThan(dense.length));
      });

      test('simplification always keeps the real start point', () async {
        // path[0] is what server-side territory resolution keys off, so it
        // must survive untouched.
        final dense = [
          for (var i = 0; i < 400; i++) LatLng(45.65 + i * 0.00002, 9.20),
        ];

        final stored =
            ((await session(await save(runPath: dense)))['path'] as List)
                .cast<GeoPoint>();

        expect(stored.first.latitude, closeTo(dense.first.latitude, 1e-9));
        expect(stored.last.latitude, closeTo(dense.last.latitude, 1e-9));
      });

      test('closed loops are stored raw, wrapped in a points map', () async {
        // Firestore rejects directly nested arrays, hence the wrapper. Loops
        // are NOT simplified: their boundaries are what the Cloud Function
        // computes claimed area and XP from.
        final loop = [
          const LatLng(45.65, 9.20),
          const LatLng(45.66, 9.20),
          const LatLng(45.66, 9.21),
          const LatLng(45.65, 9.20),
        ];

        final data = await session(await save(loops: [loop]));
        final loops = (data['closedLoops'] as List).cast<Map<String, dynamic>>();

        expect(loops, hasLength(1));
        expect((loops.first['points'] as List), hasLength(loop.length));
      });

      test('a run with no loops stores an empty list, not null', () async {
        expect((await session(await save()))['closedLoops'], isEmpty);
      });
    });

    group('startLocality', () {
      test('is reverse-geocoded from the run start', () async {
        expect((await session(await save()))['startLocality'], 'Seregno');
      });

      test('a geocode failure does not fail the save', () async {
        repo = RunSessionRepository.withDependencies(
          db: db,
          auth: auth,
          httpClient: geocoderReturning('boom', status: 500),
        );

        final data = await session(await save());
        expect(data['startLocality'], isNull);
        expect(data['distanceMeters'], 4200);
      });

      test('is skipped for a run with no recorded path', () async {
        expect(
          (await session(await save(runPath: const [])))['startLocality'],
          isNull,
        );
      });
    });
  });

  group('fetchUserSessions', () {
    test('returns the signed-in user\'s own runs by default', () async {
      await save(name: 'Mine');
      await db.collection('runningSessions').add({
        'userId': 'someone-else',
        'name': 'Theirs',
        'distanceMeters': 1000,
        'path': <GeoPoint>[],
        'createdAt': Timestamp.now(),
      });

      final runs = await repo.fetchUserSessions();

      expect(runs.map((r) => r.name), ['Mine']);
    });

    test('can fetch another user\'s runs when asked', () async {
      // The collection is readable by any signed-in user, deliberately - a
      // profile shows other people's runs.
      await db.collection('runningSessions').add({
        'userId': 'someone-else',
        'name': 'Theirs',
        'distanceMeters': 1000,
        'path': <GeoPoint>[],
        'createdAt': Timestamp.now(),
      });

      final runs = await repo.fetchUserSessions(userId: 'someone-else');

      expect(runs.map((r) => r.name), ['Theirs']);
    });
  });

  group('fetchSessionById', () {
    test('round-trips a saved run', () async {
      final id = await save(name: 'Morning run');

      final run = await repo.fetchSessionById(id);

      expect(run, isNotNull);
      expect(run!.name, 'Morning run');
      expect(run.distanceMeters, 4200);
    });

    test('returns null for an id that does not exist', () async {
      expect(await repo.fetchSessionById('nope'), isNull);
    });
  });

  group('fetchPrivateMetrics', () {
    test('reads back the heart rate the run was saved with', () async {
      final id = await save(avgHeartRateBpm: 142, maxHeartRateBpm: 175);

      final metrics = await repo.fetchPrivateMetrics(id);

      expect(metrics, isNotNull);
      expect(metrics!.avgHeartRateBpm, 142);
      expect(metrics.maxHeartRateBpm, 175);
    });

    test('a phone-only run has none, and that is not an error', () async {
      // No watch, so no private document was written at all. Absence has to
      // read as "no heart rate", not as a failure — most runs are like this.
      final id = await save();

      expect(await repo.fetchPrivateMetrics(id), isNull);
    });

    test('a session that does not exist reads as none', () async {
      expect(await repo.fetchPrivateMetrics('no-such-session'), isNull);
    });

    test('a signed-out caller gets none without touching the database',
        () async {
      // The document is addressed by the caller's own uid, so there is no
      // path to read when there is no caller.
      final id = await save(avgHeartRateBpm: 142);
      final signedOut = RunSessionRepository.withDependencies(
        db: db,
        auth: MockFirebaseAuth(),
        httpClient: geocoderReturning('{}'),
      );

      expect(await signedOut.fetchPrivateMetrics(id), isNull);
    });

    test('it is addressed by the owner uid, not a fixed name', () async {
      // A fixed document id would let any signed-in user occupy anyone's
      // slot and lock the real owner out of their own heart rate. The uid
      // path makes that unreachable — see TEST_NOTES 5.
      final id = await save(avgHeartRateBpm: 142);

      final doc = await db
          .collection('runningSessions')
          .doc(id)
          .collection('private')
          .doc('runner-1')
          .get();

      expect(doc.exists, isTrue);
    });

    test('another user reads none from the same session', () async {
      final id = await save(avgHeartRateBpm: 142);
      final other = RunSessionRepository.withDependencies(
        db: db,
        auth: MockFirebaseAuth(
            signedIn: true, mockUser: MockUser(uid: 'someone-else')),
        httpClient: geocoderReturning('{}'),
      );

      expect(await other.fetchPrivateMetrics(id), isNull);
    });
  });

  group('RunPrivateMetrics.fromDoc', () {
    Future<RunPrivateMetrics> parse(Map<String, dynamic> data) async {
      await db.collection('t').doc('d').set(data);
      return RunPrivateMetrics.fromDoc(
          await db.collection('t').doc('d').get());
    }

    test('reads both rates', () async {
      final m = await parse({'avgHeartRateBpm': 130, 'maxHeartRateBpm': 168});

      expect(m.avgHeartRateBpm, 130);
      expect(m.maxHeartRateBpm, 168);
    });

    test('a document with neither reads as null, not zero', () async {
      // Zero is a heart rate. Absent is not, and a chart drawing 0 bpm for a
      // run with no watch would be a measurement the app never took.
      final m = await parse({'userId': 'runner-1'});

      expect(m.avgHeartRateBpm, isNull);
      expect(m.maxHeartRateBpm, isNull);
    });

    test('a stored double is read as a whole beat count', () async {
      // Firestore hands numbers back as `num`; a watch that wrote 142.0
      // must not come back as a value no bpm display can format.
      final m = await parse({'avgHeartRateBpm': 142.0});

      expect(m.avgHeartRateBpm, 142);
    });
  });

  group('startLocality naming', () {
    Future<String?> localityFrom(String body) async {
      final r = RunSessionRepository.withDependencies(
        db: db, auth: auth, httpClient: geocoderReturning(body));
      final id = await r.saveSession(
        name: 'Run',
        distanceMeters: 1000,
        duration: const Duration(minutes: 6),
        avgPaceMinPerKm: 6,
        elevationDifferenceMeters: 0,
        loopsCompleted: 0,
        path: path,
        closedLoops: const [],
      );
      final doc = await db.collection('runningSessions').doc(id).get();
      return doc.data()!['startLocality'] as String?;
    }

    // Nominatim names the same administrative level differently depending on
    // what kind of place it is, and a run started in a village would
    // otherwise be filed under no locality at all.
    test('a city', () async {
      expect(await localityFrom('{"address":{"city":"Milano"}}'), 'Milano');
    });

    test('a town', () async {
      expect(await localityFrom('{"address":{"town":"Seregno"}}'), 'Seregno');
    });

    test('a village', () async {
      expect(await localityFrom('{"address":{"village":"Barzio"}}'), 'Barzio');
    });

    test('a municipality', () async {
      expect(
          await localityFrom('{"address":{"municipality":"Monza"}}'), 'Monza');
    });

    test('city wins when several are given', () async {
      expect(
          await localityFrom(
              '{"address":{"city":"Milano","town":"X","village":"Y"}}'),
          'Milano');
    });

    test('a response with no address at all leaves it unset', () async {
      expect(await localityFrom('{}'), isNull);
    });

    test('an unparseable response leaves it unset rather than failing',
        () async {
      // Reverse geocoding is best effort: a run must still save.
      expect(await localityFrom('not json'), isNull);
    });
  });
}
