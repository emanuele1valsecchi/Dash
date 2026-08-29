/**
 * One-off maintenance script — NOT a Cloud Function, not deployed
 * (see firebase.json functions "ignore"). Run locally with the Admin SDK.
 *
 * Assigns `areaColorIndex` to every `profiles/{uid}` document that does not
 * already have a valid one. New accounts get theirs from
 * `seedUserProfileAndBadges`, which only ever runs on Auth user *creation* —
 * so every profile that existed before per-player territory colours landed
 * needs this pass.
 *
 * Not exposed as a callable function on purpose: there is no admin role in
 * this project, so a deployed endpoint that rewrites other users' profiles
 * would either be callable by anyone or need an ad-hoc uid allowlist. A local
 * script authenticated by a service-account key is the same trust boundary the
 * other maintenance scripts here already use.
 *
 * **The app does not depend on this having been run.** `PlayerPalette` falls
 * back to a stable hash of the uid whenever `areaColorIndex` is missing, so
 * un-backfilled players already render with a consistent colour. This pass
 * merely persists a value, which is what makes a future "change my colour"
 * setting possible and keeps colours stable if the hash is ever changed.
 *
 * Assignment is **deliberately not random here** — it is the same FNV-1a
 * uid hash the client falls back to (see `PlayerPalette.indexForUid`). That
 * way running this script does not change what anyone already sees on the
 * map: it writes down the colour that was being displayed anyway. Re-running
 * it is therefore a no-op, and the two implementations must stay in step.
 *
 * Credentials: needs a service-account key. Either
 *   - put it at uploader/serviceAccountKey.json (existing repo convention), or
 *   - set GOOGLE_APPLICATION_CREDENTIALS to its path.
 *
 * Usage (from the functions/ directory, which has a working node_modules):
 *   node _backfill_area_colors.js            # dry run — prints what it would do
 *   node _backfill_area_colors.js --yes      # actually write
 *   node _backfill_area_colors.js --yes --random   # random instead of hashed
 */
const fs = require('fs');
const path = require('path');
const { initializeApp, cert, applicationDefault } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const APPLY = process.argv.includes('--yes');
const RANDOM = process.argv.includes('--random');

/** Keep in step with PALETTE_SIZE in index.js and PlayerPalette.size in Dart. */
const PALETTE_SIZE = 10;

/**
 * 32-bit FNV-1a over the uid's UTF-16 code units — a byte-for-byte port of
 * `PlayerPalette.indexForUid`. If you change one, change both, or a backfilled
 * profile will visibly change colour the moment it is written.
 */
function indexForUid(uid) {
  if (!uid) return 0;
  let hash = 0x811c9dc5;
  for (let i = 0; i < uid.length; i++) {
    hash ^= uid.charCodeAt(i);
    // Math.imul keeps this in 32-bit two's-complement like Dart's masked
    // multiply; >>> 0 brings it back to unsigned.
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash % PALETTE_SIZE;
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
const tag = APPLY ? '[WRITE]' : '[dry-run]';

async function main() {
  const snap = await db.collection('profiles').get();
  console.log(`${tag} ${snap.size} profile(s) found.`);

  let assigned = 0;
  let skipped = 0;

  // Firestore caps a batch at 500 writes.
  let batch = db.batch();
  let pending = 0;

  for (const doc of snap.docs) {
    const current = doc.data().areaColorIndex;
    const alreadyValid =
      typeof current === 'number' &&
      Number.isInteger(current) &&
      current >= 0 &&
      current < PALETTE_SIZE;

    if (alreadyValid) {
      skipped++;
      continue;
    }

    const index = RANDOM
      ? Math.floor(Math.random() * PALETTE_SIZE)
      : indexForUid(doc.id);

    console.log(`${tag} ${doc.id} -> areaColorIndex ${index}`);
    assigned++;

    if (APPLY) {
      batch.update(doc.ref, { areaColorIndex: index });
      pending++;
      if (pending === 450) {
        await batch.commit();
        batch = db.batch();
        pending = 0;
      }
    }
  }

  if (APPLY && pending > 0) await batch.commit();

  console.log(
    `${tag} done — ${assigned} assigned, ${skipped} already had a valid colour.`
  );
  if (!APPLY && assigned > 0) {
    console.log('Re-run with --yes to actually write these.');
  }
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  }
);
