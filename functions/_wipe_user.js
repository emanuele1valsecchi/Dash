/**
 * One-off maintenance script — NOT a Cloud Function, not deployed
 * (see firebase.json functions "ignore"). Run locally with the Admin SDK.
 *
 * Completely removes a user from the project so its email and username can be
 * registered again from scratch.
 *
 * Why this is needed: deleting Firestore documents by hand does NOT delete the
 * Firebase Auth account, and the signup Cloud Function (seedUserProfileAndBadges)
 * only ever runs on Auth user *creation* — so a user whose profile doc was
 * deleted can neither log in usefully (the client cannot recreate profiles/{uid}
 * or badge_progress) nor re-register (the email is still taken in Auth). This
 * script deletes everything for one UID, including the `nicknames` entry that
 * otherwise keeps the username reserved, and the Auth account itself.
 *
 * Credentials: needs a service-account key. Either
 *   - put it at uploader/serviceAccountKey.json (existing repo convention), or
 *   - set GOOGLE_APPLICATION_CREDENTIALS to its path.
 * Get one from: Firebase Console -> Project settings -> Service accounts ->
 * "Generate new private key".
 *
 * Usage (from the functions/ directory, which has a working node_modules):
 *   node _wipe_user.js <uid>            # dry run — prints what it would delete
 *   node _wipe_user.js <uid> --yes      # actually delete
 *
 *   --keep-routes   keep routes this user authored (matches the in-app
 *                   "Delete account" flow, which preserves published routes)
 */
const fs = require('fs');
const path = require('path');
const { initializeApp, cert, applicationDefault } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getAuth } = require('firebase-admin/auth');
const { getStorage } = require('firebase-admin/storage');

const uid = process.argv[2];
const APPLY = process.argv.includes('--yes');
const KEEP_ROUTES = process.argv.includes('--keep-routes');

if (!uid || uid.startsWith('--')) {
  console.error('Usage: node _wipe_user.js <uid> [--yes] [--keep-routes]');
  process.exit(1);
}

// --- credentials ---------------------------------------------------------
const keyCandidates = [
  process.env.GOOGLE_APPLICATION_CREDENTIALS,
  path.join(__dirname, '..', 'uploader', 'serviceAccountKey.json'),
  path.join(__dirname, 'serviceAccountKey.json'),
].filter(Boolean);

let serviceAccount = null;
for (const p of keyCandidates) {
  if (fs.existsSync(p)) {
    serviceAccount = JSON.parse(fs.readFileSync(p, 'utf8'));
    console.log(`Using service account key: ${p}`);
    break;
  }
}

initializeApp(
  serviceAccount
    ? { credential: cert(serviceAccount) }
    : { credential: applicationDefault() }
);

const db = getFirestore();
const projectId =
  (serviceAccount && serviceAccount.project_id) ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.GCLOUD_PROJECT;

const tag = APPLY ? '[DELETE]' : '[dry-run]';

async function deleteQuery(label, query) {
  const snap = await query.get();
  console.log(`${tag} ${label}: ${snap.size} document(s)`);
  if (!APPLY || snap.empty) return;
  for (let i = 0; i < snap.docs.length; i += 450) {
    const batch = db.batch();
    for (const doc of snap.docs.slice(i, i + 450)) batch.delete(doc.ref);
    await batch.commit();
  }
}

async function deleteDocRecursive(label, ref) {
  const snap = await ref.get();
  console.log(`${tag} ${label}: ${snap.exists ? 'exists' : 'not found'}`);
  if (APPLY && snap.exists) {
    // recursiveDelete also clears subcollections (profiles/{uid}/badge_progress).
    await db.recursiveDelete(ref);
  }
}

async function main() {
  console.log(
    `\nWiping uid=${uid}  ${APPLY ? '(APPLYING CHANGES)' : '(dry run — pass --yes to apply)'}\n`
  );

  const profileSnap = await db.collection('profiles').doc(uid).get();
  const profile = profileSnap.exists ? profileSnap.data() : {};
  if (profileSnap.exists) {
    console.log(`  profile.username = ${profile.username || '(none)'}`);
    console.log(`  profile.email    = ${profile.email || '(none)'}\n`);
  }

  // --- Firestore --------------------------------------------------------
  await deleteDocRecursive('profiles/{uid} (+ badge_progress)', db.collection('profiles').doc(uid));
  await deleteDocRecursive('userStats/{uid}', db.collection('userStats').doc(uid));

  await deleteQuery('nicknames (uid ==)', db.collection('nicknames').where('uid', '==', uid));
  await deleteQuery('runningSessions (userId ==)', db.collection('runningSessions').where('userId', '==', uid));
  await deleteQuery('claimedAreas (userId ==)', db.collection('claimedAreas').where('userId', '==', uid));
  await deleteQuery('notifications (userId ==)', db.collection('notifications').where('userId', '==', uid));
  await deleteQuery('favoriteRoutes (userId ==)', db.collection('favoriteRoutes').where('userId', '==', uid));
  await deleteQuery('follows (followerId ==)', db.collection('follows').where('followerId', '==', uid));
  await deleteQuery('follows (followingId ==)', db.collection('follows').where('followingId', '==', uid));

  if (KEEP_ROUTES) {
    console.log(`${tag} routes (userId ==): skipped (--keep-routes)`);
  } else {
    await deleteQuery('routes (userId ==)', db.collection('routes').where('userId', '==', uid));
  }

  // cityStats/{city}/users/{uid}
  const cityStats = await db.collection('cityStats').get();
  let cityHits = 0;
  for (const city of cityStats.docs) {
    const ref = city.ref.collection('users').doc(uid);
    if ((await ref.get()).exists) {
      cityHits++;
      if (APPLY) await ref.delete();
    }
  }
  console.log(`${tag} cityStats/*/users/{uid}: ${cityHits} entry(ies)`);

  // --- Storage (profile image) ----------------------------------------
  const paths = [];
  if (typeof profile.profileImagePath === 'string' && profile.profileImagePath) {
    paths.push(profile.profileImagePath);
  }
  paths.push(`profile_images/${uid}.jpg`);

  const bucketNames = projectId
    ? [`${projectId}.firebasestorage.app`, `${projectId}.appspot.com`]
    : [];
  for (const name of bucketNames) {
    try {
      const bucket = getStorage().bucket(name);
      const [exists] = await bucket.exists();
      if (!exists) continue;
      for (const p of paths) {
        const [fileExists] = await bucket.file(p).exists();
        console.log(`${tag} storage ${name}/${p}: ${fileExists ? 'exists' : 'not found'}`);
        if (APPLY && fileExists) await bucket.file(p).delete();
      }
      break;
    } catch (e) {
      console.log(`  storage bucket ${name}: ${e.message}`);
    }
  }

  // --- Auth ----------------------------------------------------------
  try {
    const rec = await getAuth().getUser(uid);
    const who = rec.email || rec.providerData.map((p) => p.providerId).join(',') || '(no email)';
    console.log(`${tag} auth user: ${who}`);
    if (APPLY) await getAuth().deleteUser(uid);
  } catch (e) {
    if (e.code === 'auth/user-not-found') {
      console.log(`${tag} auth user: not found`);
    } else {
      throw e;
    }
  }

  console.log(
    `\n${APPLY
      ? 'Done. Email and username are free again — re-register in the app.'
      : 'Dry run complete. Re-run with --yes to delete.'}\n`
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
