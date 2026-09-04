import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('ProfilePictureAvatar', () {
    group('falls back to initials', () {
      testWidgets('when the image URL is null', (tester) async {
        await pumpDashWidget(
          tester,
          const ProfilePictureAvatar(initialNameSurname: 'AP'),
        );

        expect(find.text('AP'), findsOneWidget);
        expect(
          tester.widget<CircleAvatar>(find.byType(CircleAvatar))
              .foregroundImage,
          isNull,
        );
      });

      testWidgets('when the image URL is the empty string', (tester) async {
        // The common case for a user who never uploaded a picture: an empty
        // string must read the same as absent, not as a broken image.
        await pumpDashWidget(
          tester,
          const ProfilePictureAvatar(
            initialNameSurname: 'AP',
            imageUrl: '',
          ),
        );

        expect(find.text('AP'), findsOneWidget);
        expect(
          tester.widget<CircleAvatar>(find.byType(CircleAvatar))
              .foregroundImage,
          isNull,
        );
      });
    });

    testWidgets('drops the initials once there is an image to show',
        (tester) async {
      await pumpDashWidget(
        tester,
        const ProfilePictureAvatar(
          initialNameSurname: 'AP',
          imageUrl: 'https://example.invalid/avatar.png',
        ),
      );

      // The initials are the fallback, not an overlay - they must not sit
      // underneath a loaded picture.
      expect(find.text('AP'), findsNothing);
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).foregroundImage,
        isNotNull,
      );
    });

    testWidgets('sizes itself as a fraction of screen width', (tester) async {
      await pumpDashWidget(
        tester,
        const ProfilePictureAvatar(
          initialNameSurname: 'AP',
          aspectRatio: 0.1,
        ),
        surfaceSize: kPhoneSurface,
      );

      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).radius,
        kPhoneSurface.width * 0.1,
      );
    });

    testWidgets('renders a single initial for a one-name user',
        (tester) async {
      await pumpDashWidget(
        tester,
        const ProfilePictureAvatar(initialNameSurname: 'A'),
      );

      expect(find.text('A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders an empty avatar rather than throwing on no initials',
        (tester) async {
      await pumpDashWidget(
        tester,
        const ProfilePictureAvatar(initialNameSurname: ''),
      );

      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
