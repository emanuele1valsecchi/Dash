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
    const snapshot = event.data; 
    if (!snapshot) return null;

    const sessionData = snapshot.data();

    if (!sessionData || sessionData.pointsEarned === undefined) {
      return null;
    }

    const userId = sessionData.userId;
    const db = admin.firestore();
    const statsRef = db.collection('userStats').doc(userId);

    // Dati base
    const currentDistance = Number(sessionData.distanceMeters || 0); // metri
    const currentDuration = Number(sessionData.durationMs || 0);     // ms
    const currentCalories = Number(sessionData.caloriesBurned || 0);
    const currentLoops = Number(sessionData.loopsCompleted || 0);
    
    // Calcoli velocità
    const currentMaxPace = Number(sessionData.maxPaceMinPerKm || 0);
    const currentMaxSpeedKmh = currentMaxPace > 0 ? (60 / currentMaxPace) : 0;
    
    // Calcolo Velocità Media della sessione (km/h)
    const durationHours = currentDuration / 3600000;
    const currentAvgSpeedKmh = durationHours > 0 ? (currentDistance / 1000) / durationHours : 0;

    return db.runTransaction(async (transaction) => {
      const statsDoc = await transaction.get(statsRef);
      
      let stats = {
        userId: userId,
        bestOverall: {
          maxDistanceMeters: currentDistance,
          maxDurationMs: currentDuration,
          maxSpeedKmh: currentMaxSpeedKmh,
          maxAvgSpeedKmh: currentAvgSpeedKmh, // <--- NUOVO RECORD
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
          maxAvgSpeedKmh: Math.max(existingBest.maxAvgSpeedKmh || 0, currentAvgSpeedKmh), // <--- AGGIORNAMENTO
          maxCaloriesBurned: Math.max(existingBest.maxCaloriesBurned || 0, currentCalories),
          maxLoopsCompleted: Math.max(existingBest.maxLoopsCompleted || 0, currentLoops)
        };
      }

      stats.updatedAt = admin.firestore.FieldValue.serverTimestamp();

      transaction.set(statsRef, stats, { merge: true });
    });
  }
);

// 3. CLAIM DELLE AREE (loop chiusi -> claimedAreas)
//
// Un'area viene creata per ogni loop chiuso della sessione, con ID
// deterministico `${sessionId}_${loopIndex}`. L'ownership deve essere
// assegnata lato server (Admin SDK) e non dal client: firestore.rules nega
// `create` su claimedAreas per lo stesso motivo per cui nega i write su
// userStats.
//
// NON gestisce ancora furti/ri-cronometraggio di un'area già rivendicata da
// un altro utente (vedi CLAUDE.md, "Stealing / champion re-timing logic" —
// prossima milestone): ogni loop chiuso genera semplicemente una nuova area,
// anche se si sovrappone a una già esistente.
//
// Nota: niente più colorHex qui — il colore ("mie" vs "altrui") è relativo a
// chi guarda la mappa, quindi è calcolato lato client (ClaimedAreasLayer),
// non una proprietà fissa dell'area.
exports.onRunningSessionCreateClaimedAreas = onDocumentCreated(
  {
    document: 'runningSessions/{sessionId}',
    region: 'europe-west1'
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;

    const sessionData = snapshot.data();
    const closedLoops = sessionData.closedLoops;
    if (!Array.isArray(closedLoops) || closedLoops.length === 0) return null;

    const userId = sessionData.userId;
    const sessionId = event.params.sessionId;
    const db = admin.firestore();
    const batch = db.batch();

    closedLoops.forEach((loop, index) => {
      const points = loop && loop.points;
      if (!Array.isArray(points) || points.length < 3) return;

      const areaRef = db.collection('claimedAreas').doc(`${sessionId}_${index}`);
      batch.set(areaRef, {
        userId: userId,
        sessionId: sessionId,
        polygon: points,
        startLocality: sessionData.startLocality || null,
        // Copied from the session rather than left for the client to look up:
        // a user can't read another user's runningSessions doc (see
        // firestore.rules), so the area-details popup needs these here.
        durationMs: sessionData.durationMs || 0,
        avgPaceMinPerKm: sessionData.avgPaceMinPerKm || null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return batch.commit();
  }
);