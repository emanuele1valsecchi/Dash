import 'package:dash/widgets/dash_user_tile.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  group('DashUserTile', () {
    testWidgets('shows the full name and email', (tester) async {
      await pumpDashWidget(
        tester,
        const DashUserTile(
          name: 'Andrea',
          surname: 'Pinessi',
          email: 'andrea@example.com',
          profileImageUrl: '',
        ),
      );

      expect(find.text('Andrea Pinessi'), findsOneWidget);
      expect(find.text('andrea@example.com'), findsOneWidget);
    });

    testWidgets('falls back to initials when there is no profile picture',
        (tester) async {
      await pumpDashWidget(
        tester,
        const DashUserTile(
          name: 'Andrea',
          surname: 'Pinessi',
          email: 'andrea@example.com',
          profileImageUrl: '',
        ),
      );

      // An empty URL is the common case for a user who never uploaded one,
      // and must render initials rather than an empty circle.
      expect(find.text('AP'), findsOneWidget);
      expect(find.byType(ProfilePictureAvatar), findsOneWidget);
    });

    testWidgets('trims the gap when a surname is missing', (tester) async {
      await pumpDashWidget(
        tester,
        const DashUserTile(
          name: 'Andrea',
          surname: '',
          email: 'andrea@example.com',
          profileImageUrl: '',
        ),
      );

      // 'Andrea ' with a trailing space would be a visible layout wart.
      expect(find.text('Andrea'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('renders a trailing widget when given one', (tester) async {
      await pumpDashWidget(
        tester,
        const DashUserTile(
          name: 'Andrea',
          surname: 'Pinessi',
          email: 'andrea@example.com',
          profileImageUrl: '',
          trailingIcon: Icon(Icons.person_add),
        ),
      );

      expect(find.byIcon(Icons.person_add), findsOneWidget);
    });

    testWidgets('omits the trailing slot when none is given', (tester) async {
      await pumpDashWidget(
        tester,
        const DashUserTile(
          name: 'Andrea',
          surname: 'Pinessi',
          email: 'andrea@example.com',
          profileImageUrl: '',
        ),
      );

      expect(tester.widget<ListTile>(find.byType(ListTile)).trailing, isNull);
    });

    testWidgets('fires onTap when the row is tapped', (tester) async {
      var taps = 0;
      await pumpDashWidget(
        tester,
        DashUserTile(
          name: 'Andrea',
          surname: 'Pinessi',
          email: 'andrea@example.com',
          profileImageUrl: '',
          onTap: () => taps++,
        ),
      );

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('is inert when no onTap is given', (tester) async {
      await pumpDashWidget(
        tester,
        const DashUserTile(
          name: 'Andrea',
          surname: 'Pinessi',
          email: 'andrea@example.com',
          profileImageUrl: '',
        ),
      );

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
    });
  });
}
