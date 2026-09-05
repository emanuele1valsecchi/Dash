const {test, describe} = require('node:test');
const assert = require('node:assert');

const {
  square,
  candidateFromArea,
  loopAreaM2,
  storedAreaM2,
  claim,
  geo,
} = require('./helpers');

// `computeClaim` is the only place in the system that decides who owns which
// ground. It runs server-side under the Admin SDK, bypasses Firestore rules,
// and *permanently* rewrites other players' documents — shrinking them, or
// flagging them deleted. A wrong branch here does not throw; it silently hands
// someone else's territory to the wrong player, or quietly loses ground that
// was legitimately claimed. Nothing in the app can detect that after the fact.
//
// Ported from `_verify_geo.js`, which asserted the same four scenarios but ran
// as a plain script: it printed and exited 0, so nothing could tell a broken
// build from a passing one. The scenarios are unchanged; what follows the
// first describe block is coverage that script did not have.

describe('computeClaim — scenarios ported from _verify_geo.js', () => {
  test('free territory: a loop touching nothing becomes a plain new area', () => {
    const points = square(0, 0, 1);
    const result = claim({newLoopPoints: points, sessionData: {
      durationMs: 600000, avgPaceMinPerKm: 6, startLocality: 'Milan',
    }});

    assert.strictEqual(result.deletes.length, 0);
    assert.strictEqual(result.otherOwnerUpdates.length, 0);
    assert.strictEqual(result.newArea.polygon.length, 1);
    assert.strictEqual(result.newArea.contributions.length, 1);
    assert.ok(Math.abs(result.totalAreaM2 - loopAreaM2(points)) < 1);
    assert.strictEqual(result.stolenAreaM2, 0, 'nothing overlapped, nothing stolen');
  });

  test('a loop fully inside your own area changes nothing visible', () => {
    const outer = claim({newLoopPoints: square(10, 10, 5)}).newArea;

    const innerPoints = square(10, 10, 1);
    const inner = claim({
      newLoopPoints: innerPoints,
      sessionId: 's2',
      candidates: [candidateFromArea('s1_0', 'A', outer, outer.contributions, 500)],
      now: 2000,
    });

    assert.deepStrictEqual(inner.deletes, ['s1_0'], 'the absorbed doc is removed');
    assert.strictEqual(inner.otherOwnerUpdates.length, 0);
    assert.strictEqual(inner.newArea.polygon.length, 1);
    assert.ok(
        Math.abs(storedAreaM2(outer.polygon) - storedAreaM2(inner.newArea.polygon)) < 1,
        'the shape should be unchanged, not stacked on top of itself',
    );
    assert.strictEqual(inner.newArea.contributions.length, 2, 'both runs are listed');

    // The XP guard: re-running a tiny loop inside a huge existing area must
    // not pay out the whole area again.
    assert.ok(
        Math.abs(inner.totalAreaM2 - loopAreaM2(innerPoints)) < 1,
        `totalAreaM2 should be the small loop's own area, got ${inner.totalAreaM2}`,
    );
    assert.strictEqual(inner.stolenAreaM2, 0);
  });

  test('a loop half-overlapping your own area merges into one shape', () => {
    const first = claim({newLoopPoints: square(0, 0, 2)}).newArea;

    const secondPoints = square(2, 0, 2);
    const merged = claim({
      newLoopPoints: secondPoints,
      sessionId: 's2',
      candidates: [candidateFromArea('s1_0', 'A', first, first.contributions, 500)],
      now: 2000,
    });

    assert.deepStrictEqual(merged.deletes, ['s1_0']);
    assert.strictEqual(merged.otherOwnerUpdates.length, 0);
    assert.strictEqual(merged.newArea.polygon.length, 1,
        'one seamless piece, not two shapes with a border down the middle');
    assert.strictEqual(merged.newArea.contributions.length, 2);
    assert.ok(Math.abs(merged.totalAreaM2 - loopAreaM2(secondPoints)) < 1);
    assert.strictEqual(merged.stolenAreaM2, 0);
  });

  describe('stealing from another player', () => {
    /** B owns a square; A runs a loop over its right half. */
    function partialSteal() {
      const bArea = claim({
        newLoopPoints: square(0, 0, 2),
        userId: 'B',
        sessionId: 'sb',
        sessionData: {durationMs: 1000, avgPaceMinPerKm: 6, startLocality: 'Milan'},
      }).newArea;
      const bBefore = storedAreaM2(bArea.polygon);

      const aPoints = square(2, 0, 2);
      const steal = claim({
        newLoopPoints: aPoints,
        sessionId: 'sa',
        candidates: [candidateFromArea('sb_0', 'B', bArea, bArea.contributions, 500)],
        now: 2000,
      });

      return {bArea, bBefore, aPoints, steal};
    }

    test('the overlapped part changes hands and the rest stays theirs', () => {
      const {bBefore, aPoints, steal} = partialSteal();

      assert.strictEqual(steal.deletes.length, 0, 'A had nothing of its own to absorb');
      assert.strictEqual(steal.otherOwnerUpdates.length, 1);
      assert.strictEqual(steal.otherOwnerUpdates[0].id, 'sb_0');
      assert.ok(!steal.otherOwnerUpdates[0].deleted,
          'B keeps the half A did not run over');

      const bAfter = storedAreaM2(steal.otherOwnerUpdates[0].polygon);
      assert.ok(bAfter < bBefore, "B's ground should have shrunk");
      assert.ok(bAfter > 0, 'B should still hold the untouched half');

      assert.ok(Math.abs(steal.totalAreaM2 - loopAreaM2(aPoints)) < 1,
          "totalAreaM2 is A's own new loop, regardless of who owned it before");
      assert.ok(Math.abs(steal.stolenAreaM2 - (bBefore - bAfter)) < 1,
          "stolenAreaM2 should equal B's exact loss");
    });

    test('running over all of it wipes the other player out', () => {
      const {bArea, steal} = partialSteal();
      const bRemaining = storedAreaM2(steal.otherOwnerUpdates[0].polygon);

      const enginePoints = square(2, 0, 6);
      const engulf = claim({
        newLoopPoints: enginePoints,
        sessionId: 'sa2',
        candidates: [
          candidateFromArea('sb_0', 'B',
              {polygon: steal.otherOwnerUpdates[0].polygon}, bArea.contributions, 500),
          candidateFromArea('sa_0', 'A', steal.newArea, steal.newArea.contributions, 2000),
        ],
        now: 3000,
      });

      assert.deepStrictEqual(engulf.deletes, ['sa_0'], "A's own prior area is absorbed");
      assert.strictEqual(engulf.otherOwnerUpdates.length, 1);
      assert.strictEqual(engulf.otherOwnerUpdates[0].deleted, true, 'B is wiped out');
      assert.ok(Math.abs(engulf.stolenAreaM2 - bRemaining) < 1,
          'a wipe-out still credits exactly what B actually held');
      assert.ok(Math.abs(engulf.totalAreaM2 - loopAreaM2(enginePoints)) < 1);
    });
  });
});

