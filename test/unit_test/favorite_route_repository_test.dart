import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/services/favorite_route_repository.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeFirebaseFirestore db;
  late FavoriteRouteRepository repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = FavoriteRouteRepository.withDependencies(
      db: db,
      auth: MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'runner-1'),
      ),
    );
  });

  /// Creates the pair a real favourite consists of: one *shared* route
  /// document keyed by the source session's id, plus this user's own link
  /// pointing at it. In production both are written by the `favoriteSession`
  /// Cloud Function, never by the client.
  Future<void> seedFavorite(
    String sessionId, {
    String name = 'Their morning run',
    String uid = 'runner-1',
    double distanceMeters = 4200,
  }) async {
    await db.collection('routes').doc(sessionId).set({
      // A shared route has no owner - that is what makes it unrenameable and
      // undeletable from any client.
      'userId': null,
      'isPublic': true,
      'routePolyline': [const GeoPoint(45.65, 9.20), const GeoPoint(45.66, 9.21)],
      'distanceMeters': distanceMeters,
      'estimatedTimeMin': 38,
      'isLoop': true,
      'loopAreaM2': 120000,
      'sourceSessionId': sessionId,
      'createdAt': Timestamp.now(),
    });
    await db.collection('favoriteRoutes').doc('${uid}_$sessionId').set({
      'userId': uid,
      'routeId': sessionId,
      'name': name,
      'distanceMeters': distanceMeters,
      'estimatedTimeMin': 38,
      'isLoop': true,
      'loopAreaM2': 120000,
      'createdAt': Timestamp.now(),
    });
  }

  group('isFavorited', () {
    test('is false for a run this user has not favourited', () async {
      expect(await repo.isFavorited('session-1'), isFalse);
    });

    test('is true once a link exists', () async {
      await seedFavorite('session-1');

      expect(await repo.isFavorited('session-1'), isTrue);
    });

    test('does not see another user\'s favourite of the same run', () async {
      // The link id is uid_sessionId, so this is a direct read that cannot
      // collide across users.
      await seedFavorite('session-1', uid: 'someone-else');

      expect(await repo.isFavorited('session-1'), isFalse);
    });
  });

  group('unfavoriteRoute', () {
    test('deletes this user\'s link', () async {
      await seedFavorite('session-1');

      await repo.unfavoriteRoute('session-1');

      expect(await repo.isFavorited('session-1'), isFalse);
    });

    test('leaves the shared route in place', () async {
      // Other users' favourites may point at it, and it is not this user's to
      // delete.
      await seedFavorite('session-1');

      await repo.unfavoriteRoute('session-1');

      expect((await db.collection('routes').doc('session-1').get()).exists,
          isTrue);
    });

    test('does not touch another user\'s link for the same route', () async {
      await seedFavorite('session-1');
      await seedFavorite('session-1', uid: 'someone-else');

      await repo.unfavoriteRoute('session-1');

      expect(
        (await db.collection('favoriteRoutes').doc('someone-else_session-1').get())
            .exists,
        isTrue,
      );
    });
  });

  group('renameFavorite', () {
    Future<String> nameOf(String sessionId, {String uid = 'runner-1'}) async =>
        (await db.collection('favoriteRoutes').doc('${uid}_$sessionId').get())
            .data()!['name'] as String;

    test('renames only this user\'s link', () async {
      await seedFavorite('session-1');
      await seedFavorite('session-1', uid: 'someone-else', name: 'Theirs');

      await repo.renameFavorite('session-1', 'My favourite loop');

      expect(await nameOf('session-1'), 'My favourite loop');
      expect(await nameOf('session-1', uid: 'someone-else'), 'Theirs');
    });

    test('trims the new name', () async {
      await seedFavorite('session-1');

      await repo.renameFavorite('session-1', '  My loop  ');

      expect(await nameOf('session-1'), 'My loop');
    });

    test('refuses an empty name rather than blanking the row', () async {
      await seedFavorite('session-1', name: 'Original');

      await repo.renameFavorite('session-1', '   ');

      expect(await nameOf('session-1'), 'Original');
    });

    test('never writes to the shared route document', () async {
      // The name is per-user by design; two people may call the same route
      // whatever they like.
      await seedFavorite('session-1');

      await repo.renameFavorite('session-1', 'My loop');

      final shared = await db.collection('routes').doc('session-1').get();
      expect(shared.data()!.containsKey('name'), isFalse);
    });
  });

  group('fetchFavorites', () {
    test('resolves each link to the shared route\'s geometry', () async {
      await seedFavorite('session-1');

      final favorites = await repo.fetchFavorites();

      expect(favorites, hasLength(1));
      expect(favorites.single.routePolyline, hasLength(2));
      expect(favorites.single.distanceMeters, 4200);
    });

    test('takes the name from this user\'s link, not the shared route',
        () async {
      await seedFavorite('session-1', name: 'My favourite loop');

      expect((await repo.fetchFavorites()).single.name, 'My favourite loop');
    });

    test('returns only this user\'s favourites', () async {
      await seedFavorite('session-1');
      await seedFavorite('session-2', uid: 'someone-else');

      final favorites = await repo.fetchFavorites();

      expect(favorites.map((f) => f.id), ['session-1']);
    });

    test('returns empty when there are none', () async {
      expect(await repo.fetchFavorites(), isEmpty);
    });
  });

  group('caching', () {
    test('a second fetch does not re-read Firestore', () async {
      await seedFavorite('session-1');
      await repo.fetchFavorites();

      await seedFavorite('session-2');

      expect(await repo.fetchFavorites(), hasLength(1));
    });

    test('un-favouriting invalidates the cache', () async {
      await seedFavorite('session-1');
      await repo.fetchFavorites();

      await repo.unfavoriteRoute('session-1');

      expect(await repo.fetchFavorites(), isEmpty);
    });

    test('renaming invalidates the cache', () async {
      await seedFavorite('session-1', name: 'Original');
      await repo.fetchFavorites();

      await repo.renameFavorite('session-1', 'Renamed');

      expect((await repo.fetchFavorites()).single.name, 'Renamed');
    });

    test('invalidateCache forces a re-read', () async {
      await seedFavorite('session-1');
      await repo.fetchFavorites();
      await seedFavorite('session-2');

      repo.invalidateCache();

      expect(await repo.fetchFavorites(), hasLength(2));
    });
  });
}
