// Standalone check of geo.js's sessionLoopsAreaM2 — the area figure XP's
// area term is built from. Run with `node _verify_session_area.js`. Not part
// of the deployed function (see firebase.json's functions `ignore` list).
//
// The property under test: ground a single session covers more than once is
// paid for once. Summing each loop's own raw area used to charge it twice,
// which a field test caught by drawing one square inside another and watching
// the reported area grow when no new ground had been claimed.

const assert = require('assert');
const turf = require('@turf/turf');
const geo = require('./geo');

/** Axis-aligned square of side `2 * half`, centred on (cx, cy). */
function square(cx, cy, half) {
  return [
    {latitude: cy - half, longitude: cx - half},
    {latitude: cy - half, longitude: cx + half},
    {latitude: cy + half, longitude: cx + half},
    {latitude: cy + half, longitude: cx - half},
  ];
}

function areaOf(points) {
  return turf.area(geo.loopToTurfPolygon(points));
}

/** Within 0.1% — the union is exact, so this only absorbs float noise. */
function close(actual, expected, label) {
  const tolerance = Math.max(1, Math.abs(expected) * 0.001);
  assert.ok(
      Math.abs(actual - expected) < tolerance,
      `${label}: expected ~${expected}, got ${actual}`
  );
}

// ── 1. Nothing at all ───────────────────────────────────────────────────────
{
  assert.strictEqual(geo.sessionLoopsAreaM2([]), 0, 'no loops -> 0');
  assert.strictEqual(
      geo.sessionLoopsAreaM2([null, undefined, [], [{latitude: 0, longitude: 0}]]),
      0,
      'degenerate loops -> 0'
  );
  console.log('1. empty and degenerate input: OK');
}

// ── 2. A single loop is just its own area ───────────────────────────────────
{
  const one = square(0, 0, 1);
  close(geo.sessionLoopsAreaM2([one]), areaOf(one), 'single loop');
  console.log('2. single loop: OK');
}

// ── 3. Separate blocks stay additive ────────────────────────────────────────
{
  // Far apart, so turf.union yields a MultiPolygon rather than merging them.
  const a = square(0, 0, 1);
  const b = square(10, 10, 1);

  close(
      geo.sessionLoopsAreaM2([a, b]),
      areaOf(a) + areaOf(b),
      'two disjoint blocks'
  );
  console.log('3. disjoint blocks remain additive: OK');
}

// ── 4. The reported bug: a loop drawn inside another ────────────────────────
{
  const outer = square(0, 0, 2);
  const inner = square(0, 0, 1); // wholly inside `outer`

  const summed = areaOf(outer) + areaOf(inner);
  const union = geo.sessionLoopsAreaM2([outer, inner]);

  close(union, areaOf(outer), 'inscribed loop adds nothing');
  assert.ok(
      union < summed * 0.9,
      `union (${union}) must be well under the old sum (${summed})`
  );
  // Order must not matter — the inner loop could be run first.
  close(geo.sessionLoopsAreaM2([inner, outer]), areaOf(outer),
      'inscribed loop, reversed order');
  console.log('4. inscribed loop charged once: OK');
}

// ── 5. Partial overlap is charged once too, not just containment ────────────
{
  // Two unit squares offset by half their width: they share a quarter of the
  // combined footprint.
  const a = square(0, 0, 1);
  const b = square(1, 0, 1);

  const union = geo.sessionLoopsAreaM2([a, b]);
  const summed = areaOf(a) + areaOf(b);
  const expected = turf.area(turf.union(turf.featureCollection([
    geo.loopToTurfPolygon(a),
    geo.loopToTurfPolygon(b),
  ])));

  close(union, expected, 'partial overlap');
  assert.ok(union < summed, 'partial overlap must cost less than the sum');
  assert.ok(union > areaOf(a), 'but more than either loop alone');
  console.log('5. partial overlap charged once: OK');
}

// ── 6. Re-running the identical loop claims nothing new ─────────────────────
{
  const a = square(0, 0, 1);
  close(geo.sessionLoopsAreaM2([a, a]), areaOf(a), 'same loop twice');
  console.log('6. identical loop twice: OK');
}

// ── 7. Adjacent blocks sharing a street ─────────────────────────────────────
{
  // The shape from the earlier field report: two squares sharing one side.
  // They overlap in nothing but that border, so the total is still the sum.
  const a = square(0, 0, 1);
  const b = square(2, 0, 1);

  close(geo.sessionLoopsAreaM2([a, b]), areaOf(a) + areaOf(b),
      'blocks sharing only a border');
  console.log('7. adjacent blocks still counted in full: OK');
}

console.log('\nAll scenarios passed.');