// ── Coverage the verify script did not have ────────────────────────────────

describe('the two passes run in the documented order', () => {
  // The subtlest invariant in the file, and the one with no test until now.
  //
  // Pass 1 unions the claiming user's own overlapping areas into the new
  // loop; pass 2 subtracts *that grown shape* from other owners. Reverse the
  // order — or subtract the raw loop instead of the merged one — and ground
  // that only becomes contested *because* of the same-owner merge is silently
  // left with its old owner.
  //
  // Laid out on one line, all squares halfSize 1 at y = 0:
  //   A's new loop   x ∈ [-1, 1]
  //   A's own area   x ∈ [0.5, 2.5]   (overlaps the new loop)
  //   B's area       x ∈ [2, 4]       (overlaps A's *existing* area only)
  // The raw new loop never reaches B. The union does.
  function layout() {
    const aExisting = claim({
      newLoopPoints: square(1.5, 0, 1),
      sessionId: 'a-old',
    }).newArea;

    const bArea = claim({
      newLoopPoints: square(3, 0, 1),
      userId: 'B',
      sessionId: 'sb',
    }).newArea;

    return {aExisting, bArea};
  }

  test("a same-owner merge that newly reaches another player's ground takes it", () => {
    const {aExisting, bArea} = layout();
    const bBefore = storedAreaM2(bArea.polygon);

    const result = claim({
      newLoopPoints: square(0, 0, 1),
      sessionId: 'a-new',
      candidates: [
        candidateFromArea('a-old_0', 'A', aExisting, aExisting.contributions, 500),
        candidateFromArea('sb_0', 'B', bArea, bArea.contributions, 600),
      ],
      now: 2000,
    });

    assert.deepStrictEqual(result.deletes, ['a-old_0']);
    assert.strictEqual(result.otherOwnerUpdates.length, 1,
        "B must be affected: the merged shape overlaps B even though the raw loop does not");

    const bAfter = result.otherOwnerUpdates[0].deleted
      ? 0
      : storedAreaM2(result.otherOwnerUpdates[0].polygon);
    assert.ok(bAfter < bBefore, "B should have lost the contested strip");
    assert.ok(result.stolenAreaM2 > 0,
        'the loss must be credited, or the thief gets the ground without the XP');
  });

  test('the raw loop alone would not have reached that player', () => {
    // Guards the test above: proves the geometry really does depend on the
    // union, so a passing result cannot be a coincidence of overlapping
    // squares.
    const {bArea} = layout();

    const withoutOwnArea = claim({
      newLoopPoints: square(0, 0, 1),
      sessionId: 'a-new',
      candidates: [candidateFromArea('sb_0', 'B', bArea, bArea.contributions, 600)],
      now: 2000,
    });

    assert.strictEqual(withoutOwnArea.otherOwnerUpdates.length, 0);
    assert.strictEqual(withoutOwnArea.stolenAreaM2, 0);
  });
});

