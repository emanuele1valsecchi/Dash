const functions = require("firebase-functions/v1"); // Modulo Gen 1
const { onDocumentCreated } = require("firebase-functions/v2/firestore"); // Modulo Gen 2
const admin = require('firebase-admin');

admin.initializeApp();

// 1. INIZIALIZZAZIONE PROFILO (Restiamo su Gen 1 per l'Auth)
exports.seedUserProfileAndBadges = functions
  .region('europe-west1')
  .auth.user().onCreate(async (user) => {
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

// 2. CALCOLO AGGREGATO (Migrato a Gen 2 per supportare eur3 multi-region)
exports.onRunningSessionCompleted = onDocumentCreated(
  {
    document: 'runningSessions/{sessionId}',
    region: 'europe-west1'
  }, 
  async (event) => {
    // Nella Gen 2 lo snapshot è dentro event.data
    const snapshot = event.data; 
    if (!snapshot) return null;

    const sessionData = snapshot.data();

    // Sicurezza: procediamo solo se la sessione esiste ed è effettivamente salvata
    if (!sessionData || sessionData.pointsEarned === undefined) {
      return null;
    }

    const userId = sessionData.userId;
    const db = admin.firestore();
    const statsRef = db.collection('userStats').doc(userId);

    const currentDistance = Number(sessionData.distanceMeters || 0);
    const currentDuration = Number(sessionData.durationMs || 0);
    const currentCalories = Number(sessionData.caloriesBurned || 0);
    const currentLoops = Number(sessionData.loopsCompleted || 0);
    
    const currentMaxPace = Number(sessionData.maxPaceMinPerKm || 0);
    const currentMaxSpeedKmh = currentMaxPace > 0 ? (60 / currentMaxPace) : 0;

    return db.runTransaction(async (transaction) => {
      const statsDoc = await transaction.get(statsRef);
      
      let stats = {
        userId: userId,
        bestOverall: {
          maxDistanceMeters: currentDistance,
          maxDurationMs: currentDuration,
          maxSpeedKmh: currentMaxSpeedKmh,
          maxCaloriesBurned: currentCalories,
          maxLoopsCompleted: currentLoops
        },
        allTime: {
          totalDistanceMeters: currentDistance,
          totalDurationMs: currentDuration,
          totalCaloriesBurned: currentCalories,
          totalSessions: 1,
          totalLoopsCompleted: currentLoops
        }
      };

      if (statsDoc.exists) {
        const existingData = statsDoc.data();
        const existingBest = existingData.bestOverall || {};
        const existingAllTime = existingData.allTime || {};

        stats.allTime = {
          totalDistanceMeters: (existingAllTime.totalDistanceMeters || 0) + currentDistance,
          totalDurationMs: (existingAllTime.totalDurationMs || 0) + currentDuration,
          totalCaloriesBurned: (existingAllTime.totalCaloriesBurned || 0) + currentCalories,
          totalSessions: (existingAllTime.totalSessions || 0) + 1,
          totalLoopsCompleted: (existingAllTime.totalLoopsCompleted || 0) + currentLoops
        };

        stats.bestOverall = {
          maxDistanceMeters: Math.max(existingBest.maxDistanceMeters || 0, currentDistance),
          maxDurationMs: Math.max(existingBest.maxDurationMs || 0, currentDuration),
          maxSpeedKmh: Math.max(existingBest.maxSpeedKmh || 0, currentMaxSpeedKmh),
          maxCaloriesBurned: Math.max(existingBest.maxCaloriesBurned || 0, currentCalories),
          maxLoopsCompleted: Math.max(existingBest.maxLoopsCompleted || 0, currentLoops)
        };
      }

      stats.updatedAt = admin.firestore.FieldValue.serverTimestamp();

      transaction.set(statsRef, stats, { merge: true });
    });
  }
);