import 'package:dash/utils/session_leaderboards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('leaderboardsForSession', () {
    test('a run counts toward both its locality and its metro area', () {
      // The rule this whole file exists to keep in one place: filing under
      // only the metro area buries the village you ran in; filing under only
      // the village fragments the metro board the coverage polygons exist to
      // create.
      expect(
        leaderboardsForSession(
          startLocality: 'Seregno',
          territoryCity: 'Milano',
        ),
        ['Seregno', 'Milano'],
      );
    });

    test('the locality comes first, as the more specific board', () {
      final boards = leaderboardsForSession(
        startLocality: 'Seregno',
        territoryCity: 'Milano',
      );

      expect(boards.first, 'Seregno');
    });

    test('a curated city wins over the broad region', () {
      expect(
        leaderboardsForSession(
          startLocality: 'Seregno',
          territoryCity: 'Milano',
          territoryBroad: 'Lombardia',
        ),
        ['Seregno', 'Milano'],
      );
    });

    test('falls back to the broad region when no polygon matched', () {
      // Without this fallback a runner outside every curated polygon earns XP
      // but appears on no board at all.
      expect(
        leaderboardsForSession(
          startLocality: 'Bergamo',
          territoryBroad: 'Northern Lombardy',
        ),
        ['Bergamo', 'Northern Lombardy'],
      );
    });

    group('deduplication', () {
      test('a village sharing its metro name yields a single board', () {
        expect(
          leaderboardsForSession(
            startLocality: 'Milano',
            territoryCity: 'Milano',
          ),
          ['Milano'],
        );
      });

      test('a locality equal to the broad region yields a single board', () {
        expect(
          leaderboardsForSession(
            startLocality: 'Lombardia',
            territoryBroad: 'Lombardia',
          ),
          ['Lombardia'],
        );
      });
    });

    group('missing and malformed inputs', () {
      test('locality alone still produces a board', () {
        expect(leaderboardsForSession(startLocality: 'Seregno'), ['Seregno']);
      });

      test('territory alone still produces a board', () {
        expect(leaderboardsForSession(territoryCity: 'Milano'), ['Milano']);
      });

      test('nothing resolved yields no boards, not a null entry', () {
        // Callers read empty as "global board only".
        expect(leaderboardsForSession(), isEmpty);
      });

      test('empty strings are treated as absent', () {
        expect(
          leaderboardsForSession(startLocality: '', territoryCity: ''),
          isEmpty,
        );
      });

      test('whitespace-only strings are treated as absent', () {
        expect(
          leaderboardsForSession(startLocality: '   ', territoryCity: '\t'),
          isEmpty,
        );
      });

      test('surrounding whitespace is trimmed off a real name', () {
        // A padded name would otherwise open a second board keyed by a string
        // that looks identical to the user.
        expect(
          leaderboardsForSession(
            startLocality: '  Seregno  ',
            territoryCity: ' Milano ',
          ),
          ['Seregno', 'Milano'],
        );
      });

      test('a padded duplicate still collapses to one board', () {
        expect(
          leaderboardsForSession(
            startLocality: ' Milano ',
            territoryCity: 'Milano',
          ),
          ['Milano'],
        );
      });
    });
  });

  group('displayLocalityForSession', () {
    test('shows the locality the run actually started in', () {
      // Showing "Northern Lombardy" instead reads as though the app lost
      // track of where you were.
      expect(
        displayLocalityForSession(
          startLocality: 'Seregno',
          territoryCity: 'Milano',
        ),
        'Seregno',
      );
    });

    test('falls back to the curated city when there is no locality', () {
      expect(
        displayLocalityForSession(
          territoryCity: 'Milano',
          territoryBroad: 'Lombardia',
        ),
        'Milano',
      );
    });

    test('falls back to the broad region as a last resort', () {
      expect(
        displayLocalityForSession(territoryBroad: 'Lombardia'),
        'Lombardia',
      );
    });

    test('returns null when nothing resolved', () {
      expect(displayLocalityForSession(), isNull);
    });

    test('treats empty and whitespace as absent', () {
      expect(
        displayLocalityForSession(startLocality: '  ', territoryCity: 'Milano'),
        'Milano',
      );
    });

    test('trims the name it returns', () {
      expect(
        displayLocalityForSession(startLocality: '  Seregno  '),
        'Seregno',
      );
    });
  });

  group('the two agree with each other', () {
    test('the displayed name is always one of the boards scored', () {
      // If these ever disagreed, a run would show a place name that has no
      // board behind it - the exact confusion this module was extracted to
      // prevent.
      const cases = [
        (locality: 'Seregno', city: 'Milano', broad: 'Lombardia'),
        (locality: 'Milano', city: 'Milano', broad: null),
        (locality: null, city: 'Milano', broad: 'Lombardia'),
        (locality: null, city: null, broad: 'Lombardia'),
      ];

      for (final c in cases) {
        final boards = leaderboardsForSession(
          startLocality: c.locality,
          territoryCity: c.city,
          territoryBroad: c.broad,
        );
        final shown = displayLocalityForSession(
          startLocality: c.locality,
          territoryCity: c.city,
          territoryBroad: c.broad,
        );

        expect(boards, contains(shown), reason: 'case $c');
      }
    });
  });
}
