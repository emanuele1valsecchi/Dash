import 'package:flutter_test/flutter_test.dart';

import 'package:dash/utils/profile_link.dart';

/// The profile deep link is written by `share_profile_page` into a QR code and
/// read back by `qr_scanner_page`. Both halves are pinned here because the
/// failure mode is silent: a scanner that no longer recognises the app's own
/// link does not error, it simply keeps scanning, and the user is left holding
/// a phone at a QR code that "doesn't work".
///
/// The parser also runs on whatever arbitrary QR code a camera happens to see,
/// so most of what follows is about rejecting input cleanly rather than
/// parsing the happy path.
void main() {
  group('round trip', () {
    test('what the share page writes is what the scanner reads', () {
      // The one test that would fail if either side changed format alone.
      const userId = 'runner-1';

      expect(ProfileLink.userIdFrom(ProfileLink.forUser(userId)), userId);
    });

    test('survives ids that need escaping', () {
      // Firebase uids are alphanumeric, but nothing enforces that here and a
      // link is user-visible text that may be re-typed or truncated.
      for (final id in const ['a-b_c', 'ABC123', '0']) {
        expect(ProfileLink.userIdFrom(ProfileLink.forUser(id)), id,
            reason: 'round trip failed for "$id"');
      }
    });

    test('the written link is the canonical https one', () {
      // Pinned because it is printed, shared and possibly already in the wild
      // — changing it silently invalidates every QR code already handed out.
      expect(ProfileLink.forUser('runner-1'),
          'https://dash-efb1d.web.app/profile/runner-1');
    });
  });

  group('reading a scanned value', () {
    test('accepts the canonical link', () {
      expect(
        ProfileLink.userIdFrom('https://dash-efb1d.web.app/profile/abc123'),
        'abc123',
      );
    });

    test('accepts a link from another host', () {
      // Deliberate: a profile is public to any signed-in user, so the host
      // grants nothing. Being strict would break every printed code the day
      // the hosting domain changed. Documented here so the looseness is a
      // decision rather than an oversight.
      expect(
        ProfileLink.userIdFrom('https://example.com/profile/abc123'),
        'abc123',
      );
    });

    test('ignores extra path segments after the id', () {
      expect(
        ProfileLink.userIdFrom('https://dash-efb1d.web.app/profile/abc123/runs'),
        'abc123',
      );
    });

    test('ignores query strings and fragments', () {
      expect(
        ProfileLink.userIdFrom(
            'https://dash-efb1d.web.app/profile/abc123?ref=qr#top'),
        'abc123',
      );
    });
  });

  group('rejecting anything else', () {
    test('a null raw value', () {
      // `Barcode.rawValue` is nullable — a detected-but-undecodable symbol.
      expect(ProfileLink.userIdFrom(null), isNull);
    });

    test('an empty string', () {
      expect(ProfileLink.userIdFrom(''), isNull);
    });

    test('an unrelated URL', () {
      expect(ProfileLink.userIdFrom('https://example.com/about'), isNull);
    });

    test('a different first segment', () {
      // The guard that stops, say, a route-sharing link being read as a user.
      expect(
        ProfileLink.userIdFrom('https://dash-efb1d.web.app/route/abc123'),
        isNull,
      );
    });

    test('a profile link with no id', () {
      expect(
        ProfileLink.userIdFrom('https://dash-efb1d.web.app/profile'),
        isNull,
      );
    });

    test('a profile link with an empty id', () {
      // `/profile//` parses to segments ['profile', ''] — a link that looks
      // structurally right but names nobody. Navigating on it would open a
      // profile page bound to an empty uid.
      expect(
        ProfileLink.userIdFrom('https://dash-efb1d.web.app/profile//'),
        isNull,
      );
    });

    test('plain text that is not a URI at all', () {
      // Uri.tryParse is famously permissive, so this is checked rather than
      // assumed: most free text parses into a path-only Uri.
      expect(ProfileLink.userIdFrom('hello world'), isNull);
      expect(ProfileLink.userIdFrom('WIFI:S:mynet;T:WPA;P:secret;;'), isNull);
    });

    test('a relative path that happens to match the shape', () {
      // No host, but the path shape is right. Accepted, because the check is
      // deliberately about shape only — recorded so the behaviour is known.
      expect(ProfileLink.userIdFrom('profile/abc123'), 'abc123');
    });
  });
}
