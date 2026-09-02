import { test, describe, before, after, beforeEach } from 'node:test';
import { doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp }
  from 'firebase/firestore';
import {
  rulesSuite, assertFails, assertSucceeds, routeDoc,
} from './helpers.js';

// Own emulator project, so parallel test files cannot clear each
// other's data. See rulesSuite().
const { asUser, asAnon, seed, clearData, cleanup } =
    rulesSuite('routes');

const ALICE = 'alice';
const BOB = 'bob';

/**
 * `routes` holds two shapes, and the difference is the whole security story:
 *
 *  - an **owned** route (`userId` is its author), private unless published;
 *  - a **shared session route** (`userId: null`, `isPublic: true`, doc ID ==
 *    the source session's ID) — the one canonical copy of a run's path that
 *    every user who favourited that run points at.
 *
 * The client must never be able to write the second shape, and must never be
 * able to flip the first one's visibility after the fact.
 */
describe('routes', () => {
  before(clearData);
  after(cleanup);
  beforeEach(clearData);

  describe('reading', () => {
    test('a signed-out visitor may read nothing', async () => {
      await seed((db) => setDoc(doc(db, 'routes/r1'), routeDoc(ALICE)));
      const anon = await asAnon();

      await assertFails(getDoc(doc(anon, 'routes/r1')));
    });

    test('the owner may read their own private route', async () => {
      await seed((db) => setDoc(doc(db, 'routes/r1'), routeDoc(ALICE)));
      const alice = await asUser(ALICE);

      await assertSucceeds(getDoc(doc(alice, 'routes/r1')));
    });

    test('another user may NOT read a private route', async () => {
      await seed((db) => setDoc(doc(db, 'routes/r1'), routeDoc(ALICE)));
      const bob = await asUser(BOB);

      await assertFails(getDoc(doc(bob, 'routes/r1')));
    });

    test('another user MAY read a published route', async () => {
      await seed((db) =>
        setDoc(doc(db, 'routes/r1'), routeDoc(ALICE, { isPublic: true })));
      const bob = await asUser(BOB);

      await assertSucceeds(getDoc(doc(bob, 'routes/r1')));
    });

    test('a route predating the isPublic field reads as private', async () => {
      // The rule uses get('isPublic', false), so an absent field must default
      // to private rather than being an evaluation error or, worse, public.
      const legacy = routeDoc(ALICE);
      delete legacy.isPublic;
      await seed((db) => setDoc(doc(db, 'routes/r1'), legacy));
      const bob = await asUser(BOB);

      await assertFails(getDoc(doc(bob, 'routes/r1')));
    });
  });

  describe('creating', () => {
    test('a user may create their own route', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(setDoc(doc(alice, 'routes/r1'), {
        ...routeDoc(ALICE),
        createdAt: serverTimestamp(),
      }));
    });

    test('a user may NOT create a route owned by someone else', async () => {
      const alice = await asUser(ALICE);

      await assertFails(setDoc(doc(alice, 'routes/r1'), {
        ...routeDoc(BOB),
        createdAt: serverTimestamp(),
      }));
    });

    test('isPublic must be present', async () => {
      // Stated explicitly so a route can never end up public — or ambiguous —
      // through a missing field.
      const alice = await asUser(ALICE);
      const noVisibility = routeDoc(ALICE);
      delete noVisibility.isPublic;

      await assertFails(setDoc(doc(alice, 'routes/r1'), {
        ...noVisibility,
        createdAt: serverTimestamp(),
      }));
    });

    test('isPublic must be a boolean', async () => {
      const alice = await asUser(ALICE);

      await assertFails(setDoc(doc(alice, 'routes/r1'), {
        ...routeDoc(ALICE, { isPublic: 'yes' }),
        createdAt: serverTimestamp(),
      }));
    });

    test('createdAt must be the server timestamp, not a client clock',
      async () => {
        const alice = await asUser(ALICE);

        await assertFails(setDoc(doc(alice, 'routes/r1'), {
          ...routeDoc(ALICE),
          createdAt: new Date(2020, 0, 1),
        }));
      });

    test('a client may NOT forge a shared session route', async () => {
      // The critical one. A shared route is read by every user who favourited
      // that run, and no rule can check that a client-supplied polyline really
      // is the run it claims to be. If a client could pre-create
      // routes/{sessionId}, it could poison the geometry everyone else sees.
      const alice = await asUser(ALICE);

      await assertFails(setDoc(doc(alice, 'routes/session-1'), {
        ...routeDoc(null, { isPublic: true }),
        createdAt: serverTimestamp(),
      }));
    });
  });

  describe('updating', () => {
    beforeEach(() => seed((db) =>
      setDoc(doc(db, 'routes/r1'), routeDoc(ALICE))));

    test('the owner may rename', async () => {
      const alice = await asUser(ALICE);

      await assertSucceeds(
        updateDoc(doc(alice, 'routes/r1'), { name: 'Evening loop' }));
    });

    test('another user may NOT rename', async () => {
      const bob = await asUser(BOB);

      await assertFails(
        updateDoc(doc(bob, 'routes/r1'), { name: 'Mine now' }));
    });

    describe('visibility is permanent', () => {
      // The choice is made once, at save time. Enforced here rather than by
      // simply not building a toggle: whether a route someone may already have
      // seen quietly disappears is not a client's call.
      test('the owner may NOT publish a private route afterwards',
        async () => {
          const alice = await asUser(ALICE);

          await assertFails(
            updateDoc(doc(alice, 'routes/r1'), { isPublic: true }));
        });

      test('the owner may NOT un-publish a public route', async () => {
        await seed((db) =>
          setDoc(doc(db, 'routes/r2'), routeDoc(ALICE, { isPublic: true })));
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'routes/r2'), { isPublic: false }));
      });

      test('a rename still works on a route predating the field', async () => {
        // Compared with get(..., false) on both sides precisely so this
        // does not become an evaluation error.
        const legacy = routeDoc(ALICE);
        delete legacy.isPublic;
        await seed((db) => setDoc(doc(db, 'routes/r3'), legacy));
        const alice = await asUser(ALICE);

        await assertSucceeds(
          updateDoc(doc(alice, 'routes/r3'), { name: 'Renamed' }));
      });

      test('but publishing such a route is still refused', async () => {
        const legacy = routeDoc(ALICE);
        delete legacy.isPublic;
        await seed((db) => setDoc(doc(db, 'routes/r4'), legacy));
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'routes/r4'), { isPublic: true }));
      });
    });

    describe('geometry is immutable', () => {
      test('the polyline may not be rewritten', async () => {
        const alice = await asUser(ALICE);

        await assertFails(updateDoc(doc(alice, 'routes/r1'), {
          routePolyline: [{ latitude: 1, longitude: 2 }],
        }));
      });

      test('the distance may not be rewritten', async () => {
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'routes/r1'), { distanceMeters: 99999 }));
      });

      test('ownership may not be reassigned', async () => {
        const alice = await asUser(ALICE);

        await assertFails(
          updateDoc(doc(alice, 'routes/r1'), { userId: BOB }));
      });
    });

    test('nobody may write a shared session route', async () => {
      // It has no owner, so isOwner() is false for everyone - including the
      // user whose run it came from.
      await seed((db) => setDoc(doc(db, 'routes/session-1'),
        routeDoc(null, { isPublic: true })));
      const alice = await asUser(ALICE);

      await assertFails(
        updateDoc(doc(alice, 'routes/session-1'), { name: 'Mine' }));
    });
  });

  describe('deleting', () => {
    test('the owner may delete their route', async () => {
      await seed((db) => setDoc(doc(db, 'routes/r1'), routeDoc(ALICE)));
      const alice = await asUser(ALICE);

      await assertSucceeds(deleteDoc(doc(alice, 'routes/r1')));
    });

    test('another user may NOT delete it', async () => {
      await seed((db) => setDoc(doc(db, 'routes/r1'), routeDoc(ALICE)));
      const bob = await asUser(BOB);

      await assertFails(deleteDoc(doc(bob, 'routes/r1')));
    });

    test('nobody may delete a shared session route', async () => {
      // Other users' favourites reference it, so it must outlive any one of
      // them un-favouriting.
      await seed((db) => setDoc(doc(db, 'routes/session-1'),
        routeDoc(null, { isPublic: true })));
      const alice = await asUser(ALICE);

      await assertFails(deleteDoc(doc(alice, 'routes/session-1')));
    });
  });
});
