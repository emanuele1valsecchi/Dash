import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart'
    show PermissionHandlerPlatform;

import 'package:dash/screens/qr_scanner_page.dart';

import '../helpers/fake_location_platform.dart' show FakePermissions;
import '../helpers/pump_app.dart';

/// Scanning a friend's profile QR code.
///
/// The page is a camera viewfinder, which a widget test cannot render — but
/// the camera is not where its decisions are. What this page decides is
/// whether to open *at all*, and that is a consent gate testable with a fake
/// permission platform and no camera whatsoever.
///
/// **The granted path is deliberately not tested here.** Once permission
/// lands the page constructs a `MobileScannerController`, which starts a
/// platform timer that outlives the widget tree — `flutter_test` fails the
/// test for it, and it cannot be cancelled from outside the page. Reaching
/// `_handleDetect` (the one-shot guard, and skipping barcodes that are not
/// profile links) would need that controller, so it stays integration-test
/// territory. What it parses is `ProfileLink`'s and is covered in
/// `profile_link_test.dart`.
void main() {
  late FakePermissions permissions;

  setUp(() {
    permissions = FakePermissions();
    PermissionHandlerPlatform.instance = permissions;
  });

  /// Holds the permission check open indefinitely, so the page can be
  /// inspected mid-check. A `Completer` rather than a delay on purpose: an
  /// unfinished `Future.delayed` is a pending timer, which is the very thing
  /// this file has to avoid leaving behind.
  Future<void> installPendingCheck() async {
    PermissionHandlerPlatform.instance = _PendingPermissions();
  }

  /// Pumps the scanner behind a button, so "did it close?" is answerable — a
  /// page that pops as its first act needs somewhere to pop back to.
  Future<void> pumpScanner(WidgetTester tester) async {
    await pumpDashWidget(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const QrScannerPage()),
          ),
          child: const Text('open'),
        ),
      ),
      surfaceSize: kPhoneSurface,
    );
    await tester.tap(find.text('open'));
    // Long enough for the push transition to finish, and no `pumpAndSettle`:
    // a single frame only *starts* the transition, so every `findsNothing`
    // below would pass against a page that had not been built — while
    // settling never returns, because the waiting state is a spinner that
    // animates for as long as it is shown.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('while it is still asking', () {
    setUp(installPendingCheck);

    testWidgets('it waits rather than showing a dead viewfinder',
        (tester) async {
      await pumpScanner(tester);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(MobileScanner), findsNothing);
    });

    testWidgets('it offers no torch until there is a camera to light',
        (tester) async {
      // The torch button is gated on the controller existing, not on the
      // page being open — offering it earlier would reach a null camera.
      await pumpScanner(tester);

      expect(find.byType(QrScannerPage), findsOneWidget,
          reason: 'otherwise the absence below proves nothing');
      expect(find.byIcon(Symbols.flashlight_on_rounded), findsNothing);
    });

    testWidgets('it is titled while it waits', (tester) async {
      await pumpScanner(tester);

      expect(find.text('Scan QR Code'), findsOneWidget);
    });
  });

  group('when permission is refused', () {
    testWidgets('the scanner closes instead of opening', (tester) async {
      // The camera must not be reachable without consent — and a page left
      // spinning forever would read as a hang rather than as a refusal.
      permissions.status = PermissionStatus.permanentlyDenied;

      await pumpScanner(tester);
      await tester.pumpAndSettle();

      expect(find.byType(QrScannerPage), findsNothing);
      expect(find.text('open'), findsOneWidget, reason: 'back where we were');
    });

    testWidgets('it asks first, rather than refusing on the stored status',
        (tester) async {
      // A first-run user has no decision recorded: the status is `denied`
      // and the request is what turns it into an answer. Treating that
      // initial `denied` as final would make the scanner permanently
      // unusable for them without a single prompt.
      permissions.status = PermissionStatus.denied;

      await pumpScanner(tester);
      await tester.pumpAndSettle();

      expect(permissions.requests, 1);
    });

    testWidgets('a refusal is not treated as a camera error', (tester) async {
      // Distinct states: the error text belongs to a camera that failed to
      // start, not to one that was never allowed to.
      permissions.status = PermissionStatus.permanentlyDenied;

      await pumpScanner(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('Camera error'), findsNothing);
    });
  });
}

/// A permission platform whose check never resolves.
class _PendingPermissions extends FakePermissions {
  final _never = Completer<PermissionStatus>();

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) =>
      _never.future;
}
