/**
 * One-off migration: move heart rate off the public `runningSessions`
 * document into the owner-only `private/metrics` subcollection, and drop the
 * `caloriesBurned` field that is no longer stored.
 *
 * ## Why this has to run
 *
 * `runningSessions` documents are readable by every signed-in user (a
 * deliberate exposure, so a run-detail page can show someone else's route).
 * Heart rate sat on those documents, which meant it was readable by everyone
 * too. New runs no longer write it there — but **existing runs still have it,
 * and the app change alone does not remove it.** Until this script runs, every
 * historical watch run is still publishing its owner's heart rate.
 *
 * `caloriesBurned` is dropped in the same pass: energy is now derived from
 * distance (see ./estimates and lib/utils/run_estimates.dart), so the stored
 * copy is dead weight. It is not a privacy fix — distance is public and
 * energy is distance * 70 — just cleanup.
 *
 * ## Running it
 *
 *   node functions/_migrate_private_metrics.js            # dry run, prints only
 *   node functions/_migrate_private_metrics.js --commit   # actually writes
 *
 * Credentials follow the same convention as `_backfill_area_colors.js`. Either
 *   - put a service-account key at uploader/serviceAccountKey.json (the
 *     existing repo convention — gitignored, and it must stay that way), or
 *   - set GOOGLE_APPLICATION_CREDENTIALS to its path, or
 *   - have application-default credentials, in which case the project id is
 *     taken from .firebaserc (or GOOGLE_CLOUD_PROJECT / --project <id>).
 *
 * The resolved project is printed before anything is written, because this
 * rewrites production documents and "which database am I pointed at" should
 * never be a guess.
 *
 * Deliberately a local Admin-SDK script rather than a callable, following
 * `_backfill_area_colors.js`: there is no admin role in this project, so a
 * deployed endpoint that rewrote other users' documents would either be
 * callable by anyone or need an ad-hoc uid allowlist. It is in firebase.json's
 * functions `ignore` list, so it is never deployed.
 *
 * **Idempotent**: a session whose fields have already moved has nothing left
 * to read, so a second run is a no-op. Safe to re-run after a partial failure.
 */

const fs = require("fs");
const path = require("path");
const { initializeApp, cert, applicationDefault } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// `--yes` is accepted too, matching _backfill_area_colors.js's flag.
const COMMIT =
  process.argv.includes("--commit") || process.argv.includes("--yes");
const BATCH_LIMIT = 200;

// --- credentials ---------------------------------------------------------
const keyCandidates = [
  process.env.GOOGLE_APPLICATION_CREDENTIALS,
  path.join(__dirname, "..", "uploader", "serviceAccountKey.json"),
  path.join(__dirname, "serviceAccountKey.json"),
].filter(Boolean);

let serviceAccount = null;
for (const p of keyCandidates) {
  if (fs.existsSync(p)) {
    serviceAccount = JSON.parse(fs.readFileSync(p, "utf8"));
    console.log(`Using service account key: ${p}`);
    break;
  }
}

/**
 * Application-default credentials often carry no project id, which surfaces as
 * "Unable to detect a Project Id in the current environment". The repo already
 * states which project this is, so read it rather than making the caller
 * export an env var.
 */
function resolveProjectId() {
  const flagIndex = process.argv.indexOf("--project");
  if (flagIndex !== -1 && process.argv[flagIndex + 1]) {
    return process.argv[flagIndex + 1];
  }
  if (process.env.GOOGLE_CLOUD_PROJECT) return process.env.GOOGLE_CLOUD_PROJECT;
  if (process.env.GCLOUD_PROJECT) return process.env.GCLOUD_PROJECT;

  try {
    const rc = JSON.parse(
      fs.readFileSync(path.join(__dirname, "..", ".firebaserc"), "utf8")
    );
    return rc.projects && rc.projects.default;
  } catch (_) {
    return undefined;
  }
}

const projectId = serviceAccount ? serviceAccount.project_id : resolveProjectId();

if (!projectId) {
  console.error(
    "Could not determine which Firebase project to migrate.\n" +
    "Provide a service-account key (see this file's header), or pass " +
    "--project <projectId>."
  );
  process.exit(1);
}

initializeApp({
  credential: serviceAccount ? cert(serviceAccount) : applicationDefault(),
  projectId,
});

const db = getFirestore();

async function main() {
  console.log(`Project: ${projectId}`);
  console.log(
    COMMIT
      ? "MIGRATING private run metrics (writing)."
      : "DRY RUN — nothing will be written. Pass --commit to apply."
  );

  const snapshot = await db.collection("runningSessions").get();
  console.log(`Scanned ${snapshot.size} session(s).`);

  let moved = 0;
  let calorieOnly = 0;
  let untouched = 0;
  let pending = [];

  const flush = async () => {
    if (!COMMIT || pending.length === 0) {
      pending = [];
      return;
    }
    const batch = db.batch();
    for (const op of pending) op(batch);
    await batch.commit();
    pending = [];
  };

  for (const doc of snapshot.docs) {
    const data = doc.data();

    const avg = data.avgHeartRateBpm;
    const max = data.maxHeartRateBpm;
    const hasHeartRate = avg !== undefined || max !== undefined;
    const hasCalories = data.caloriesBurned !== undefined;

    if (!hasHeartRate && !hasCalories) {
      untouched += 1;
      continue;
    }

    const strip = {};
    if (hasCalories) strip.caloriesBurned = FieldValue.delete();

    if (hasHeartRate) {
      // The owner is needed on the private document itself: the security rule
      // authorizes against it rather than doing a get() on the parent session,
      // which would be a billed read on every evaluation. A session with no
      // userId cannot be protected that way, so its heart rate is deleted
      // rather than moved — an unattributable body metric is not worth
      // keeping, and leaving it in place would leave it public.
      const userId = data.userId;

      strip.avgHeartRateBpm = FieldValue.delete();
      strip.maxHeartRateBpm = FieldValue.delete();

      if (typeof userId === "string" && userId.length > 0) {
        const metrics = { userId };
        if (avg !== undefined) metrics.avgHeartRateBpm = avg;
        if (max !== undefined) metrics.maxHeartRateBpm = max;

        const privateRef = doc.ref.collection("private").doc("metrics");
        pending.push((batch) => batch.set(privateRef, metrics, { merge: true }));
      } else {
        console.warn(
          `  ${doc.id}: heart rate present but no userId — deleting rather ` +
          `than moving (cannot be secured without an owner).`
        );
      }
      moved += 1;
    } else {
      calorieOnly += 1;
    }

    pending.push((batch) => batch.update(doc.ref, strip));

    // Two ops per session worst case, and a Firestore batch caps at 500.
    if (pending.length >= BATCH_LIMIT) await flush();
  }

  await flush();

  console.log(
    `\nHeart rate moved to private/metrics: ${moved}` +
    `\nCalories-only cleanup:               ${calorieOnly}` +
    `\nAlready migrated / nothing to do:    ${untouched}`
  );
  if (!COMMIT) console.log("\nDry run: no writes were made.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
