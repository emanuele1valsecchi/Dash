/**
 * Standalone checks for routeCascade.js — run with `node _verify_routeCascade.js`
 * from the functions directory. Not deployed (see firebase.json's functions
 * ignore list), and needs no live or emulated Firestore.
 *
 * These exist because account deletion is irreversible: every assertion below
 * pins a branch where getting it wrong permanently destroys either a deleted
 * user's privacy or other users' saved routes.
 */

const assert = require("assert");
const {
  isSharedRoute,
  anonymizedRouteStats,
  ownedRouteDisposition,
} = require("./routeCascade");

let passed = 0;
function check(label, fn) {
  fn();
  passed++;
  console.log(`  ok  ${label}`);
}

console.log("isSharedRoute");

check("an explicit null owner is shared", () => {
  assert.strictEqual(isSharedRoute({ userId: null }), true);
});

check("a missing userId key is shared", () => {
  assert.strictEqual(isSharedRoute({ distanceMeters: 100 }), true);
});

check("a route with an owner is not shared", () => {
  assert.strictEqual(isSharedRoute({ userId: "abc123" }), false);
});

check("a legacy favourited copy is owned, not shared", () => {
  // Favourited before routes became shared: an owned copy that still carries
  // sourceSessionId. Treating it as shared would rewrite it in place instead
  // of deleting it with the rest of its owner's data.
  assert.strictEqual(
    isSharedRoute({ userId: "abc123", sourceSessionId: "sess1" }),
    false
  );
});

check("a missing route is not shared", () => {
  assert.strictEqual(isSharedRoute(null), false);
  assert.strictEqual(isSharedRoute(undefined), false);
});

console.log("anonymizedRouteStats");

check("replaces measured values with planned estimates", () => {
  // 5 km -> 45 min, 350 kcal at the planned constants.
  const stats = anonymizedRouteStats({ distanceMeters: 5000 });
  assert.strictEqual(stats.estimatedTimeMin, 45);
  assert.strictEqual(stats.estimatedCalories, 350);
});

check("result never depends on the run's real measurements", () => {
  // Same distance, wildly different actual performance: the scrubbed output
  // must be identical, or the deleted user's pace is still inferable.
  const fast = anonymizedRouteStats({
    distanceMeters: 5000,
    estimatedTimeMin: 18,
    estimatedCalories: 500,
  });
  const slow = anonymizedRouteStats({
    distanceMeters: 5000,
    estimatedTimeMin: 62,
    estimatedCalories: 210,
  });
  assert.deepStrictEqual(fast, slow);
});

check("does not carry the source session pointer through", () => {
  const stats = anonymizedRouteStats({
    distanceMeters: 5000,
    sourceSessionId: "sess1",
  });
  assert.strictEqual(stats.sourceSessionId, undefined);
});

check("a missing or zero distance degrades to zero, not NaN", () => {
  assert.deepStrictEqual(anonymizedRouteStats({}), {
    estimatedTimeMin: 0,
    estimatedCalories: 0,
  });
  assert.deepStrictEqual(anonymizedRouteStats({ distanceMeters: "oops" }), {
    estimatedTimeMin: 0,
    estimatedCalories: 0,
  });
});

console.log("ownedRouteDisposition");

check("an unpublished owned route is deleted", () => {
  assert.strictEqual(
    ownedRouteDisposition({ userId: "abc", isPublic: false }),
    "delete"
  );
});

check("a route with no isPublic field is deleted", () => {
  assert.strictEqual(ownedRouteDisposition({ userId: "abc" }), "delete");
});

check("a published route is anonymized, never deleted", () => {
  assert.strictEqual(
    ownedRouteDisposition({ userId: "abc", isPublic: true }),
    "anonymize"
  );
});

check("only a real boolean true counts as published", () => {
  // A truthy-but-not-true value must not be enough to preserve a route the
  // user never actually published.
  assert.strictEqual(
    ownedRouteDisposition({ userId: "abc", isPublic: "true" }),
    "delete"
  );
  assert.strictEqual(
    ownedRouteDisposition({ userId: "abc", isPublic: 1 }),
    "delete"
  );
});

console.log(`\n${passed} checks passed.`);
