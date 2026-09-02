import { test, describe, before, after, beforeEach } from 'node:test';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';
import {
  rulesSuite, assertFails, assertSucceeds, sessionDoc,
} from './helpers.js';

// Own emulator project, so parallel test files cannot clear each
// other's data. See rulesSuite().
const { asUser, asAnon, seed, clearData, cleanup } =
    rulesSuite('sessions');

const ALICE = 'alice';
const BOB = 'bob';

/**
 * `runningSessions` is **world-readable to signed-in users** — deliberately,
 * so a run-detail page can show someone else's whole run. That makes the write
 * rules the entire trust boundary, and makes the private subcollection the
 * only place body metrics can safely live: Firestore cannot restrict
 * individual fields of a document that is readable at all.
 */
describe('runningSessions', () => {
  before(clearData);
  after(cleanup);
  beforeEach(clearData);

  describe('reading', () => {
    test('any signed-in user may read any session', async () => {
      await seed((db) => setDoc(doc(db, 'runningSessions/s1'), sessionDoc(ALICE)));
      const bob = await asUser(BOB);

      await assertSucceeds(getDoc(doc(bob, 'runningSessions/s1')));
    });

    test('a signed-out visitor may not', async () => {
      await seed((db) => setDoc(doc(db, 'runningSessions/s1'), sessionDoc(ALICE)));
      const anon = await asAnon();

      await assertFails(getDoc(doc(anon, 'runningSessions/s1')));
    });
  });

  describe('creating', () => {
    test('a user may save their own run', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(
        setDoc(doc(alice, 'runningSessions/s1'), sessionDoc(ALICE)));
    });

    test('a user may NOT save a run owned by someone else', async () => {
      const alice = await asUser(ALICE);

      await assertFails(
        setDoc(doc(alice, 'runningSessions/s1'), sessionDoc(BOB)));
    });

    test('pointsEarned must be zero — XP is the server\'s to award',
      async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, 'runningSessions/s1'),
          sessionDoc(ALICE, { pointsEarned: 9999 })));
      });

    describe('heart rate may not be published', () => {
      // The whole reason the private subcollection exists. A session doc is
      // readable by every signed-in user, so a body metric here is public
      // however the UI chooses to draw it.
      test('avgHeartRateBpm is rejected outright', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, 'runningSessions/s1'),
          sessionDoc(ALICE, { avgHeartRateBpm: 152 })));
      });

      test('maxHeartRateBpm is rejected outright', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, 'runningSessions/s1'),
          sessionDoc(ALICE, { maxHeartRateBpm: 178 })));
      });
    });

    describe('server-only scoring fields are refused on create', () => {
      for (const field of [
        'territoryCity', 'territoryBroad', 'territoryBroadType',
        'totalAreaM2', 'stolenAreaM2', 'xpFromDistance', 'xpFromArea',
        'xpFromStolenArea', 'pointsProcessed',
      ]) {
        test(field, async () => {
          const alice = await asUser(ALICE);

          await assertFails(setDoc(doc(alice, 'runningSessions/s1'),
            sessionDoc(ALICE, { [field]: 1 })));
        });
      }
    });
  });

  describe('updating', () => {
    beforeEach(() => seed((db) =>
      setDoc(doc(db, 'runningSessions/s1'), sessionDoc(ALICE))));

    test('the owner may finalize their own run', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(
        updateDoc(doc(alice, 'runningSessions/s1'), { name: 'Evening run' }));
    });

    test('another user may NOT touch it', async () => {
      const bob = await asUser(BOB);

      await assertFails(
        updateDoc(doc(bob, 'runningSessions/s1'), { name: 'Mine now' }));
    });

    test('pointsEarned may not be changed', async () => {
      // The single most important line in this file: XP is the score, and a
      // client that can set it can rewrite the leaderboard.
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'runningSessions/s1'), { pointsEarned: 9999 }));
    });

    test('ownership may not be reassigned', async () => {
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'runningSessions/s1'), { userId: BOB }));
    });

    test('heart rate may not be added later either', async () => {
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'runningSessions/s1'), { avgHeartRateBpm: 152 }));
    });

    describe('server-only scoring fields are refused on update', () => {
      for (const field of [
        'territoryCity', 'totalAreaM2', 'stolenAreaM2',
        'xpFromDistance', 'pointsProcessed',
      ]) {
        test(field, async () => {
          const alice = await asUser(ALICE);

          await assertFails(
            updateDoc(doc(alice, 'runningSessions/s1'), { [field]: 1 }));
        });
      }
    });

    test('nobody may delete a session', async () => {
      const alice = await asUser(ALICE);

      await assertFails(deleteDoc(doc(alice, 'runningSessions/s1')));
    });
  });

  describe('the private metrics subcollection', () => {
    const path = 'runningSessions/s1/private/metrics';

    beforeEach(() => seed((db) =>
      setDoc(doc(db, 'runningSessions/s1'), sessionDoc(ALICE))));

    test('the owner may write their own metrics', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(setDoc(doc(alice, path), {
        userId: ALICE, avgHeartRateBpm: 152, maxHeartRateBpm: 178,
      }));
    });

    test('the owner may read them back', async () => {
      await seed((db) => setDoc(doc(db, path), {
        userId: ALICE, avgHeartRateBpm: 152,
      }));
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, path)));
    });

    test('another user may NOT read them, though the parent is public',
      async () => {
        // The point of the whole subcollection. Rules do not cascade, so this
        // block is the only thing granting access - and it grants it to the
        // owner alone.
        await seed((db) => setDoc(doc(db, path), {
          userId: ALICE, avgHeartRateBpm: 152,
        }));
        const bob = await asUser(BOB);

        await assertFails(getDoc(doc(bob, path)));
      });

    test('another user may NOT overwrite metrics that exist', async () => {
      // The real boundary. Update is gated on the *existing* document's
      // userId, so once the owner has written theirs, nobody else can touch
      // it.
      await seed((db) => setDoc(doc(db, path), {
        userId: ALICE, avgHeartRateBpm: 152,
      }));
      const bob = await asUser(BOB);

      await assertFails(setDoc(doc(bob, path), {
        userId: BOB, avgHeartRateBpm: 999,
      }));
    });

    // ─────────────────────────────────────────────────────────────────
    // OPEN SECURITY QUESTION — this test asserts the behaviour we WANT and
    // currently FAILS. Marked `todo` so it shows up as a red line in every
    // run without breaking the build. See TEST_NOTES.md section 5.
    //
    // `create` on this subcollection authorizes off the document's own
    // denormalized `userId`, not the parent session's owner. So any signed-in
    // user can write a metrics document under ANYONE's session, as long as
    // they stamp their own uid on it.
    //
    // Delete this `todo` marker the moment the rule is tightened; node:test
    // reports a passing todo, which is the prompt to do so.
    // ─────────────────────────────────────────────────────────────────
    test('another user may NOT create metrics under someone elses session',
      { todo: 'private-metrics squatting - unresolved, see TEST_NOTES.md #5' },
      async () => {
        const bob = await asUser(BOB);

        await assertFails(setDoc(doc(bob, path), {
          userId: BOB, avgHeartRateBpm: 152,
        }));
      });

    // The consequence that makes the above more than untidy: once the slot is
    // squatted, the owner's own write becomes an *update*, which is gated on
    // the EXISTING document's userId — so she is locked out of her own run's
    // metrics, and cannot read or delete the squatter's document to clear it.
    // Verified empirically: create ALLOWED for Bob, then write/read/delete all
    // DENIED for Alice. Also `todo` — same unresolved issue.
    test('the owner can still save metrics after someone squats the slot',
      { todo: 'private-metrics squatting - unresolved, see TEST_NOTES.md #5' },
      async () => {
        const bob = await asUser(BOB);
        await setDoc(doc(bob, path), { userId: BOB, avgHeartRateBpm: 152 });

        const alice = await asUser(ALICE);
        await assertSucceeds(setDoc(doc(alice, path), {
          userId: ALICE, avgHeartRateBpm: 140,
        }));
      });

    test('a missing document denies rather than reading as empty', async () => {
      // Deliberate: if absence read as an empty snapshot while presence read
      // as denied, any signed-in user could tell which of someone else's runs
      // carry watch data. Denying both leaks nothing.
      const alice = await asUser(ALICE);

      await assertFails(getDoc(doc(alice, path)));
    });

    describe('heart rate must be plausible', () => {
      test('zero is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, path), {
          userId: ALICE, avgHeartRateBpm: 0,
        }));
      });

      test('above 250 is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, path), {
          userId: ALICE, avgHeartRateBpm: 251,
        }));
      });

      test('a non-integer is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, path), {
          userId: ALICE, avgHeartRateBpm: '152',
        }));
      });

      test('absent is fine — most runs have no watch', async () => {
        const alice = await asUser(ALICE);

        await assertSucceeds(setDoc(doc(alice, path), { userId: ALICE }));
      });
    });
  });
});
