/**
 * One-off cleanup: deletes the badges that were early concepts and never got
 * any logic behind them.
 *
 * ## Why a script is needed at all
 *
 * `uploader/badges.json` is only the *seed source*, and `seed_badges.js` does
 * `set(..., { merge: true })` per badge — it never deletes. Removing an entry
 * from that file therefore does nothing to a project that has already been
 * seeded: the `badges/{id}` document stays, and the app keeps showing it,
 * because `BadgeService.getAllBadges` builds its list from that collection.
 *
 * Two things have to go:
 *   1. `badges/{id}` — the definition. This is what makes the badge disappear
 *      from every profile and badge page, and it also stops
 *      `seedUserProfileAndBadges` handing it to new signups, since that
 *      function seeds `badge_progress` by reading this collection.
 *   2. `profiles/{uid}/badge_progress/{id}` — every user's progress row. These
 *      are invisible once (1) is gone (nothing joins against them), so this
 *      half is tidiness rather than correctness — but leaving thousands of
 *      orphans behind to confuse the next person is its own cost.
 *
 * ## Running it
 *
 *   node functions/_wipe_discarded_badges.js            # dry run, prints only
 *   node functions/_wipe_discarded_badges.js --commit   # actually deletes
 *
 * Credentials and project resolution follow `_backfill_area_colors.js` and
 * `_migrate_private_metrics.js`: a service-account key at
 * `uploader/serviceAccountKey.json` (gitignored) or
 * GOOGLE_APPLICATION_CREDENTIALS, else ADC with the project id from
 * `.firebaserc`. The resolved project is printed before anything is written.
 *
 * Not deployed — the `_wipe_*` prefix is in firebase.json's functions ignore
 * list. **Idempotent**: a second run finds nothing left to delete.
 */

const fs = require("fs");
const path = require("path");
const { initializeApp, cert, applicationDefault } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

/**
 * Discarded badge ids. Keep in step with `uploader/badges.json` — anything
 * listed here must NOT be in that file, or the next seed would put it back.
 */
const DISCARDED_BADGE_IDS = [
  "the_defender",
  "the_champion",
  "first_time",
  "by_a_whisker",
  "the_important_thing_is_to_participate",
  "cheetah",
  "turtle",
  "expanding_kingdom",
  "napoleone",
  "buuuu",
  "try_to_beat_me",
  "eat_my_dust",
];

const COMMIT =
  process.argv.includes("--commit") || process.argv.includes("--yes");

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
    "Could not determine which Firebase project to clean.\n" +
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
      ? "DELETING discarded badges (writing)."
      : "DRY RUN — nothing will be deleted. Pass --commit to apply."
  );
  console.log(`Badges to retire: ${DISCARDED_BADGE_IDS.length}`);

  // ── 1. The badge definitions ──
  let definitionsFound = 0;
  for (const id of DISCARDED_BADGE_IDS) {
    const ref = db.collection("badges").doc(id);
    const snap = await ref.get();
    if (!snap.exists) continue;
    definitionsFound += 1;
    console.log(`  badges/${id}`);
    if (COMMIT) await ref.delete();
  }

  // ── 2. Every user's progress rows for them ──
  //
  // Walked per profile rather than with a collection-group query: that would
  // need an index on a subcollection this project has never queried that way,
  // and the profile count here is small.
  const profiles = await db.collection("profiles").get();
  let progressFound = 0;

  for (const profile of profiles.docs) {
    const refs = DISCARDED_BADGE_IDS.map((id) =>
      profile.ref.collection("badge_progress").doc(id)
    );
    const snaps = await db.getAll(...refs);
    const present = snaps.filter((s) => s.exists);
    if (present.length === 0) continue;

    progressFound += present.length;
    console.log(`  profiles/${profile.id}: ${present.length} progress doc(s)`);

    if (COMMIT) {
      const batch = db.batch();
      for (const s of present) batch.delete(s.ref);
      await batch.commit();
    }
  }

  console.log(
    `\nBadge definitions: ${definitionsFound}` +
    `\nProgress documents: ${progressFound} (across ${profiles.size} profile(s))`
  );
  if (!COMMIT) console.log("\nDry run: nothing was deleted.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