describe('candidates that do not actually touch', () => {
  // The geohash query that produces `candidates` is bounding-box based, so it
  // returns near misses by design; `computeClaim` is what filters them out.
  test('a nearby but non-overlapping area of your own is left alone', () => {
    const mine = claim({newLoopPoints: square(50, 50, 1), sessionId: 'far'}).newArea;

    const result = claim({
      newLoopPoints: square(0, 0, 1),
      sessionId: 's2',
      candidates: [candidateFromArea('far_0', 'A', mine, mine.contributions, 500)],
    });

    assert.deepStrictEqual(result.deletes, [], 'a false positive must not delete a real area');
    assert.strictEqual(result.newArea.contributions.length, 1,
        "the untouched area's history must not be merged in");
  });

  test("a nearby but non-overlapping area of another player is untouched", () => {
    const theirs = claim({
      newLoopPoints: square(50, 50, 1), userId: 'B', sessionId: 'sb',
    }).newArea;

    const result = claim({
      newLoopPoints: square(0, 0, 1),
      candidates: [candidateFromArea('sb_0', 'B', theirs, theirs.contributions, 500)],
    });

    assert.deepStrictEqual(result.otherOwnerUpdates, []);
    assert.strictEqual(result.stolenAreaM2, 0);
  });
});

describe('stealing from several players at once', () => {
  test('every overlapped owner is updated and all losses are credited', () => {
    const b = claim({newLoopPoints: square(-1.5, 0, 1), userId: 'B', sessionId: 'sb'}).newArea;
    const c = claim({newLoopPoints: square(1.5, 0, 1), userId: 'C', sessionId: 'sc'}).newArea;
    const before = storedAreaM2(b.polygon) + storedAreaM2(c.polygon);

    const result = claim({
      newLoopPoints: square(0, 0, 1.2),
      candidates: [
        candidateFromArea('sb_0', 'B', b, b.contributions, 500),
        candidateFromArea('sc_0', 'C', c, c.contributions, 500),
      ],
      now: 2000,
    });

    assert.strictEqual(result.otherOwnerUpdates.length, 2);
    assert.deepStrictEqual(
        result.otherOwnerUpdates.map((u) => u.id).sort(), ['sb_0', 'sc_0']);

    const after = result.otherOwnerUpdates.reduce(
        (sum, u) => sum + (u.deleted ? 0 : storedAreaM2(u.polygon)), 0);
    assert.ok(Math.abs(result.stolenAreaM2 - (before - after)) < 1,
        'stolenAreaM2 must be the sum across every victim, not just the last one');
  });
});

