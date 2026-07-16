// Standalone check of geo.js's computeClaim against the 4 scenarios from
// the design discussion. Run with `node _verify_geo.js`. Not part of the
// deployed function — delete before/after use.

const assert = require('assert');
const geo = require('./geo');

function square(cx, cy, halfSize) {
  return [
    {latitude: cy - halfSize, longitude: cx - halfSize},
    {latitude: cy - halfSize, longitude: cx + halfSize},
    {latitude: cy + halfSize, longitude: cx + halfSize},
    {latitude: cy + halfSize, longitude: cx - halfSize},
  ];
}

function totalOuterRings(area) {
  return area.polygon.length;
}

function candidateFromArea(id, userId, area, contributions, createdAtMillis) {
  return {
    id,
    userId,
    polygon: area.polygon,
    contributions: contributions || area.contributions,
    createdAtMillis: createdAtMillis != null ? createdAtMillis : area.earliestCreatedAtMillis,
  };
}

// ── 1. Free territory: A claims a fresh area ───────────────────────────────
{
  const result = geo.computeClaim({
    newLoopPoints: square(0, 0, 1),
    userId: 'A',
    sessionId: 's1',
    loopIndex: 0,
    candidates: [],
    sessionData: {durationMs: 600000, avgPaceMinPerKm: 6, startLocality: 'Milan'},
    now: 1000,
  });
  assert.strictEqual(result.deletes.length, 0);
  assert.strictEqual(result.otherOwnerUpdates.length, 0);
  assert.strictEqual(totalOuterRings(result.newArea), 1);
  assert.strictEqual(result.newArea.contributions.length, 1);
  console.log('1. free territory: OK');
}

// ── 2. A's new loop fully inside A's own existing area -> no visible change ─
{
  const outer = geo.computeClaim({
    newLoopPoints: square(10, 10, 5), // big area
    userId: 'A',
    sessionId: 's1',
    loopIndex: 0,
    candidates: [],
    sessionData: {durationMs: 1000, avgPaceMinPerKm: 6},
    now: 1000,
  }).newArea;

  const inner = geo.computeClaim({
    newLoopPoints: square(10, 10, 1), // small loop, fully inside the big one
    userId: 'A',
    sessionId: 's2',
    loopIndex: 0,
    candidates: [candidateFromArea('s1_0', 'A', outer, outer.contributions, 500)],
    sessionData: {durationMs: 2000, avgPaceMinPerKm: 5},
    now: 2000,
  });

  assert.deepStrictEqual(inner.deletes, ['s1_0']); // old doc absorbed
  assert.strictEqual(inner.otherOwnerUpdates.length, 0);
  assert.strictEqual(totalOuterRings(inner.newArea), 1);
  // Shape should be (numerically) unchanged from the outer square, i.e. area
  // should match the outer polygon's area, not be visually "on top of" it.
  const area1 = require('@turf/turf').area(geo.storedPolygonToTurf(outer.polygon));
  const area2 = require('@turf/turf').area(geo.storedPolygonToTurf(inner.newArea.polygon));
  assert.ok(Math.abs(area1 - area2) < 1, `expected unchanged area, got ${area1} vs ${area2}`);
  assert.strictEqual(inner.newArea.contributions.length, 2); // both runs listed
  console.log('2. fully-contained self-overlap: OK (no visible change, contributions merged)');
}

