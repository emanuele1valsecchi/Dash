import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/services/route_repository.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  late FakeFirebaseFirestore db;
  late MockFirebaseAuth auth;
  late RouteRepository repo;

  /// Stands in for Nominatim. `publishRoute` reverse-geocodes the route's
  /// first point for `startLocality`; without this the test would make a real
  /// network call, which is slow, flaky, and rude to a free public service.
  http.Client geocoderReturning(String body, {int status = 200}) =>
      MockClient((_) async => http.Response(body, status));

  const seregno = '{"address":{"town":"Seregno"}}';

  setUp(() {
    db = FakeFirebaseFirestore();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'runner-1', email: 'runner@example.com'),
    );
    repo = RouteRepository.withDependencies(
      db: db,
      auth: auth,
      httpClient: geocoderReturning(seregno),
    );
  });

  /// The minimum a caller must supply. Individual tests override what matters.
  Future<String> publish({
    String name = 'Morning loop',
    bool isPublic = false,
    List<LatLng>? polyline,
    String? sourceSessionId,
  }) =>
      repo.publishRoute(
        name: name,
        waypoints: const [LatLng(45.65, 9.20), LatLng(45.66, 9.21)],
        routePolyline: polyline ??
            const [LatLng(45.65, 9.20), LatLng(45.66, 9.21)],
        distanceMeters: 4200,
        estimatedTimeMin: 38,
        estimatedCalories: 294,
        isLoop: true,
        loopAreaM2: 120000,
        isPublic: isPublic,
        sourceSessionId: sourceSessionId,
      );

  Future<Map<String, dynamic>> readRoute(String id) async {
    final doc = await db.collection('routes').doc(id).get();
    return doc.data()!;
  }

  group('publishRoute', () {
    test('writes the route under the signed-in user', () async {
      final id = await publish();

      expect((await readRoute(id))['userId'], 'runner-1');
    });

    test('stores the geometry as GeoPoints', () async {
      // Firestore has no LatLng; the polyline has to survive the round trip
      // through GeoPoint or every saved route comes back empty.
      final id = await publish();
      final data = await readRoute(id);

      final polyline = (data['routePolyline'] as List).cast<GeoPoint>();
      expect(polyline, hasLength(2));
      expect(polyline.first.latitude, closeTo(45.65, 1e-9));
      expect(polyline.first.longitude, closeTo(9.20, 1e-9));
    });

    test('keeps the measurements it was given', () async {
      final data = await readRoute(await publish());

      expect(data['distanceMeters'], 4200);
      expect(data['estimatedTimeMin'], 38);
      expect(data['isLoop'], isTrue);
      expect(data['loopAreaM2'], 120000);
    });

    group('visibility', () {
      test('defaults to private when the caller does not say', () async {
        // The security-relevant default. A caller that forgets to ask must
        // not be able to publish someone's route by accident.
        final id = await repo.publishRoute(
          name: 'Morning loop',
          waypoints: const [],
          routePolyline: const [LatLng(45.65, 9.20)],
          distanceMeters: 100,
          estimatedTimeMin: 1,
          estimatedCalories: 7,
          isLoop: false,
          loopAreaM2: 0,
        );

        expect((await readRoute(id))['isPublic'], isFalse);
      });

      test('is written explicitly, never left absent', () async {
        // firestore.rules requires `isPublic is bool` on create, so a missing
        // field is a rejected write, not a default.
        expect((await readRoute(await publish()))['isPublic'], isNotNull);
      });

      test('honours an explicit publish', () async {
        expect(
          (await readRoute(await publish(isPublic: true)))['isPublic'],
          isTrue,
        );
      });
    });

    group('name handling', () {
      test('trims surrounding whitespace', () async {
        final id = await publish(name: '  Morning loop  ');

        expect((await readRoute(id))['name'], 'Morning loop');
      });

      test('falls back to a placeholder for an empty name', () async {
        expect((await readRoute(await publish(name: '')))['name'],
            'Unnamed route');
      });

      test('falls back for a whitespace-only name too', () async {
        expect((await readRoute(await publish(name: '   ')))['name'],
            'Unnamed route');
      });
    });

    group('startLocality', () {
      test('is filled from the reverse geocode of the first point', () async {
        expect((await readRoute(await publish()))['startLocality'], 'Seregno');
      });

      test('is null when the geocoder fails, without failing the save',
          () async {
        // Locality is a display nicety; losing it must never cost the route.
        repo = RouteRepository.withDependencies(
          db: db,
          auth: auth,
          httpClient: geocoderReturning('nope', status: 500),
        );

        final data = await readRoute(await publish());
        expect(data['startLocality'], isNull);
        expect(data['distanceMeters'], 4200);
      });

      test('is skipped entirely for a route with no polyline', () async {
        final id = await publish(polyline: const []);

        expect((await readRoute(id))['startLocality'], isNull);
      });
    });

    test('omits sourceSessionId for a hand-planned route', () async {
      // Its presence is what marks a route as built from a favourited run.
      expect(
        (await readRoute(await publish())).containsKey('sourceSessionId'),
        isFalse,
      );
    });

    test('records sourceSessionId for a route built from a run', () async {
      final id = await publish(sourceSessionId: 'session-9');

      expect((await readRoute(id))['sourceSessionId'], 'session-9');
    });
  });

  group('fetchUserRoutes', () {
    test('returns only the signed-in user\'s routes', () async {
      await publish(name: 'Mine');
      await db.collection('routes').add({
        'userId': 'someone-else',
        'name': 'Theirs',
        'routePolyline': <GeoPoint>[],
        'distanceMeters': 1000,
        'isPublic': true,
        'createdAt': Timestamp.now(),
      });

      final routes = await repo.fetchUserRoutes();

      expect(routes.map((r) => r.name), ['Mine']);
    });

    test('sorts newest first', () async {
      // Done client-side on purpose, to avoid a composite index.
      for (final name in ['first', 'second', 'third']) {
        await db.collection('routes').add({
          'userId': 'runner-1',
          'name': name,
          'routePolyline': <GeoPoint>[],
          'distanceMeters': 1000,
          'isPublic': false,
          'createdAt': Timestamp.fromDate(
            DateTime(2026, 1, ['first', 'second', 'third'].indexOf(name) + 1),
          ),
        });
      }

      final routes = await repo.fetchUserRoutes();

      expect(routes.map((r) => r.name), ['third', 'second', 'first']);
    });

    test('returns empty rather than throwing when the user has none',
        () async {
      expect(await repo.fetchUserRoutes(), isEmpty);
    });
  });

  group('caching', () {
    test('a second fetch does not re-read Firestore', () async {
      await publish(name: 'Mine');
      await repo.fetchUserRoutes();

      // Write straight to the fake, behind the repository's back. A cached
      // second call must not see it.
      await db.collection('routes').add({
        'userId': 'runner-1',
        'name': 'Added behind the cache',
        'routePolyline': <GeoPoint>[],
        'distanceMeters': 1,
        'isPublic': false,
        'createdAt': Timestamp.now(),
      });

      expect((await repo.fetchUserRoutes()).map((r) => r.name), ['Mine']);
    });

    test('invalidateCache forces a re-read', () async {
      await publish(name: 'Mine');
      await repo.fetchUserRoutes();
      await db.collection('routes').add({
        'userId': 'runner-1',
        'name': 'Added behind the cache',
        'routePolyline': <GeoPoint>[],
        'distanceMeters': 1,
        'isPublic': false,
        'createdAt': Timestamp.now(),
      });

      repo.invalidateCache();

      expect((await repo.fetchUserRoutes()), hasLength(2));
    });

    test('publishing invalidates the cache on its own', () async {
      // Otherwise a route the user just saved would be missing from the list
      // they land on immediately afterwards.
      await publish(name: 'First');
      await repo.fetchUserRoutes();

      await publish(name: 'Second');

      expect((await repo.fetchUserRoutes()), hasLength(2));
    });
  });
}