describe('contribution history', () => {
  test(`is capped at MAX_CONTRIBUTIONS (${geo.MAX_CONTRIBUTIONS})`, () => {
    // Unbounded, this array grows once per run forever and eventually pushes
    // the document past Firestore's 1 MiB limit, at which point the claim
    // stops being writable at all.
    const many = Array.from({length: geo.MAX_CONTRIBUTIONS + 5}, (_, i) => ({
      sessionId: `old-${i}`,
      durationMs: 1000,
      avgPaceMinPerKm: 6,
      conquestDateMillis: i, // oldest first
    }));
    const mine = claim({newLoopPoints: square(0, 0, 1)}).newArea;

    const result = claim({
      newLoopPoints: square(0, 0, 1),
      sessionId: 'newest',
      candidates: [candidateFromArea('s1_0', 'A', mine, many, 500)],
      now: 999999,
    });

    assert.strictEqual(result.newArea.contributions.length, geo.MAX_CONTRIBUTIONS);
  });

  test('keeps the most recent runs and drops the oldest', () => {
    const many = Array.from({length: geo.MAX_CONTRIBUTIONS + 5}, (_, i) => ({
      sessionId: `old-${i}`,
      durationMs: 1000,
      avgPaceMinPerKm: 6,
      conquestDateMillis: i,
    }));
    const mine = claim({newLoopPoints: square(0, 0, 1)}).newArea;

    const result = claim({
      newLoopPoints: square(0, 0, 1),
      sessionId: 'newest',
      candidates: [candidateFromArea('s1_0', 'A', mine, many, 500)],
      now: 999999,
    });

    const kept = result.newArea.contributions;
    assert.strictEqual(kept[0].sessionId, 'newest', 'this run is the most recent');
    assert.ok(!kept.some((c) => c.sessionId === 'old-0'),
        'the oldest run should have been dropped, not a recent one');

    const times = kept.map((c) => c.conquestDateMillis);
    assert.deepStrictEqual(times, [...times].sort((a, b) => b - a),
        'newest first');
  });
});

describe('createdAt of a merged area', () => {
  test('keeps the earliest absorbed area, so a merge does not look new', () => {
    // The area's age is what "held since" is drawn from; taking the newest
    // would reset a long-held territory's clock on every re-run.
    const older = claim({newLoopPoints: square(0, 0, 1), sessionId: 'old'}).newArea;
    const newer = claim({newLoopPoints: square(1, 0, 1), sessionId: 'mid'}).newArea;

    const result = claim({
      newLoopPoints: square(0.5, 0, 1.2),
      sessionId: 'now',
      candidates: [
        candidateFromArea('old_0', 'A', older, older.contributions, 200),
        candidateFromArea('mid_0', 'A', newer, newer.contributions, 900),
      ],
      now: 5000,
    });

    assert.strictEqual(result.newArea.earliestCreatedAtMillis, 200);
  });

  test('is null when nothing was absorbed', () => {
    // index.js turns null into serverTimestamp() — a genuinely new area.
    const result = claim({newLoopPoints: square(0, 0, 1)});
    assert.strictEqual(result.newArea.earliestCreatedAtMillis, null);
  });
});

describe('re-processing the same loop', () => {
  test('does not schedule the area it is about to write for deletion', () => {
    // `areaId` is deterministic (`${sessionId}_${loopIndex}`), so a retried
    // transaction sees its own previous output as a candidate. Deleting it
    // and re-creating it in the same batch is at best wasted work and at
    // worst ordering-dependent.
    const mine = claim({newLoopPoints: square(0, 0, 1)}).newArea;

    const result = claim({
      newLoopPoints: square(0, 0, 1),
      sessionId: 's1',
      loopIndex: 0,
      candidates: [candidateFromArea('s1_0', 'A', mine, mine.contributions, 500)],
      now: 2000,
    });

    assert.strictEqual(result.areaId, 's1_0');
    assert.deepStrictEqual(result.deletes, [],
        'the doc being written must never appear in its own delete list');
  });
});
