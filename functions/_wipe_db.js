/**
 * One-off maintenance script — NOT a Cloud Function, not deployed
 * (see firebase.json functions "ignore"). Run locally with the Admin SDK.
 *
 * DESTRUCTIVE, WHOLE-PROJECT WIPE. Intended for clearing accumulated mock /
 * inconsistent development data and starting from an empty database.
 *
 * Deletes:
 *   - EVERY Firestore top-level collection except the ones in KEEP_COLLECTIONS
 *     (recursively, so subcollections like profiles/{uid}/badge_progress and
 *     cityStats/{city}/users go too)
 *   - EVERY Cloud Storage object except those under KEEP_STORAGE_PREFIXES
 *   - EVERY Firebase Auth user (unless --keep-auth)
 *
 * Keeps:
 *   - the `badges` collection (shared reference data: titles, images, order)
 *   - Storage objects under `badges/` (the badge images)
 *   - Firestore security rules, indexes, Cloud Functions (those are not data)
 *
 * No onDelete / onWrite Cloud Function triggers exist in this project, so the
 * wipe does not cascade into function executions.
 *
 * Credentials: a service-account key. Either put it at
 * uploader/serviceAccountKey.json (repo convention) or set
 * GOOGLE_APPLICATION_CREDENTIALS. Get one from the Firebase Console ->
 * Project settings -> Service accounts -> "Generate new private key".
 *
 * Usage (from the functions/ directory):
 *   node _wipe_db.js                 # dry run — counts what would be deleted
 *   node _wipe_db.js --yes           # actually wipe (5s countdown first)
 *   node _wipe_db.js --yes --keep-auth   # wipe data, keep Auth accounts
 */
const fs = require('fs');
const path = require('path');
const { initializeApp, cert, applicationDefault } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getAuth } = require('firebase-admin/auth');
const { getStorage } = require('firebase-admin/storage');

const APPLY = process.argv.includes('--yes');
const KEEP_AUTH = process.argv.includes('--keep-auth');

const KEEP_COLLECTIONS = new Set(['badges']);
const KEEP_STORAGE_PREFIXES = ['badges/'];

// --- credentials -------------------------------------------------------
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

const projectId =
  (serviceAccount && serviceAccount.project_id) ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.GCLOUD_PROJECT;

initializeApp({
  credential: serviceAccount ? cert(serviceAccount) : applicationDefault(),
  storageBucket: `${projectId}.firebasestorage.app`,
});

const db = getFirestore();
const tag = APPLY ? '[DELETE]' : '[dry-run]';

async function countDown(seconds) {
  process.stdout.write('Starting in ');
  for (let i = seconds; i > 0; i--) {
    process.stdout.write(`${i}... `);
    await new Promise((r) => setTimeout(r, 1000));
  }
  process.stdout.write('go\n\n');
}

async function wipeFirestore() {
  console.log('\n=== Firestore ===');
  const collections = await db.listCollections();
  for (const col of collections) {
    if (KEEP_COLLECTIONS.has(col.id)) {
      const kept = await col.count().get();
      console.log(`  KEEP  ${col.id} (${kept.data().count} docs)`);
      continue;
    }
    const n = await col.count().get();
    console.log(`  ${tag} ${col.id}: ${n.data().count} doc(s) (+ subcollections)`);
    if (APPLY) await db.recursiveDelete(col);
  }
}

async function wipeStorage() {
  console.log('\n=== Storage ===');
  let bucket;
  try {
    bucket = getStorage().bucket();
    const [exists] = await bucket.exists();
    if (!exists) {
      console.log(`  bucket ${bucket.name} does not exist — skipping`);
      return;
    }
  } catch (e) {
    console.log(`  storage unavailable: ${e.message}`);
    return;
  }

  const [files] = await bucket.getFiles();
  const toDelete = files.filter(
    (f) => !KEEP_STORAGE_PREFIXES.some((p) => f.name.startsWith(p))
  );
  const kept = files.length - toDelete.length;
  console.log(`  KEEP  ${kept} object(s) under ${KEEP_STORAGE_PREFIXES.join(', ')}`);
  console.log(`  ${tag} ${toDelete.length} object(s)`);

  if (!APPLY) return;
  let done = 0;
  const queue = [...toDelete];
  async function worker() {
    while (queue.length) {
      const f = queue.pop();
      await f.delete().catch((e) => console.log(`    failed ${f.name}: ${e.message}`));
      done++;
    }
  }
  await Promise.all(Array.from({ length: 8 }, worker));
  console.log(`  deleted ${done} object(s)`);
}

async function wipeAuth() {
  console.log('\n=== Auth ===');
  if (KEEP_AUTH) {
    console.log('  --keep-auth: leaving all Auth accounts in place');
    return;
  }

  const allUids = [];
  let pageToken;
  do {
    const res = await getAuth().listUsers(1000, pageToken);
    for (const u of res.users) allUids.push(u.uid);
    pageToken = res.pageToken;
  } while (pageToken);

  console.log(`  ${tag} ${allUids.length} Auth user(s)`);
  if (!APPLY || allUids.length === 0) return;

  let deleted = 0;
  for (let i = 0; i < allUids.length; i += 1000) {
    const res = await getAuth().deleteUsers(allUids.slice(i, i + 1000));
    deleted += res.successCount;
    if (res.failureCount) {
      console.log(`  ${res.failureCount} failed:`);
      for (const err of res.errors) console.log(`    ${err.error.message}`);
    }
  }
  console.log(`  deleted ${deleted} Auth user(s)`);
}

async function main() {
  console.log(`\n############################################`);
  console.log(`#  WHOLE-PROJECT WIPE`);
  console.log(`#  TARGET PROJECT: ${projectId || '(unknown!)'}`);
  console.log(`#  mode: ${APPLY ? 'APPLY (destructive)' : 'dry run'}`);
  console.log(`#  keep collections: ${[...KEEP_COLLECTIONS].join(', ')}`);
  console.log(`#  keep auth: ${KEEP_AUTH}`);
  console.log(`############################################`);

  if (APPLY) {
    console.log('\nThis PERMANENTLY deletes all data above. Ctrl+C now to abort.');
    await countDown(5);
  }

  await wipeFirestore();
  await wipeStorage();
  await wipeAuth();

  console.log(
    `\n${APPLY
      ? 'Wipe complete. `badges` and badge images kept; everything else is empty.'
      : 'Dry run complete. Re-run with --yes to wipe.'}\n`
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
