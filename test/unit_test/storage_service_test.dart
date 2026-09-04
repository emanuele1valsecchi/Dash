import 'package:flutter_test/flutter_test.dart';

import 'package:dash/services/storage_service.dart';

/// The two-sided download-URL helper.
///
/// `getDownloadUrl` throws so a caller can handle failure explicitly;
/// `getDownloadUrlSafe` never throws and answers null instead, for the places
/// that just want a fallback — an avatar in a list of users, where one missing
/// image must not take the list down.
///
/// **Only the guard clause is covered here, and deliberately so.**
/// `StorageService` resolves `FirebaseStorage.instance` with no injection
/// seam, and `firebase_storage_mocks` is not a dev-dependency (see the note in
/// section 4 of TEST_NOTES). What *is* reachable without either is the branch
/// that decides an empty path is not worth a network call at all — and that is
/// the one that runs most often, since a profile with no picture is the common
/// case.
void main() {
  late StorageService service;

  setUp(() {
    // Constructing is safe: `_storage` is `late`, so no Firebase is touched
    // until a path actually reaches it.
    service = StorageService();
  });

  group('getDownloadUrlSafe short-circuits before Firebase', () {
    test('a null path resolves to null', () async {
      // The common case: a profile with no picture at all.
      expect(await service.getDownloadUrlSafe(null), isNull);
    });

    test('an empty path resolves to null', () async {
      expect(await service.getDownloadUrlSafe(''), isNull);
    });

    test('a whitespace-only path resolves to null', () async {
      // Trimmed before the emptiness check, so a stray space in Firestore
      // does not become a doomed Storage request per rendered avatar.
      expect(await service.getDownloadUrlSafe('   '), isNull);
      expect(await service.getDownloadUrlSafe('\n\t '), isNull);
    });

    test('it returns rather than throwing, which is the whole contract',
        () async {
      // The difference between the two methods. A list of avatars calls this
      // one precisely so one absent image cannot raise.
      await expectLater(service.getDownloadUrlSafe(null), completes);
    });
  });
}
