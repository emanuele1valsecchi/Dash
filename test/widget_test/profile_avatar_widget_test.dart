import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart'
    show PermissionHandlerPlatform;

import 'package:dash/widgets/profile_avatar_widget.dart';

import '../helpers/fake_location_platform.dart' show FakePermissions;
import '../helpers/pump_app.dart';

/// The tap-to-change profile picture avatar.
///
/// The picker itself is a platform channel and cannot run here, so what is
/// tested is everything around it: which of the three visual states is drawn,
/// and — the part that matters — that the gallery is never reached without
/// permission, and that a refusal is explained rather than silently doing
/// nothing.
void main() {
  late FakePermissions permissions;

  setUp(() {
    permissions = FakePermissions();
    PermissionHandlerPlatform.instance = permissions;
  });

  Future<void> pumpAvatar(WidgetTester tester, {String? url}) async {
    await mockNetworkImagesFor(() async {
      await pumpDashWidget(
        tester,
        ProfileAvatarWidget(initialImageUrl: url),
        surfaceSize: kPhoneSurface,
      );
      await tester.pump();
    });
  }

  Future<void> tapAvatar(WidgetTester tester) async {
    await mockNetworkImagesFor(() async {
      await tester.tap(find.byType(ProfileAvatarWidget));
      await tester.pump();
    });
  }

  group('what it shows', () {
    testWidgets('a placeholder person when there is no picture yet',
        (tester) async {
      await pumpAvatar(tester);

      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });

    testWidgets('no placeholder once a picture is set', (tester) async {
      await pumpAvatar(tester, url: 'https://example.com/me.png');

      expect(find.byIcon(Icons.person_rounded), findsNothing);
    });

    testWidgets('an add badge either way, so it reads as changeable',
        (tester) async {
      await pumpAvatar(tester, url: 'https://example.com/me.png');

      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('nothing is loading before it is tapped', (tester) async {
      await pumpAvatar(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('permission', () {
    testWidgets('an already-granted permission is not asked for again',
        (tester) async {
      // A prompt the user answered once should not reappear on every tap.
      permissions.status = PermissionStatus.granted;
      await pumpAvatar(tester);

      await tapAvatar(tester);

      expect(permissions.requests, 0);
    });

    testWidgets('a first-run user is asked', (tester) async {
      // The stored status is `denied` before any decision has been made;
      // treating that as final would make the avatar permanently untappable.
      permissions.status = PermissionStatus.denied;
      await pumpAvatar(tester);

      await tapAvatar(tester);

      expect(permissions.requests, 1);
    });

    testWidgets('a refusal stops before the gallery, and shows no spinner',
        (tester) async {
      // The loading state is entered only *after* permission is granted —
      // a spinner over a refused permission would suggest work in progress
      // that is never going to finish.
      permissions.status = PermissionStatus.denied;
      await pumpAvatar(tester);

      await tapAvatar(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });

    testWidgets('a permanent refusal points at the settings app',
        (tester) async {
      // There is nothing left to prompt for at this point, so the only way
      // back is Settings. Saying nothing would look like a broken button.
      permissions.status = PermissionStatus.permanentlyDenied;
      await pumpAvatar(tester);

      await tapAvatar(tester);
      await tester.pump();

      expect(find.textContaining('impostazioni'), findsOneWidget);
      expect(find.text('Impostazioni'), findsOneWidget,
          reason: 'the snackbar carries an action, not just an explanation');
    });

    testWidgets('an ordinary refusal is not sent to settings', (tester) async {
      // Settings cannot help someone who simply tapped "deny" — they can be
      // asked again.
      permissions.status = PermissionStatus.denied;
      await pumpAvatar(tester);

      await tapAvatar(tester);
      await tester.pump();

      expect(find.text('Impostazioni'), findsNothing);
    });
  });
}
