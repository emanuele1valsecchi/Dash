import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from '@firebase/rules-unit-testing';

const here = dirname(fileURLToPath(import.meta.url));
const rulesPath = join(here, '..', '..', 'firestore.rules');

/**
 * Builds a set of helpers bound to their own emulator project.
 *
 * **Each test file must pass a distinct [namespace].** `node --test` runs test
 * files in parallel against the one shared emulator, and every file clears the
 * database between tests — so with a shared project id, one file wipes
 * another's seeded documents mid-test and the failures look like rules bugs.
 * A project id per file isolates the data without giving up the parallelism.
 *
 * The rules are read from the real `firestore.rules` at the repo root — not a
 * copy — so these tests fail the moment the deployed file drifts from what
 * they assert.
 */
export function rulesSuite(namespace) {
  let testEnv;

  async function getTestEnv() {
    if (!testEnv) {
      testEnv = await initializeTestEnvironment({
        projectId: `dash-rules-${namespace}`,
        firestore: {
          rules: readFileSync(rulesPath, 'utf8'),
          host: '127.0.0.1',
          port: 8080,
        },
      });
    }
    return testEnv;
  }

  return {
    /** Firestore as a signed-in user. */
    async asUser(uid) {
      const env = await getTestEnv();
      return env.authenticatedContext(uid).firestore();
    },

    /** Firestore as a signed-out visitor. */
    async asAnon() {
      const env = await getTestEnv();
      return env.unauthenticatedContext().firestore();
    },

    /**
     * Seeds documents with the rules switched off.
     *
     * Needed because most collections here are deliberately not
     * client-writable at all: to test that user B cannot update user A's
     * route, the route has to exist first, and no client is allowed to create
     * it in a way the rules permit. This is the emulator's supported escape
     * hatch, and confining it to setup keeps the assertions honest.
     */
    async seed(fn) {
      const env = await getTestEnv();
      await env.withSecurityRulesDisabled(async (ctx) => {
        await fn(ctx.firestore());
      });
    },

    async clearData() {
      const env = await getTestEnv();
      await env.clearFirestore();
    },

    async cleanup() {
      if (testEnv) {
        await testEnv.cleanup();
        testEnv = undefined;
      }
    },
  };
}

export { assertFails, assertSucceeds };

/** A plausible route document owned by [uid]. */
export function routeDoc(uid, overrides = {}) {
  return {
    userId: uid,
    name: 'Morning loop',
    waypoints: [],
    routePolyline: [],
    distanceMeters: 4200,
    estimatedTimeMin: 38,
    estimatedCalories: 294,
    isLoop: true,
    loopAreaM2: 120000,
    isPublic: false,
    startLocality: 'Seregno',
    ...overrides,
  };
}

/** A plausible completed-run document owned by [uid]. */
export function sessionDoc(uid, overrides = {}) {
  return {
    userId: uid,
    name: 'Morning run',
    distanceMeters: 4200,
    durationMs: 1440000,
    avgPaceMinPerKm: 5.7,
    elevationDifferenceMeters: 32,
    loopsCompleted: 0,
    path: [],
    closedLoops: [],
    startLocality: 'Seregno',
    pointsEarned: 0,
    ...overrides,
  };
}
