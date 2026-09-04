import 'package:dash/config/app_theme.dart';
import 'package:dash/screens/user_setup_page.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:dash/services/wear_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import '../mocks.mocks.dart';

/// Profile setup: the last step of signing up, and the only place a username
/// is chosen. Two things make it worth testing carefully — the uniqueness
/// check is a network round trip that must not be skipped, and the nickname
/// index has to be written or the name is not actually reserved.
void main() {
  late MockProfileService profiles;

  setUpAll(() async {
    // Success navigates to RootScreen, which touches Firebase in initState.
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    profiles = MockProfileService();
    when(profiles.isUsernameTaken(any)).thenAnswer((_) async => false);
    when(profiles.createProfile(
      username: anyNamed('username'),
      name: anyNamed('name'),
      surname: anyNamed('surname'),
      bio: anyNamed('bio'),
      profileImage: anyNamed('profileImage'),
    )).thenAnswer((_) async {});
    when(profiles.saveNickname(any)).thenAnswer((_) async {});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: UserSetupScreen(profileService: profiles),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Advances past the sign-up, tolerating the destination's Firebase errors.
  /// See login_page_auth_flow_test.dart for why the app shell cannot mount.
  Future<void> submit(WidgetTester tester) async {
    // The tick in the header, rather than the main button: both call the same
    // handler, and this one has a stable finder regardless of the loading
    // spinner the other swaps in.
    await tester.tap(find.byIcon(Icons.check));
    // Several frames, not one: the submit path awaits three futures in
    // sequence (uniqueness check, profile write, nickname write) before it
    // navigates. A single pump flushes only the first, which makes any
    // assertion about the later calls depend on scheduling luck.
    // `pumpAndSettle` is not an option — the destination never goes idle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // `WearBridge` is an app-lifetime singleton that `HomePage.initState`
    // starts, opening a 1-second periodic timer that nothing cancels — by
    // design, since it is meant to outlive any one screen. `flutter_test`
    // fails a test that ends with a pending timer, so it is stopped here,
    // *inside the test body*: `addTearDown` runs after the framework's
    // invariant check, which is too late.
    WearBridge.instance.dispose();

    for (var i = 0; i < 100; i++) {
      final error = tester.takeException();
      if (error == null) return;
      final text = error.toString();
      if (!text.toLowerCase().contains('firebase') &&
          !text.contains('Multiple exceptions')) {
        fail('Unexpected error during setup: $error');
      }
    }
  }

  /// Fills the four fields by position: username, name, surname, bio.
  ///
  /// Addressed by index rather than by hint text because 'Surname' is used as
  /// both a label and a hint, so a text finder matches two widgets and is
  /// ambiguous.
  Future<void> fillForm(
    WidgetTester tester, {
    String username = 'speedy',
    String name = 'Andrea',
    String surname = 'Pinessi',
    String bio = '',
  }) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), username);
    await tester.enterText(fields.at(1), name);
    await tester.enterText(fields.at(2), surname);
    if (bio.isNotEmpty) await tester.enterText(fields.at(3), bio);
    await tester.pump();
  }

  group('layout', () {
    testWidgets('asks for the four profile fields', (tester) async {
      await pumpPage(tester);

      expect(find.byType(TextField), findsNWidgets(4));
      expect(find.text('Username'), findsOneWidget);
      expect(find.text('@username'), findsOneWidget);
      // 'Surname' is both the label and the hint on that field.
      expect(find.text('Surname'), findsNWidgets(2));
      expect(find.text('Bio'), findsOneWidget);
    });
  });

  group('local validation happens before any network call', () {
    testWidgets('an empty form is refused', (tester) async {
      await pumpPage(tester);

      await submit(tester);

      expect(find.text('Username, name and surname are required'),
          findsOneWidget);
      verifyNever(profiles.isUsernameTaken(any));
    });

    testWidgets('a missing surname is refused', (tester) async {
      await pumpPage(tester);
      await fillForm(tester, surname: '');

      await submit(tester);

      expect(find.text('Username, name and surname are required'),
          findsOneWidget);
    });

    testWidgets('whitespace does not count as a name', (tester) async {
      await pumpPage(tester);
      await fillForm(tester, name: '   ');

      await submit(tester);

      expect(find.text('Username, name and surname are required'),
          findsOneWidget);
    });

    testWidgets('a two-character username is refused', (tester) async {
      await pumpPage(tester);
      await fillForm(tester, username: 'ab');

      await submit(tester);

      expect(find.text('Username must be at least 3 characters'),
          findsOneWidget);
      verifyNever(profiles.isUsernameTaken(any));
    });

    testWidgets('three characters is accepted, not off by one',
        (tester) async {
      await pumpPage(tester);
      await fillForm(tester, username: 'abc');

      await submit(tester);

      expect(find.text('Username must be at least 3 characters'), findsNothing);
      verify(profiles.isUsernameTaken('abc')).called(1);
    });

    testWidgets('the bio is optional', (tester) async {
      await pumpPage(tester);
      await fillForm(tester);

      await submit(tester);

      verify(profiles.createProfile(
        username: anyNamed('username'),
        name: anyNamed('name'),
        surname: anyNamed('surname'),
        bio: '',
        profileImage: anyNamed('profileImage'),
      )).called(1);
    });
  });

  group('username uniqueness', () {
    testWidgets('is checked before the profile is created', (tester) async {
      await pumpPage(tester);
      await fillForm(tester);

      await submit(tester);

      verify(profiles.isUsernameTaken('speedy')).called(1);
    });

    testWidgets('a taken username stops the sign-up', (tester) async {
      // The check must actually gate the write - not merely warn after it.
      when(profiles.isUsernameTaken(any)).thenAnswer((_) async => true);

      await pumpPage(tester);
      await fillForm(tester);
      await submit(tester);

      expect(find.text('Username already taken, choose another'),
          findsOneWidget);
      verifyNever(profiles.createProfile(
        username: anyNamed('username'),
        name: anyNamed('name'),
        surname: anyNamed('surname'),
        bio: anyNamed('bio'),
        profileImage: anyNamed('profileImage'),
      ));
      verifyNever(profiles.saveNickname(any));
    });
  });

  group('creating the profile', () {
    testWidgets('passes the trimmed values through', (tester) async {
      await pumpPage(tester);
      await fillForm(
        tester,
        username: '  speedy  ',
        name: '  Andrea  ',
        surname: '  Pinessi  ',
        bio: '  Runner  ',
      );

      await submit(tester);

      verify(profiles.createProfile(
        username: 'speedy',
        name: 'Andrea',
        surname: 'Pinessi',
        bio: 'Runner',
        profileImage: anyNamed('profileImage'),
      )).called(1);
    });

    testWidgets('reserves the nickname in its own index', (tester) async {
      // Two writes, not one: the profile document and the separate
      // `nicknames/{nickname}` uniqueness index. Skipping the second would
      // leave the name unreserved and the next person could take it.
      await pumpPage(tester);
      await fillForm(tester);

      await submit(tester);

      verify(profiles.saveNickname('speedy')).called(1);
    });

    testWidgets('reserves the nickname only after the profile is written',
        (tester) async {
      await pumpPage(tester);
      await fillForm(tester);

      await submit(tester);

      verifyInOrder([
        profiles.isUsernameTaken('speedy'),
        profiles.createProfile(
          username: anyNamed('username'),
          name: anyNamed('name'),
          surname: anyNamed('surname'),
          bio: anyNamed('bio'),
          profileImage: anyNamed('profileImage'),
        ),
        profiles.saveNickname('speedy'),
      ]);
    });
  });

  group('failures', () {
    testWidgets('a thrown error is reported rather than swallowed',
        (tester) async {
      when(profiles.createProfile(
        username: anyNamed('username'),
        name: anyNamed('name'),
        surname: anyNamed('surname'),
        bio: anyNamed('bio'),
        profileImage: anyNamed('profileImage'),
      )).thenThrow(Exception('network down'));

      await pumpPage(tester);
      await fillForm(tester);
      await submit(tester);

      expect(find.textContaining('Something went wrong'), findsOneWidget);
    });

    testWidgets('the user is left able to retry', (tester) async {
      when(profiles.isUsernameTaken(any)).thenThrow(Exception('network down'));

      await pumpPage(tester);
      await fillForm(tester);
      await submit(tester);

      expect(find.byType(UserSetupScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
