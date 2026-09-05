const {test, describe} = require('node:test');
const assert = require('node:assert');

const {square, loopAreaM2, turf, geo} = require('./helpers');

// `sessionLoopsAreaM2` is the area figure XP's area term is built from.
//
// The property under test: ground a single session covers more than once is
// paid for once. Summing each loop's own raw area used to charge it twice,
// which a field test caught — drawing one square inside another made the
// reported area grow when no new ground had been claimed.
//
// Ported from `_verify_session_area.js`.

/** Within 0.1% — the union is exact, so this only absorbs float noise. */
function close(actual, expected, label) {
  const tolerance = Math.max(1, Math.abs(expected) * 0.001);
  assert.ok(
      Math.abs(actual - expected) < tolerance,
      `${label}: expected ~${expected}, got ${actual}`,
  );
}

describe('input that claims nothing', () => {
  test('no loops at all is zero', () => {
    assert.strictEqual(geo.sessionLoopsAreaM2([]), 0);
  });

  test('degenerate loops are skipped rather than throwing', () => {
    // A run can end with fewer than three accepted fixes; that is not ground.
    assert.strictEqual(
        geo.sessionLoopsAreaM2([null, undefined, [], [{latitude: 0, longitude: 0}]]),
        0,
    );
  });

  test('a valid loop still counts alongside degenerate ones', () => {
    // Guards the skip above: it must drop the bad entries, not abandon the
    // whole session's area the moment one is malformed.
    const good = square(0, 0, 1);
    close(geo.sessionLoopsAreaM2([null, good, []]), loopAreaM2(good),
        'one good loop among junk');
  });
});

describe('loops that do not overlap', () => {
  test('a single loop is just its own area', () => {
    const one = square(0, 0, 1);
    close(geo.sessionLoopsAreaM2([one]), loopAreaM2(one), 'single loop');
  });

  test('separate blocks stay additive', () => {
    // Far apart, so turf.union yields a MultiPolygon rather than merging.
    const a = square(0, 0, 1);
    const b = square(10, 10, 1);
    close(geo.sessionLoopsAreaM2([a, b]), loopAreaM2(a) + loopAreaM2(b),
        'two disjoint blocks');
  });

  test('blocks sharing only a street are still counted in full', () => {
    // From a field report: two squares sharing one side overlap in nothing
    // but that border, so the total is still the sum.
    const a = square(0, 0, 1);
    const b = square(2, 0, 1);
    close(geo.sessionLoopsAreaM2([a, b]), loopAreaM2(a) + loopAreaM2(b),
        'blocks sharing only a border');
  });
});

describe('overlapping loops are charged once', () => {
  test('a loop drawn inside another adds nothing', () => {
    // The originally reported bug.
    const outer = square(0, 0, 2);
    const inner = square(0, 0, 1);

    const union = geo.sessionLoopsAreaM2([outer, inner]);
    close(union, loopAreaM2(outer), 'inscribed loop adds nothing');
    assert.ok(union < (loopAreaM2(outer) + loopAreaM2(inner)) * 0.9,
        'must be well under the old naive sum');
  });

  test('order does not matter — the inner loop may be run first', () => {
    const outer = square(0, 0, 2);
    const inner = square(0, 0, 1);
    close(geo.sessionLoopsAreaM2([inner, outer]), loopAreaM2(outer),
        'inscribed loop, reversed order');
  });

  test('partial overlap is charged once too, not just containment', () => {
    const a = square(0, 0, 1);
    const b = square(1, 0, 1);

    const union = geo.sessionLoopsAreaM2([a, b]);
    const expected = turf.area(turf.union(turf.featureCollection([
      geo.loopToTurfPolygon(a),
      geo.loopToTurfPolygon(b),
    ])));

    close(union, expected, 'partial overlap');
    assert.ok(union < loopAreaM2(a) + loopAreaM2(b),
        'must cost less than the sum');
    assert.ok(union > loopAreaM2(a), 'but more than either loop alone');
  });

  test('re-running the identical loop claims nothing new', () => {
    const a = square(0, 0, 1);
    close(geo.sessionLoopsAreaM2([a, a]), loopAreaM2(a), 'same loop twice');
  });

  test('three loops chained along a line are unioned, not summed', () => {
    // Not in the original script: two-loop cases can pass with a pairwise
    // union that never accumulates. This needs the running union to carry
    // forward across every iteration.
    const a = square(0, 0, 1);
    const b = square(1, 0, 1);
    const c = square(2, 0, 1);

    const union = geo.sessionLoopsAreaM2([a, b, c]);
    const expected = turf.area(turf.union(turf.featureCollection([
      geo.loopToTurfPolygon(a),
      geo.loopToTurfPolygon(b),
      geo.loopToTurfPolygon(c),
    ])));

    close(union, expected, 'three chained loops');
    assert.ok(union < loopAreaM2(a) * 3, 'the shared strips must not be paid twice');
  });
});
