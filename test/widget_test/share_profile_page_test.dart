import 'package:dash/screens/share_profile_page.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../helpers/pump_app.dart';

void main() {
  const page = ShareProfilePage(
    userId: 'runner-1',
    name: 'Andrea',
    surname: 'Pinessi',
    profileImageUrl: '',
  );

  const expectedLink = 'https://dash-efb1d.web.app/profile/runner-1';

  Future<void> pumpPage(WidgetTester tester, [Widget? subject]) => pumpDashWidget(
        tester,
        subject ?? page,
        wrapInScaffold: false,
        surfaceSize: kPhoneSurface,
      );

  group('layout', () {
    testWidgets('shows the person whose profile is being shared',
        (tester) async {
      await pumpPage(tester);

      expect(find.text('Share Profile'), findsOneWidget);
      expect(find.text('Andrea Pinessi'), findsOneWidget);
    });

    testWidgets('shows their avatar', (tester) async {
      await pumpPage(tester);

      expect(find.byType(ProfilePictureAvatar), findsOneWidget);
      // No picture uploaded, so it falls back to initials.
      expect(find.text('AP'), findsOneWidget);
    });

    testWidgets('renders a QR code', (tester) async {
      await pumpPage(tester);

      expect(find.byType(PrettyQrView), findsOneWidget);
    });

    testWidgets('offers both sharing actions', (tester) async {
      await pumpPage(tester);

      expect(find.text('Copy Link'), findsOneWidget);
      expect(find.text('Share External'), findsOneWidget);
    });

    // These assert the action buttons never clip, at every common phone width.
    //
    // **Read the result carefully.** `flutter test` substitutes a monospace
    // test font in which every glyph is a full em square, so a label measures
    // roughly twice its real width (a 15px "Continue with Google" measures
    // 300px here, ~145px on a device). That makes this a deliberately
    // *conservative* check: passing proves the layout is safe with a large
    // margin, but a failure is not by itself evidence of a user-visible bug —
    // measure real text metrics before acting on one.
    for (final width in const [320.0, 360.0, 390.0, 430.0]) {
      testWidgets('lays out without overflowing at ${width}pt wide',
          (tester) async {
        await pumpDashWidget(
          tester,
          page,
          wrapInScaffold: false,
          surfaceSize: Size(width, 900),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Copy Link'), findsOneWidget);
        expect(find.text('Share External'), findsOneWidget);
      });
    }
  });

  group('profile link', () {
    test('is built from the user id', () {
      // The QR code and the clipboard both encode this, so it is the one
      // thing on the page that must not drift.
      expect(page.profileLink, expectedLink);
    });

    test('changes with the user', () {
      const other = ShareProfilePage(
        userId: 'someone-else',
        name: 'X',
        surname: 'Y',
        profileImageUrl: '',
      );

      expect(other.profileLink, endsWith('/someone-else'));
    });

    // What the QR *encodes* is deliberately not asserted here: PrettyQrView
    // exposes its decoded data only to subclasses, so reaching it would mean
    // testing the library rather than this page. The page passes
    // `profileLink` to both the QR and the clipboard, and the clipboard side
    // is asserted below — so the link itself is pinned either way.
  });

  group('Copy Link', () {
    testWidgets('puts the profile link on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpPage(tester);
      await tester.tap(find.text('Copy Link'));
      await tester.pumpAndSettle();

      expect(copied, expectedLink);
    });

    testWidgets('confirms the copy so the tap is not silent', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpPage(tester);
      await tester.tap(find.text('Copy Link'));
      await tester.pumpAndSettle();

      expect(find.text('Link copied to clipboard!'), findsOneWidget);
    });
  });

  group('name handling', () {
    testWidgets('trims the gap when there is no surname', (tester) async {
      await pumpPage(
        tester,
        const ShareProfilePage(
          userId: 'runner-1',
          name: 'Andrea',
          surname: '',
          profileImageUrl: '',
        ),
      );

      expect(find.text('Andrea'), findsOneWidget);
    });

    testWidgets('renders without a name at all rather than throwing',
        (tester) async {
      await pumpPage(
        tester,
        const ShareProfilePage(
          userId: 'runner-1',
          name: '',
          surname: '',
          profileImageUrl: '',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(PrettyQrView), findsOneWidget);
    });
  });
}
