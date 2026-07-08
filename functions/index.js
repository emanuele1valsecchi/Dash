const functions = require("firebase-functions/v1");
const admin = require('firebase-admin');

admin.initializeApp();

exports.seedUserProfileAndBadges = functions.auth.user().onCreate(async (user) => {
  const db = admin.firestore();
  const now = admin.firestore.FieldValue.serverTimestamp();

  const profileRef = db.collection('profiles').doc(user.uid);
  const badgesSnapshot = await db.collection('badges').get();

  const batch = db.batch();

  batch.set(
  profileRef,
  {
    uid: user.uid,
    email: user.email || null,
    displayName: user.displayName || null,
    totalPoints: 0,
    profileCompleted: false,
    createdAt: now,
    updatedAt: now,
    },
    { merge: true }
    );

  for (const badgeDoc of badgesSnapshot.docs) {
    const badgeProgressRef = profileRef.collection('badge_progress').doc(badgeDoc.id);

    batch.set(
      badgeProgressRef,
      {
        badgeId: badgeDoc.id,
        progress: 0,
        unlocked: false,
        createdAt: now,
        updatedAt: now,
      },
      { merge: true }
    );
  }

  return batch.commit();
});