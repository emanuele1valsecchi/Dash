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

    test('pointsEarned must be zero, XP is the server to award', async () => {
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
    // The document ID *is* the owner's uid. That is what makes one user's
    // write structurally unable to collide with another's — see the block
    // comment in firestore.rules.
    const alicePath = `runningSessions/s1/private/${ALICE}`;
    const bobPath = `runningSessions/s1/private/${BOB}`;

    beforeEach(() => seed((db) =>
      setDoc(doc(db, 'runningSessions/s1'), sessionDoc(ALICE))));

    test('the owner may write their own metrics', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(setDoc(doc(alice, alicePath), {
        userId: ALICE, avgHeartRateBpm: 152, maxHeartRateBpm: 178,
      }));
    });

    test('the owner may read them back', async () => {
      await seed((db) => setDoc(doc(db, alicePath), {
        userId: ALICE, avgHeartRateBpm: 152,
      }));
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, alicePath)));
    });

    test('the owner may delete their own', async () => {
      await seed((db) => setDoc(doc(db, alicePath), { userId: ALICE }));
      const alice = await asUser(ALICE);

      await assertSucceeds(deleteDoc(doc(alice, alicePath)));
    });

    describe('one user cannot reach the slot of another', () => {
      // The fix for the squatting hole. Previously every user addressed the
      // same `.../private/metrics` document, so Bob could occupy Alice's slot
      // and lock her out of her own heart rate permanently.
      test('another user may NOT read it', async () => {
        await seed((db) => setDoc(doc(db, alicePath), {
          userId: ALICE, avgHeartRateBpm: 152,
        }));
        const bob = await asUser(BOB);

        await assertFails(getDoc(doc(bob, alicePath)));
      });

      test('another user may NOT create in it', async () => {
        const bob = await asUser(BOB);

        await assertFails(setDoc(doc(bob, alicePath), {
          userId: BOB, avgHeartRateBpm: 152,
        }));
      });

      test('another user may NOT overwrite it', async () => {
        await seed((db) => setDoc(doc(db, alicePath), {
          userId: ALICE, avgHeartRateBpm: 152,
        }));
        const bob = await asUser(BOB);

        await assertFails(setDoc(doc(bob, alicePath), {
          userId: BOB, avgHeartRateBpm: 999,
        }));
      });

      test('another user may NOT delete it', async () => {
        await seed((db) => setDoc(doc(db, alicePath), { userId: ALICE }));
        const bob = await asUser(BOB);

        await assertFails(deleteDoc(doc(bob, alicePath)));
      });

      test('the body cannot claim an owner the path does not', async () => {
        // Belt and braces: the path already decides, but a document whose
        // `userId` disagreed with its own ID would be a confusing lie to
        // anything reading the field.
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, alicePath), { userId: BOB }));
      });
    });

    describe('the squatting attack is now impossible', () => {
      // Regression tests for the finding. Both of these were `todo` markers
      // because they FAILED: Bob could create under Alice's session and
      // thereby lock her out of her own data.
      test('a squat attempt is refused outright', async () => {
        const bob = await asUser(BOB);

        await assertFails(setDoc(doc(bob, alicePath), {
          userId: BOB, avgHeartRateBpm: 152,
        }));
      });

      test('the owner can still save metrics afterwards', async () => {
        // Bob writes the only thing he can — his own slot under her session —
        // and Alice is entirely unaffected.
        const bob = await asUser(BOB);
        await assertSucceeds(
          setDoc(doc(bob, bobPath), { userId: BOB, avgHeartRateBpm: 152 }));

        const alice = await asUser(ALICE);
        await assertSucceeds(setDoc(doc(alice, alicePath), {
          userId: ALICE, avgHeartRateBpm: 140,
        }));
      });

      test('and Bob still cannot read what she wrote', async () => {
        await seed((db) => setDoc(doc(db, alicePath), {
          userId: ALICE, avgHeartRateBpm: 140,
        }));
        const bob = await asUser(BOB);

        await assertFails(getDoc(doc(bob, alicePath)));
      });
    });

    test('a missing document reads as empty for the owner', async () => {
      // Deliberately changed. It used to deny, because the rule had to
      // authorize off a `userId` a missing document does not have. Now the
      // path decides, so the owner gets a clean empty answer while another
      // user is refused before existence is ever consulted - which is what
      // stops anyone probing whose runs carry watch data.
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, alicePath)));
    });

    test('another user probing an absent slot is still denied', async () => {
      const bob = await asUser(BOB);

      await assertFails(getDoc(doc(bob, alicePath)));
    });

    describe('heart rate must be plausible', () => {
      test('zero is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, alicePath), {
          userId: ALICE, avgHeartRateBpm: 0,
        }));
      });

      test('above 250 is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, alicePath), {
          userId: ALICE, avgHeartRateBpm: 251,
        }));
      });

      test('a non-integer is refused', async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, alicePath), {
          userId: ALICE, avgHeartRateBpm: '152',
        }));
      });

      test('absent is fine, most runs have no watch', async () => {
        const alice = await asUser(ALICE);

        await assertSucceeds(
          setDoc(doc(alice, alicePath), { userId: ALICE }));
      });
    });

    describe('transitional legacy documents', () => {
      // Written under the old fixed `metrics` ID. Readable and deletable by
      // their owner so nothing breaks before the migration runs; not
      // writable, so the set can only shrink.
      const legacyPath = 'runningSessions/s1/private/metrics';

      test('the owner may still read one', async () => {
        await seed((db) => setDoc(doc(db, legacyPath), {
          userId: ALICE, avgHeartRateBpm: 152,
        }));
        const alice = await asUser(ALICE);

        await assertSucceeds(getDoc(doc(alice, legacyPath)));
      });

      test('another user may not', async () => {
        await seed((db) => setDoc(doc(db, legacyPath), {
          userId: ALICE, avgHeartRateBpm: 152,
        }));
        const bob = await asUser(BOB);

        await assertFails(getDoc(doc(bob, legacyPath)));
      });

      test('the owner may clear one', async () => {
        await seed((db) => setDoc(doc(db, legacyPath), { userId: ALICE }));
        const alice = await asUser(ALICE);

        await assertSucceeds(deleteDoc(doc(alice, legacyPath)));
      });

      test('nobody may create a new one, the old slot is closed to writes',
        async () => {
          const alice = await asUser(ALICE);

          await assertFails(setDoc(doc(alice, legacyPath), {
            userId: ALICE, avgHeartRateBpm: 152,
          }));
        });
    });
  });
});
