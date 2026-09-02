import { test, describe, before, after, beforeEach } from 'node:test';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';
import {
  rulesSuite, assertFails, assertSucceeds,
} from './helpers.js';

// Own emulator project, so parallel test files cannot clear each
// other's data. See rulesSuite().
const { asUser, asAnon, seed, clearData, cleanup } =
    rulesSuite('server');

const ALICE = 'alice';
const BOB = 'bob';

/**
 * The collections a client must never be able to write, and the fields on
 * `profiles` that decide trust.
 *
 * CLAUDE.md's "Security & performance — non-negotiable" section is mostly
 * about exactly this: points, ranking and area ownership are computed
 * server-side, and the rules — not the absence of a UI button — are what
 * enforce it.
 */
describe('server-owned data', () => {
  before(clearData);
  after(cleanup);
  beforeEach(clearData);

  describe('profiles', () => {
    test('any signed-in user may read a profile', async () => {
      await seed((db) => setDoc(doc(db, 'profiles/alice'),
        { totalPoints: 0, username: 'alice' }));
      const bob = await asUser(BOB);

      await assertSucceeds(getDoc(doc(bob, 'profiles/alice')));
    });

    test('a user may create their own profile with zero points', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(
        setDoc(doc(alice, 'profiles/alice'), { totalPoints: 0 }));
    });

    test('a user may NOT create a profile under someone else\'s uid',
      async () => {
        const alice = await asUser(ALICE);

        await assertFails(
          setDoc(doc(alice, 'profiles/bob'), { totalPoints: 0 }));
      });

    test('a user may NOT self-award points at creation', async () => {
      const alice = await asUser(ALICE);

      await assertFails(
        setDoc(doc(alice, 'profiles/alice'), { totalPoints: 5000 }));
    });

    test('a user may NOT raise their own totalPoints', async () => {
      // The headline trust value. Everything about the leaderboard rests on
      // this one line holding.
      await seed((db) => setDoc(doc(db, 'profiles/alice'), { totalPoints: 10 }));
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'profiles/alice'), { totalPoints: 99999 }));
    });

    test('a user may NOT change someone else\'s profile', async () => {
      await seed((db) => setDoc(doc(db, 'profiles/alice'), { totalPoints: 10 }));
      const bob = await asUser(BOB);

      await assertFails(
        updateDoc(doc(bob, 'profiles/alice'), { username: 'pwned' }));
    });

    test('a user may edit their own non-trust fields', async () => {
      await seed((db) => setDoc(doc(db, 'profiles/alice'), { totalPoints: 10 }));
      const alice = await asUser(ALICE);

      await assertSucceeds(
        updateDoc(doc(alice, 'profiles/alice'), { username: 'speedy' }));
    });

    test('nobody may delete a profile from the client', async () => {
      await seed((db) => setDoc(doc(db, 'profiles/alice'), { totalPoints: 0 }));
      const alice = await asUser(ALICE);

      await assertFails(deleteDoc(doc(alice, 'profiles/alice')));
    });

    describe('areaColorIndex must stay in palette range', () => {
      // Not trust-affecting the way totalPoints is, but it is read by *other*
      // users' maps, so it has to be something the renderer can accept.
      // The bound 10 is duplicated in PlayerPalette.size and functions/index.js.
      beforeEach(() => seed((db) =>
        setDoc(doc(db, 'profiles/alice'), { totalPoints: 0 })));

      test('an in-range index is accepted', async () => {
        const alice = await asUser(ALICE);

        await assertSucceeds(
          updateDoc(doc(alice, 'profiles/alice'), { areaColorIndex: 7 }));
      });

      test('zero is accepted', async () => {
        const alice = await asUser(ALICE);

        await assertSucceeds(
          updateDoc(doc(alice, 'profiles/alice'), { areaColorIndex: 0 }));
      });

      test('10 is out of range', async () => {
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'profiles/alice'), { areaColorIndex: 10 }));
      });

      test('a negative index is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'profiles/alice'), { areaColorIndex: -1 }));
      });

      test('a non-integer is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'profiles/alice'), { areaColorIndex: 'red' }));
      });
    });

    describe('badge_progress', () => {
      test('is readable by any signed-in user', async () => {
        // Widened from self-only deliberately: a public profile shows another
        // user's badges, and every such read was silently denied before.
        await seed((db) => setDoc(
          doc(db, 'profiles/alice/badge_progress/duke'),
          { progress: 1, unlocked: true }));
        const bob = await asUser(BOB);

        await assertSucceeds(
          getDoc(doc(bob, 'profiles/alice/badge_progress/duke')));
      });

      test('is not writable, even by its owner', async () => {
        // Unlocking a badge is a trust value.
        const alice = await asUser(ALICE);

        await assertFails(setDoc(
          doc(alice, 'profiles/alice/badge_progress/duke'),
          { progress: 1, unlocked: true }));
      });
    });
  });

  describe('claimedAreas', () => {
    const area = {
      userId: ALICE,
      polygon: [],
      contributions: [],
      geohash: 'u0nd',
    };

    test('any signed-in user may read the map', async () => {
      await seed((db) => setDoc(doc(db, 'claimedAreas/a1'), area));
      const bob = await asUser(BOB);

      await assertSucceeds(getDoc(doc(bob, 'claimedAreas/a1')));
    });

    test('a client may NOT claim territory for itself', async () => {
      // Area ownership is the game. Only the claim Cloud Function writes here.
      const alice = await asUser(ALICE);

      await assertFails(setDoc(doc(alice, 'claimedAreas/a1'), area));
    });

    test('a client may NOT reshape an existing area', async () => {
      await seed((db) => setDoc(doc(db, 'claimedAreas/a1'), area));
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'claimedAreas/a1'), { geohash: 'zzzz' }));
    });

    test('a client may NOT steal an area by reassigning it', async () => {
      await seed((db) => setDoc(doc(db, 'claimedAreas/a1'), area));
      const bob = await asUser(BOB);

      await assertFails(
        updateDoc(doc(bob, 'claimedAreas/a1'), { userId: BOB }));
    });

    test('the owner may delete their own area', async () => {
      await seed((db) => setDoc(doc(db, 'claimedAreas/a1'), area));
      const alice = await asUser(ALICE);

      await assertSucceeds(deleteDoc(doc(alice, 'claimedAreas/a1')));
    });

    test('another user may NOT delete it', async () => {
      await seed((db) => setDoc(doc(db, 'claimedAreas/a1'), area));
      const bob = await asUser(BOB);

      await assertFails(deleteDoc(doc(bob, 'claimedAreas/a1')));
    });
  });

  describe('userStats', () => {
    test('the owner may read their own stats', async () => {
      await seed((db) => setDoc(doc(db, 'userStats/alice'), { totalRuns: 3 }));
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, 'userStats/alice')));
    });

    test('another user may NOT read them', async () => {
      await seed((db) => setDoc(doc(db, 'userStats/alice'), { totalRuns: 3 }));
      const bob = await asUser(BOB);

      await assertFails(getDoc(doc(bob, 'userStats/alice')));
    });

    test('nobody may write them, not even their owner', async () => {
      const alice = await asUser(ALICE);

      await assertFails(
        setDoc(doc(alice, 'userStats/alice'), { totalRuns: 9999 }));
    });
  });

  describe('favoriteRoutes', () => {
    const link = {
      userId: ALICE,
      routeId: 'session-1',
      name: 'Their morning run',
      distanceMeters: 4200,
    };

    test('a client may NOT create a link — only the Cloud Function may',
      async () => {
        // A link is written together with the shared route it points at, so a
        // client-created one could reference a route that does not exist, with
        // a summary nobody verified.
        const alice = await asUser(ALICE);

        await assertFails(
          setDoc(doc(alice, 'favoriteRoutes/alice_session-1'), link));
      });

    test('the owner may rename their own favourite', async () => {
      await seed((db) =>
        setDoc(doc(db, 'favoriteRoutes/alice_session-1'), link));
      const alice = await asUser(ALICE);

      await assertSucceeds(updateDoc(
        doc(alice, 'favoriteRoutes/alice_session-1'), { name: 'My loop' }));
    });

    test('the owner may NOT repoint it at a different route', async () => {
      // Only `name` is updatable, so the denormalized summary cannot be
      // falsified and the link cannot be aimed elsewhere.
      await seed((db) =>
        setDoc(doc(db, 'favoriteRoutes/alice_session-1'), link));
      const alice = await asUser(ALICE);

      await assertFails(updateDoc(
        doc(alice, 'favoriteRoutes/alice_session-1'), { routeId: 'session-9' }));
    });

    test('the owner may NOT falsify the denormalized distance', async () => {
      await seed((db) =>
        setDoc(doc(db, 'favoriteRoutes/alice_session-1'), link));
      const alice = await asUser(ALICE);

      await assertFails(updateDoc(
        doc(alice, 'favoriteRoutes/alice_session-1'), { distanceMeters: 1 }));
    });

    test('the owner may un-favourite', async () => {
      await seed((db) =>
        setDoc(doc(db, 'favoriteRoutes/alice_session-1'), link));
      const alice = await asUser(ALICE);

      await assertSucceeds(
        deleteDoc(doc(alice, 'favoriteRoutes/alice_session-1')));
    });

    test('another user may NOT delete someone\'s favourite', async () => {
      await seed((db) =>
        setDoc(doc(db, 'favoriteRoutes/alice_session-1'), link));
      const bob = await asUser(BOB);

      await assertFails(
        deleteDoc(doc(bob, 'favoriteRoutes/alice_session-1')));
    });
  });

  describe('notifications', () => {
    const note = { userId: ALICE, title: 'You were overtaken', isRead: false };

    test('the recipient may read their own', async () => {
      await seed((db) => setDoc(doc(db, 'notifications/n1'), note));
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, 'notifications/n1')));
    });

    test('another user may NOT read them', async () => {
      await seed((db) => setDoc(doc(db, 'notifications/n1'), note));
      const bob = await asUser(BOB);

      await assertFails(getDoc(doc(bob, 'notifications/n1')));
    });

    test('a client may NOT create one', async () => {
      const alice = await asUser(ALICE);

      await assertFails(setDoc(doc(alice, 'notifications/n1'), note));
    });

    test('the recipient may mark it read', async () => {
      await seed((db) => setDoc(doc(db, 'notifications/n1'), note));
      const alice = await asUser(ALICE);

      await assertSucceeds(
        updateDoc(doc(alice, 'notifications/n1'), { isRead: true }));
    });

    test('the recipient may NOT rewrite its content', async () => {
      await seed((db) => setDoc(doc(db, 'notifications/n1'), note));
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'notifications/n1'), { title: 'Something else' }));
    });
  });

  describe('badges (shared reference data)', () => {
    test('any signed-in user may read them', async () => {
      await seed((db) => setDoc(doc(db, 'badges/duke'), { title: 'Duke' }));
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, 'badges/duke')));
    });

    test('no client may write them', async () => {
      const alice = await asUser(ALICE);

      await assertFails(setDoc(doc(alice, 'badges/duke'), { title: 'Duke' }));
    });
  });
});
