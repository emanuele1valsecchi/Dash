const {test, describe} = require('node:test');
const assert = require('node:assert');

const cascade = require('../routeCascade');
const {CALORIES_PER_KM} = require('../estimates');

// What happens to a user's routes when they delete their account.
//
// This is the one place in the codebase where getting a branch wrong is
// *unrecoverable*: too eager and other users lose routes they favourited;
// too cautious and a deleted user's measured performance stays on a public
// route forever. Neither can be undone, and neither raises an error.
//
// Ported from `_verify_routeCascade.js` (13 checks), plus the boundary cases
// that script did not cover.

describe('telling a shared route from an owned one', () => {
  // Ownership is the discriminator rather than the presence of
  // `sourceSessionId`, because a route favourited under the pre-sharing
  // scheme is an *owned* copy that also carries that field.
  test('an explicit null owner is shared', () => {
    assert.strictEqual(cascade.isSharedRoute({userId: null}), true);
  });

  test('a missing userId key is shared', () => {
    assert.strictEqual(cascade.isSharedRoute({}), true);
  });

  test('a route with an owner is not shared', () => {
    assert.strictEqual(cascade.isSharedRoute({userId: 'someone'}), false);
  });

  test('a legacy favourited copy is owned, not shared', () => {
    // Carries sourceSessionId but still has an owner — must not be mistaken
    // for the canonical shared copy and left behind.
    assert.strictEqual(
        cascade.isSharedRoute({userId: 'someone', sourceSessionId: 's1'}), false);
  });

  test('a missing route is not shared', () => {
    assert.strictEqual(cascade.isSharedRoute(null), false);
    assert.strictEqual(cascade.isSharedRoute(undefined), false);
  });

  test('an empty-string owner is treated as owned', () => {
    // Not in the original script. '' is falsy, so a looser check would call
    // this shared and leave a route behind that nobody can reach.
    assert.strictEqual(cascade.isSharedRoute({userId: ''}), false);
  });
});

describe('scrubbing a shared route of the deleted runner', () => {
  test('replaces measured values with planned estimates', () => {
    const stats = cascade.anonymizedRouteStats({distanceMeters: 5000});

    assert.strictEqual(stats.estimatedTimeMin, 5 * cascade.PLANNED_MIN_PER_KM);
    assert.strictEqual(stats.estimatedCalories, 5 * CALORIES_PER_KM);
  });

  test('the result never depends on the run\'s real measurements', () => {
    // The whole point: two routes of the same length must be indistinguishable
    // afterwards, however fast the deleted user actually ran them.
    const fast = cascade.anonymizedRouteStats({
      distanceMeters: 5000, estimatedTimeMin: 18, estimatedCalories: 700,
    });
    const slow = cascade.anonymizedRouteStats({
      distanceMeters: 5000, estimatedTimeMin: 62, estimatedCalories: 120,
    });

    assert.deepStrictEqual(fast, slow);
  });

  test('does not carry the source session pointer through', () => {
    // That document is deleted with the account; a surviving pointer would
    // dangle.
    const stats = cascade.anonymizedRouteStats({
      distanceMeters: 5000, sourceSessionId: 's1',
    });

    assert.ok(!('sourceSessionId' in stats));
  });

  test('a missing or zero distance degrades to zero, not NaN', () => {
    // A NaN written to Firestore poisons the document for every reader.
    for (const route of [{}, null, undefined, {distanceMeters: 0},
      {distanceMeters: null}, {distanceMeters: 'not a number'}]) {
      const stats = cascade.anonymizedRouteStats(route);
      assert.strictEqual(stats.estimatedTimeMin, 0,
          `time went non-zero for ${JSON.stringify(route)}`);
      assert.strictEqual(stats.estimatedCalories, 0,
          `calories went non-zero for ${JSON.stringify(route)}`);
      assert.ok(Number.isFinite(stats.estimatedTimeMin));
      assert.ok(Number.isFinite(stats.estimatedCalories));
    }
  });

  test('a numeric string distance is still read as a distance', () => {
    // Not in the original script. Firestore has held both over this field's
    // life; `Number()` accepts the string form, and this pins that.
    assert.deepStrictEqual(
        cascade.anonymizedRouteStats({distanceMeters: '5000'}),
        cascade.anonymizedRouteStats({distanceMeters: 5000}));
  });
});

describe('deciding what to do with an owned route', () => {
  test('an unpublished owned route is deleted', () => {
    // Nobody but the owner could ever read it, so keeping it would preserve
    // personal data no one can see.
    assert.strictEqual(
        cascade.ownedRouteDisposition({isPublic: false}), 'delete');
  });

  test('a route with no isPublic field is deleted', () => {
    // Absent means private — see the per-route visibility notes in CLAUDE.md.
    assert.strictEqual(cascade.ownedRouteDisposition({}), 'delete');
  });

  test('a published route is anonymized, never deleted', () => {
    // Other users may have favourited it; destroying it takes their route
    // away too.
    assert.strictEqual(
        cascade.ownedRouteDisposition({isPublic: true}), 'anonymize');
  });

  test('only a real boolean true counts as published', () => {
    // A truthy-but-not-true value must not be enough to preserve a route
    // that was never actually shared.
    for (const value of ['true', 1, {}, [], 'yes']) {
      assert.strictEqual(
          cascade.ownedRouteDisposition({isPublic: value}), 'delete',
          `${JSON.stringify(value)} should not count as published`);
    }
  });

  test('a missing route is deleted rather than throwing', () => {
    // Not in the original script. Mid-cascade this is reachable if a document
    // vanishes between read and decision; throwing would strand the deletion
    // half-done.
    assert.strictEqual(cascade.ownedRouteDisposition(null), 'delete');
    assert.strictEqual(cascade.ownedRouteDisposition(undefined), 'delete');
  });
});

describe('the planned-route constants', () => {
  test('match the client\'s own estimates', () => {
    // A scrubbed route should read exactly like a hand-planned route of the
    // same length. If RouteCreatePage's constants move and these do not, an
    // anonymized route becomes distinguishable from a planned one again.
    assert.strictEqual(cascade.PLANNED_KCAL_PER_KM, CALORIES_PER_KM);
    assert.ok(cascade.PLANNED_MIN_PER_KM > 0);
  });
});