// ── 3. A's new loop partially overlaps A's own existing area -> merges into
//       one seamless shape ──────────────────────────────────────────────────
{
  const first = geo.computeClaim({
    newLoopPoints: square(0, 0, 2),
    userId: 'A',
    sessionId: 's1',
    loopIndex: 0,
    candidates: [],
    sessionData: {durationMs: 1000, avgPaceMinPerKm: 6},
    now: 1000,
  }).newArea;

  // Second loop shifted right, overlapping the first by half.
  const secondPoints = square(2, 0, 2);
  const merged = geo.computeClaim({
    newLoopPoints: secondPoints,
    userId: 'A',
    sessionId: 's2',
    loopIndex: 0,
    candidates: [candidateFromArea('s1_0', 'A', first, first.contributions, 500)],
    sessionData: {durationMs: 1500, avgPaceMinPerKm: 5.5},
    now: 2000,
  });

  assert.deepStrictEqual(merged.deletes, ['s1_0']);
  assert.strictEqual(merged.otherOwnerUpdates.length, 0);
  assert.strictEqual(totalOuterRings(merged.newArea), 1); // one seamless piece, no separate borders
  assert.strictEqual(merged.newArea.contributions.length, 2);
  console.log('3. partial self-overlap: OK (single merged polygon, contributions combined)');
}

// ── 4. A runs over part of B's area -> that part becomes A's, B keeps the
//       rest ────────────────────────────────────────────────────────────────
{
  const bArea = geo.computeClaim({
    newLoopPoints: square(0, 0, 2),
    userId: 'B',
    sessionId: 'sb',
    loopIndex: 0,
    candidates: [],
    sessionData: {durationMs: 1000, avgPaceMinPerKm: 6, startLocality: 'Milan'},
    now: 1000,
  }).newArea;

  const turf = require('@turf/turf');
  const bAreaM2Before = turf.area(geo.storedPolygonToTurf(bArea.polygon));

  // A's loop overlaps the right half of B's square only.
  const aPoints = square(2, 0, 2);
  const steal = geo.computeClaim({
    newLoopPoints: aPoints,
    userId: 'A',
    sessionId: 'sa',
    loopIndex: 0,
    candidates: [candidateFromArea('sb_0', 'B', bArea, bArea.contributions, 500)],
    sessionData: {durationMs: 800, avgPaceMinPerKm: 5},
    now: 2000,
  });

  assert.strictEqual(steal.deletes.length, 0); // A had nothing of its own to absorb
  assert.strictEqual(steal.otherOwnerUpdates.length, 1);
  assert.strictEqual(steal.otherOwnerUpdates[0].id, 'sb_0');
  assert.ok(!steal.otherOwnerUpdates[0].deleted, 'B should keep a remaining piece, not be wiped out');

  const bAreaM2After = turf.area(geo.storedPolygonToTurf(steal.otherOwnerUpdates[0].polygon));
  assert.ok(bAreaM2After < bAreaM2Before, 'B\'s remaining area should have shrunk');
  assert.ok(bAreaM2After > 0, 'B should still have some area left');
  // B's contributions untouched — still "their" run, just less ground.
  assert.strictEqual(steal.otherOwnerUpdates[0].polygon.length >= 1, true);
  console.log(`4. partial steal: OK (B ${bAreaM2Before.toFixed(1)} -> ${bAreaM2After.toFixed(1)} m^2, A gets full new loop)`);

  // ── 4b. A runs over ALL of B's (now-shrunk) area -> B is fully wiped out ──
  const engulf = geo.computeClaim({
    newLoopPoints: square(2, 0, 6), // huge loop covering everything
    userId: 'A',
    sessionId: 'sa2',
    loopIndex: 0,
    candidates: [
      candidateFromArea('sb_0', 'B', {polygon: steal.otherOwnerUpdates[0].polygon}, bArea.contributions, 500),
      candidateFromArea('sa_0', 'A', steal.newArea, steal.newArea.contributions, 2000),
    ],
    sessionData: {durationMs: 900, avgPaceMinPerKm: 4.5},
    now: 3000,
  });
  assert.deepStrictEqual(engulf.deletes, ['sa_0']); // A's own prior area absorbed via union
  assert.strictEqual(engulf.otherOwnerUpdates.length, 1);
  assert.strictEqual(engulf.otherOwnerUpdates[0].deleted, true); // B fully wiped out
  console.log('4b. full steal: OK (B\'s area deleted entirely, A\'s own prior claim absorbed)');
}

console.log('\nAll scenarios passed.');
