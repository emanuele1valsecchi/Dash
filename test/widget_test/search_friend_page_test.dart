import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dash/screens/search_friend_page.dart';
import 'package:dash/widgets/dash_user_tile.dart';

import '../helpers/pump_app.dart';

void main() {
  late FakeFirebaseFirestore db;

  const recentsKey = 'recent_friend_searches';

  setUp(() {
    db = FakeFirebaseFirestore();
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> addProfile(
    String uid, {
    required String name,
    String surname = '',
    String? email,
  }) =>
      db.collection('profiles').doc(uid).set({
        'name': name,
        'surname': surname,
        // Omitted, not empty: the tile's fallback is a `??`, so an empty
        // string would render as blank rather than as the fallback.
        'email': ?email,
        'profileImageUrl': '',
      });

  Map<String, dynamic> recent(String uid, String name) => {
        'uid': uid,
        'name': name,
        'surname': '',
        'email': '$uid@example.com',
        'profileImageUrl': '',
      };

  void seedRecents(List<Map<String, dynamic>> entries) {
    SharedPreferences.setMockInitialValues({recentsKey: jsonEncode(entries)});
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        SearchFriendPage(firestore: db),
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );
      await tester.pumpAndSettle();
    });
  }

  /// A tile's name, scoped so it cannot match the text sitting in the search
  /// field — which holds the same string whenever the query is a whole name.
  Finder tileNamed(String text) => find.descendant(
        of: find.byType(DashUserTile),
        matching: find.text(text),
      );

  /// The per-row remove button. Scoped to the tile because the search field
  /// carries its own clear button, which is also an `IconButton`.
  Finder removeButtons() => find.descendant(
        of: find.byType(DashUserTile),
        matching: find.byIcon(Symbols.close),
      );

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  group('searching', () {
    testWidgets('finds a profile by the start of its name', (tester) async {
      await addProfile('ada', name: 'Ada', email: 'ada@example.com');

      await pumpPage(tester);
      await search(tester, 'Ada');

      expect(find.byType(DashUserTile), findsOneWidget);
      expect(tileNamed('Ada'), findsOneWidget);
    });

    testWidgets('matches a prefix, not only the whole name', (tester) async {
      // The query is a range scan over `name`, so "Ad" has to reach "Ada".
      await addProfile('ada', name: 'Ada');

      await pumpPage(tester);
      await search(tester, 'Ad');

      expect(find.byType(DashUserTile), findsOneWidget);
    });

    testWidgets('leaves out names that do not start with the query',
        (tester) async {
      await addProfile('ada', name: 'Ada');
      await addProfile('bob', name: 'Bob');

      await pumpPage(tester);
      await search(tester, 'Ad');

      expect(tileNamed('Ada'), findsOneWidget);
      expect(tileNamed('Bob'), findsNothing);
    });

    testWidgets('finds several matches at once', (tester) async {
      await addProfile('ada', name: 'Ada');
      await addProfile('adam', name: 'Adam');

      await pumpPage(tester);
      await search(tester, 'Ad');

      expect(find.byType(DashUserTile), findsNWidgets(2));
    });

    testWidgets('a query matching nobody shows no tiles', (tester) async {
      await addProfile('ada', name: 'Ada');

      await pumpPage(tester);
      await search(tester, 'Zebedee');

      expect(find.byType(DashUserTile), findsNothing);
    });

    testWidgets('clearing the query goes back to recents', (tester) async {
      seedRecents([recent('bob', 'Bob')]);
      await addProfile('ada', name: 'Ada');

      await pumpPage(tester);
      await search(tester, 'Ada');
      expect(tileNamed('Ada'), findsOneWidget);

      await search(tester, '');

      expect(tileNamed('Ada'), findsNothing);
      expect(tileNamed('Bob'), findsOneWidget);
    });

    testWidgets('whitespace alone is not a search', (tester) async {
      seedRecents([recent('bob', 'Bob')]);

      await pumpPage(tester);
      await search(tester, '   ');

      expect(tileNamed('Bob'), findsOneWidget,
          reason: 'still showing recents, not an empty result list');
    });

    testWidgets('a profile with no email still renders', (tester) async {
      await addProfile('ada', name: 'Ada');

      await pumpPage(tester);
      await search(tester, 'Ada');

      expect(find.text('No email provided'), findsOneWidget);
    });
  });

  group('recent searches', () {
    testWidgets('are restored from disk on open', (tester) async {
      seedRecents([recent('ada', 'Ada'), recent('bob', 'Bob')]);

      await pumpPage(tester);

      expect(find.byType(DashUserTile), findsNWidgets(2));
      expect(tileNamed('Ada'), findsOneWidget);
    });

    testWidgets('an empty history shows no tiles', (tester) async {
      await pumpPage(tester);

      expect(find.byType(DashUserTile), findsNothing);
      expect(find.text('Recent'), findsOneWidget);
    });

    testWidgets('each carries a remove button; search results do not',
        (tester) async {
      seedRecents([recent('ada', 'Ada')]);

      await pumpPage(tester);
      expect(removeButtons(), findsOneWidget);

      await addProfile('zed', name: 'Zed');
      await search(tester, 'Zed');

      // A search result is somebody to open, not an entry to forget.
      expect(find.byType(DashUserTile), findsOneWidget);
      expect(removeButtons(), findsNothing);
    });

    testWidgets('removing one drops it from the list', (tester) async {
      seedRecents([recent('ada', 'Ada'), recent('bob', 'Bob')]);

      await pumpPage(tester);
      await tester.tap(removeButtons().first);
      await tester.pumpAndSettle();

      expect(find.byType(DashUserTile), findsOneWidget);
      expect(tileNamed('Ada'), findsNothing);
      expect(tileNamed('Bob'), findsOneWidget);
    });

    testWidgets('removing one writes the shortened list back to disk',
        (tester) async {
      seedRecents([recent('ada', 'Ada'), recent('bob', 'Bob')]);

      await pumpPage(tester);
      await tester.tap(removeButtons().first);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(recentsKey)!) as List;
      expect(saved, hasLength(1));
      expect(saved.single['uid'], 'bob');
    });

    testWidgets('Clear All empties the list', (tester) async {
      seedRecents([recent('ada', 'Ada'), recent('bob', 'Bob')]);

      await pumpPage(tester);
      await tester.tap(find.text('Clear All'));
      await tester.pumpAndSettle();

      expect(find.byType(DashUserTile), findsNothing);
    });

    testWidgets('Clear All erases the stored key too', (tester) async {
      // Not merely emptied — removed, so a reopen does not decode an empty
      // list and rewrite it.
      seedRecents([recent('ada', 'Ada')]);

      await pumpPage(tester);
      await tester.tap(find.text('Clear All'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(recentsKey), isNull);
    });

    testWidgets('Clear All is inert when there is nothing to clear',
        (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('Clear All'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('recents stay hidden while a search is active',
        (tester) async {
      seedRecents([recent('bob', 'Bob')]);
      await addProfile('ada', name: 'Ada');

      await pumpPage(tester);
      await search(tester, 'Ada');

      expect(tileNamed('Bob'), findsNothing);
    });
  });

  group('chrome', () {
    testWidgets('is titled and offers the QR scanner', (tester) async {
      await pumpPage(tester);

      expect(find.text('Add a friend'), findsOneWidget);
      expect(find.text('Search for a friend'), findsOneWidget);
      expect(find.byIcon(Symbols.qr_code_scanner_rounded), findsOneWidget);
    });
  });
}
