const functions = require("firebase-functions/v1"); // Modulo Gen 1
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore"); // Modulo Gen 2
const admin = require('firebase-admin');
const { getFirestore } = require('firebase-admin/firestore'); // Import esplicito
const geo = require('./geo');
const territory = require('./territory');
const routing = require('./routing');
const { onSchedule } = require("firebase-functions/v2/scheduler");

admin.initializeApp();
const db = getFirestore(); // Inizializzazione sicura

// Server-side ORS proxy — see routing.js for why this exists (moves the
// OpenRouteService API key out of the client entirely).
exports.orsRoute = routing.orsRoute;

// 1. INIZIALIZZAZIONE PROFILO (Restiamo su Gen 1 per l'Auth)
exports.seedUserProfileAndBadges = functions
  .region('europe-west1')
  .auth.user().onCreate(async (user) => {
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
        followersCount: 0,
        followingCount: 0,
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

// 2. CALCOLO AGGREGATO 
// FIXED: Switched to onDocumentUpdated. Only runs when pointsEarned is finally processed.
exports.onRunningSessionCompleted = onDocumentUpdated(
  {
    document: 'runningSessions/{sessionId}',
    region: 'europe-west1'
  }, 
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();

    // Only proceed if pointsProcessed just flipped to true
    if (before.pointsProcessed === true || after.pointsProcessed !== true) {
      return null;
    }

    const sessionData = after;
    const userId = sessionData.userId;
    const statsRef = db.collection('userStats').doc(userId);

    const currentDistance = Number(sessionData.distanceMeters || 0);
    const currentDuration = Number(sessionData.durationMs || 0); 
    const currentCalories = Number(sessionData.caloriesBurned || 0);
    const currentLoops = Number(sessionData.loopsCompleted || 0);
    
    const currentMaxPace = Number(sessionData.maxPaceMinPerKm || 0);
    const currentMaxSpeedKmh = currentMaxPace > 0 ? (60 / currentMaxPace) : 0;
    
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
          maxAvgSpeedKmh: currentAvgSpeedKmh,
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
          maxAvgSpeedKmh: Math.max(existingBest.maxAvgSpeedKmh || 0, currentAvgSpeedKmh),
          maxCaloriesBurned: Math.max(existingBest.maxCaloriesBurned || 0, currentCalories),
          maxLoopsCompleted: Math.max(existingBest.maxLoopsCompleted || 0, currentLoops)
        };
      }

      stats.updatedAt = admin.firestore.FieldValue.serverTimestamp();
      transaction.set(statsRef, stats, { merge: true });
    });
  }
);

exports.matchDrawnPath = require('./routing').matchDrawnPath;

const XP_PER_KM = 100;
const AREA_M2_PER_XP = 1000;
const STOLEN_AREA_M2_PER_XP = 333;

// 3. CLAIM DELLE AREE E ASSEGNAZIONE PUNTI
exports.onRunningSessionCreateClaimedAreas = onDocumentCreated(
  {
    document: 'runningSessions/{sessionId}',
    region: 'europe-west1'
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;

    const sessionData = snapshot.data();
    const closedLoops = Array.isArray(sessionData.closedLoops) ? sessionData.closedLoops : [];

    const userId = sessionData.userId;
    const sessionId = event.params.sessionId;

    let sessionTotalAreaM2 = 0;
    let sessionStolenAreaM2 = 0;

    for (let index = 0; index < closedLoops.length; index++) {
      const points = closedLoops[index] && closedLoops[index].points;
      if (!Array.isArray(points) || points.length < 3) continue;
      try {
        const loopResult = await claimLoop({userId, sessionId, loopIndex: index, points, sessionData});
        sessionTotalAreaM2 += loopResult.totalAreaM2;
        sessionStolenAreaM2 += loopResult.stolenAreaM2;
      } catch (e) {
        console.error(`claimLoop failed for ${sessionId}_${index}:`, e);
      }
    }

    await awardSessionPoints({
      userId,
      sessionId,
      sessionData,
      totalAreaM2: sessionTotalAreaM2,
      stolenAreaM2: sessionStolenAreaM2,
    });
    return null;
  }
);

/** Computes this session's XP, resolves its scoreboard territory from its
 * real start coordinates, updates the user's per-city point total, checks
 * if the user just entered that city's Top 10, and writes everything
 * (session doc, profile total, city stats, rank, notification) atomically
 * where it matters. */
async function awardSessionPoints({userId, sessionId, sessionData, totalAreaM2, stolenAreaM2}) {
  const distanceKm = Number(sessionData.distanceMeters || 0) / 1000;
  const xpFromDistance = distanceKm * XP_PER_KM;
  const xpFromArea = totalAreaM2 / AREA_M2_PER_XP;
  const xpFromStolenArea = stolenAreaM2 / STOLEN_AREA_M2_PER_XP;
  const xp = Math.round(xpFromDistance + xpFromArea + xpFromStolenArea);

  const path = sessionData.path;
  const start = Array.isArray(path) && path.length > 0 ? path[0] : null;

  // Usa startLocality (stessa fonte della leaderboard) invece di
  // richiamare territory.resolveTerritory per la città.
  const startLocality = sessionData.startLocality || null;
  const resolvedBroad = start ?
    await territory.resolveTerritory(start.latitude, start.longitude) :
    {broad: null, broadType: null};

  const city = startLocality; // ← ora coerente con la leaderboard

  const batch = db.batch();
  batch.update(db.collection('runningSessions').doc(sessionId), {
    pointsEarned: xp,
    territoryCity: city,
    territoryBroad: resolvedBroad.broad,
    territoryBroadType: resolvedBroad.broadType,
    totalAreaM2,
    stolenAreaM2,
    xpFromDistance,
    xpFromArea,
    xpFromStolenArea,
    pointsProcessed: true,
  });
  batch.set(
    db.collection('profiles').doc(userId),
    {totalPoints: admin.firestore.FieldValue.increment(xp)},
    {merge: true}
  );
  await batch.commit();

  if (city) {
    await updateCityRankAndNotify({userId, city, xp});
  }
}

/** Increments the user's point total for this specific city, computes their
 * new rank in that city's leaderboard via a count() aggregation query, and
 * fires a "leaderboardCityEntry" notification the first time */
async function updateCityRankAndNotify({userId, city, xp}) {
  const cityUserRef = db.collection('cityStats').doc(city).collection('users').doc(userId);

  const {newTotal, previousRank} = await db.runTransaction(async (tx) => {
    const snap = await tx.get(cityUserRef);
    const existing = snap.exists ? snap.data() : {};
    const newTotal = (existing.totalPoints || 0) + xp;
    const previousRank = existing.lastKnownRank || Infinity;

    tx.set(cityUserRef, {
      userId,
      totalPoints: newTotal,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});

    return {newTotal, previousRank};
  });

  const higherScoreSnap = await db.collection('cityStats').doc(city).collection('users')
    .where('totalPoints', '>', newTotal)
    .count()
    .get();
  const newRank = higherScoreSnap.data().count + 1;

  const TOP_N = 10;
  if (newRank <= TOP_N && previousRank > TOP_N) {
    const profileDoc = await db.collection('profiles').doc(userId).get();
    const profileData = profileDoc.exists ? profileDoc.data() : {};
    const displayName = profileData.displayName || profileData.username || 'Someone';

    await db.collection('notifications').add({
      userId,
      type: 'leaderboardCityEntry',
      actorName: '',
      message: `Congratulations, ${displayName}! You entered the Top 10 leaderboard for ${city}.`,
      cityName: city,
      rank: newRank,
      actorId: 'system',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      isRead: false,
    });
  }

  await cityUserRef.set({lastKnownRank: newRank}, {merge: true});
}

async function claimLoop({userId, sessionId, loopIndex, points, sessionData}) {
  const areasRef = db.collection('claimedAreas');
  const notificationsRef = db.collection('notifications');
  const profilesRef = db.collection('profiles'); 
  const areaId = `${sessionId}_${loopIndex}`;
  const bounds = geo.geohashBoundsForLoop(points);

  return db.runTransaction(async (tx) => {
    // ── Reads first ──
    const candidateDocs = new Map();
    for (const [start, end] of bounds) {
      const snap = await tx.get(areasRef.orderBy('geohash').startAt(start).endAt(end));
      for (const doc of snap.docs) {
        if (doc.id !== areaId) candidateDocs.set(doc.id, doc);
      }
    }

    const candidates = [];
    for (const doc of candidateDocs.values()) {
      const data = doc.data();
      if (data.deleted) continue;
      candidates.push({
        id: doc.id,
        userId: data.userId,
        polygon: data.polygon,
        contributions: (data.contributions || []).map((c) => ({
          sessionId: c.sessionId,
          durationMs: c.durationMs,
          avgPaceMinPerKm: c.avgPaceMinPerKm,
          conquestDateMillis: c.conquestDate ? c.conquestDate.toMillis() : Date.now(),
        })),
        createdAtMillis: data.createdAt ? data.createdAt.toMillis() : null,
      });
    }

    const thiefDoc = await tx.get(profilesRef.doc(userId));
    const thiefData = thiefDoc.data();
    const thiefName = thiefData ? (thiefData.displayName || thiefData.username || "Someone") : "Someone";
    const thiefImageUrl = thiefData ? (thiefData.profileImageUrl || "") : "";

    // ── Pure geometry computation (no Firestore calls) ──────────────────
    const result = geo.computeClaim({
      newLoopPoints: points,
      userId,
      sessionId,
      loopIndex,
      candidates,
      sessionData,
      now: Date.now(),
    });

    // Resolve each stolen-area update back to the user it was taken from,
    // once, so both the "Coup" check below and the write loop further down
    // don't each re-derive it from `candidates`.
    const victimIdByUpdateId = new Map();
    for (const u of result.otherOwnerUpdates) {
      const originalCandidate = candidates.find(c => c.id === u.id);
      victimIdByUpdateId.set(u.id, originalCandidate ? originalCandidate.userId : null);
    }

    // "Coup" badge ("Take the duke area"): if any area actually taken this
    // loop belonged to a user who currently holds the "Duke" badge (100% of
    // their city), the thief unlocks "Coup". Must happen here, before any
    // writes below — a Firestore transaction requires every read to happen
    // before the first write, and which victims exist is only known now,
    // after `computeClaim` has run.
    const victimIds = new Set(
      [...victimIdByUpdateId.values()].filter((id) => id && id !== userId)
    );
    let stoleFromDuke = false;
    for (const victimId of victimIds) {
      const dukeProgressSnap = await tx.get(
        profilesRef.doc(victimId).collection('badge_progress').doc('duke')
      );
      if (dukeProgressSnap.exists && dukeProgressSnap.data().unlocked === true) {
        stoleFromDuke = true;
        break;
      }
    }

    // ── Writes ────────────────────────────────────────────────────────
    const toGeoPoint = (p) => new admin.firestore.GeoPoint(p.latitude, p.longitude);
    const polygonToFirestore = (polygon) => polygon.map((piece) => ({
      outer: piece.outer.map(toGeoPoint),
      holes: piece.holes.map((h) => ({points: h.points.map(toGeoPoint)})),
    }));

    tx.set(areasRef.doc(result.areaId), {
      userId: result.newArea.userId,
      polygon: polygonToFirestore(result.newArea.polygon),
      contributions: result.newArea.contributions.map((c) => ({
        sessionId: c.sessionId,
        durationMs: c.durationMs,
        avgPaceMinPerKm: c.avgPaceMinPerKm,
        conquestDate: admin.firestore.Timestamp.fromMillis(c.conquestDateMillis),
      })),
      startLocality: result.newArea.startLocality,
      geohash: result.newArea.geohash,
      createdAt: result.newArea.earliestCreatedAtMillis != null
        ? admin.firestore.Timestamp.fromMillis(result.newArea.earliestCreatedAtMillis)
        : admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      deleted: false,
    });

    for (const id of result.deletes) {
      tx.delete(areasRef.doc(id));
    }

    for (const u of result.otherOwnerUpdates) {
      const victimId = victimIdByUpdateId.get(u.id);

      if (victimId && victimId !== userId) {
         const notifRef = notificationsRef.doc();
         tx.set(notifRef, {
            userId: victimId, 
            type: "areaStolen", 
            actorName: thiefName,
            message: "has stolen a piece of your territory.", 
            actorImageUrl: thiefImageUrl,
            actorId: userId,
            sessionId: sessionId, 
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            isRead: false,
         });
      }

      if (u.deleted) {
        tx.update(areasRef.doc(u.id), {
          deleted: true,
          polygon: [],
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(areasRef.doc(u.id), {
          polygon: polygonToFirestore(u.polygon),
          geohash: u.geohash,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    if (stoleFromDuke) {
      tx.set(
        profilesRef.doc(userId).collection('badge_progress').doc('coup'),
        {
          badgeId: 'coup',
          progress: 1,
          unlocked: true,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true}
      );
    }

    return {totalAreaM2: result.totalAreaM2, stolenAreaM2: result.stolenAreaM2};
  });
}

// ==============================================================================
// ── NOTIFICATIONS (Gen 2) ──
// ==============================================================================

exports.notifyNewFollower = onDocumentCreated(
    {
        document: "follows/{followId}",
        region: "europe-west1"
    },
    async (event) => {
        const followData = event.data.data();
        if (!followData) return null;

        const followerId = followData.followerId;
        const followingId = followData.followingId;

        try {
            const followerDoc = await db.collection("profiles").doc(followerId).get();
            if (!followerDoc.exists) return null;

            const followerProfile = followerDoc.data();
            const followerName = followerProfile.displayName || followerProfile.username || "Someone";
            const followerImageUrl = followerProfile.profileImageUrl || "";

            await db.collection("notifications").add({
                userId: followingId, 
                type: "newFollower", 
                actorName: followerName, 
                message: "started following you.", 
                actorImageUrl: followerImageUrl,
                actorId: followerId, 
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                isRead: false,
            });

            console.log(`Notification 'newFollower' created for ${followingId}`);
            return null;

        } catch (error) {
            console.error("Error in notifyNewFollower:", error);
            return null;
        }
    }
);


exports.notifyRouteSaved = onDocumentCreated(
    {
        document: "favoriteRoutes/{favId}",
        region: "europe-west1"
    },
    async (event) => {
        const favData = event.data.data();
        if (!favData) return null;

        const saverId = favData.userId; 
        const routeId = favData.routeId; 

        try {
            const routeDoc = await db.collection("routes").doc(routeId).get();
            if (!routeDoc.exists) return null;
            const routeData = routeDoc.data();
            const authorId = routeData.userId;
            const routeName = routeData.name || "Untitled";

            if (authorId === saverId) return null;

            const saverProfileDoc = await db.collection("profiles").doc(saverId).get();
            if (!saverProfileDoc.exists) return null;
            const saverProfile = saverProfileDoc.data();
            const saverName = saverProfile.displayName || saverProfile.username || "Someone";
            const saverImageUrl = saverProfile.profileImageUrl || "";

            await db.collection("notifications").add({
                userId: authorId, 
                type: "routeSaved", 
                actorName: saverName, 
                message: `saved your route '${routeName}' to their favorites.`, 
                actorImageUrl: saverImageUrl,
                actorId: saverId,
                routeId: routeId, 
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                isRead: false,
            });

            console.log(`Notification 'routeSaved' created for author ${authorId}`);
            return null;

        } catch (error) {
            console.error("Error in notifyRouteSaved:", error);
            return null;
        }
    }
);


exports.notifyNewRouteFromFollowing = onDocumentCreated(
    {
        document: "routes/{routeId}",
        region: "europe-west1"
    },
    async (event) => {
        const routeData = event.data.data();
        if (!routeData) return null;

        if (routeData.isPublic !== true) return null;

        const authorId = routeData.userId;
        const routeId = event.params.routeId;
        const routeName = routeData.name || "Untitled";

        try {
            const authorDoc = await db.collection("profiles").doc(authorId).get();
            if (!authorDoc.exists) return null;
            const authorData = authorDoc.data();
            const authorName = authorData.displayName || authorData.username || "Someone";
            const authorImageUrl = authorData.profileImageUrl || "";

            const followersSnap = await db.collection("follows")
                .where("followingId", "==", authorId)
                .get();

            if (followersSnap.empty) return null;

            console.log(`Sending 'newRoutePublished' notifications to ${followersSnap.size} followers of ${authorId}`);

            let batch = db.batch();
            let count = 0;
            const now = admin.firestore.FieldValue.serverTimestamp();

            for (const followDoc of followersSnap.docs) {
                const followerId = followDoc.data().followerId;
                
                if (followerId === authorId) continue;

                const notifRef = db.collection("notifications").doc();
                batch.set(notifRef, {
                    userId: followerId, 
                    type: "newRoutePublished", 
                    actorName: authorName, 
                    message: `published a new public route: '${routeName}'.`, 
                    actorImageUrl: authorImageUrl,
                    actorId: authorId,
                    routeId: routeId, 
                    createdAt: now,
                    isRead: false,
                });

                count++;
                if (count === 499) {
                    await batch.commit();
                    batch = db.batch();
                    count = 0;
                }
            }

            if (count > 0) {
                await batch.commit();
            }
            return null;

        } catch (error) {
            console.error("Error in notifyNewRouteFromFollowing:", error);
            return null;
        }
    }
);

// FIXED: Switched to onDocumentUpdated & added Transaction to prevent race conditions
// FIXED: Reads before writes inside the transaction
exports.notifyRouteRunFaster = onDocumentUpdated(
    {
        document: "runningSessions/{sessionId}",
        region: "europe-west1"
    },
    async (event) => {
        const before = event.data.before.data();
        const after = event.data.after.data();

        // Only proceed if pointsProcessed just flipped to true
        if (before.pointsProcessed === true || after.pointsProcessed !== true) return null;
        if (!after.routeId || !after.durationMs) return null;

        const runnerId = after.userId;
        const routeId = after.routeId;
        const currentDuration = Number(after.durationMs);

        try {
            const db = admin.firestore();
            const routeRef = db.collection("routes").doc(routeId);
            const runnerProfileRef = db.collection("profiles").doc(runnerId); // Reference ready

            await db.runTransaction(async (transaction) => {
                // ── 1. ALL READS FIRST ──
                const routeDoc = await transaction.get(routeRef);
                
                if (!routeDoc.exists) return;
                const routeData = routeDoc.data();
                const authorId = routeData.userId;
                const routeName = routeData.name || "Untitled";
                
                if (authorId === runnerId) return;

                const previousBest = routeData.bestDurationMs ? Number(routeData.bestDurationMs) : Infinity;

                if (currentDuration < previousBest) {
                    // Read runner profile BEFORE any writes
                    const runnerProfileSnap = await transaction.get(runnerProfileRef);
                    const runnerName = runnerProfileSnap.exists ? (runnerProfileSnap.data().displayName || runnerProfileSnap.data().username) : "Someone";
                    const runnerImage = runnerProfileSnap.exists ? (runnerProfileSnap.data().profileImageUrl || "") : "";

                    // ── 2. ALL WRITES SECOND ──
                    transaction.update(routeRef, {
                        bestDurationMs: currentDuration,
                        recordHolderId: runnerId
                    });

                    const notifRef = db.collection("notifications").doc();
                    transaction.set(notifRef, {
                        userId: authorId,
                        type: "routeRunFaster", 
                        actorName: runnerName,
                        message: `set a new record on your route '${routeName}'!`,
                        actorImageUrl: runnerImage,
                        actorId: runnerId,
                        routeId: routeId,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                        isRead: false,
                    });
                }
            });
            return null;
        } catch (error) {
            console.error("Error in notifyRouteRunFaster:", error);
            return null;
        }
    }
);

// FIXED: Corrected batch variable scope to prevent write reuse after commit
exports.processLeaderboards = onSchedule({
    schedule: "0 2 * * *", 
    timeZone: "Europe/Rome",
    region: "europe-west1"
}, async (event) => {
    try {
        const profilesSnap = await db.collection("profiles")
            .orderBy("totalPoints", "desc")
            .get();

        let currentRank = 1;
        let batch = db.batch(); // Replaced const with let
        let operations = 0;
        const now = admin.firestore.FieldValue.serverTimestamp();

        for (const doc of profilesSnap.docs) {
            const userData = doc.data();
            const userId = doc.id;
            const previousRank = userData.lastKnownGlobalRank || 999999;

            if (currentRank <= 10 && previousRank > 10) {
                const notifRef = db.collection("notifications").doc();
                batch.set(notifRef, {
                    userId: userId,
                    type: "leaderboardGlobalEntry", 
                    actorName: "",
                    message: `Congratulations! You've entered the Global Top 10!`,
                    actorImageUrl: "",
                    actorId: "system",
                    createdAt: now,
                    isRead: false,
                });
                operations++;
            }

            if (currentRank < previousRank && currentRank <= 100 && previousRank !== 999999) {
                const notifRef = db.collection("notifications").doc();
                batch.set(notifRef, {
                    userId: userId,
                    type: "leaderboardOvertake",
                    actorName: "System",
                    message: `You moved up in the leaderboard! You are now rank #${currentRank}.`,
                    actorImageUrl: "",
                    actorId: "system",
                    createdAt: now,
                    isRead: false,
                });
                operations++;
            }

            batch.update(db.collection("profiles").doc(userId), {
                lastKnownGlobalRank: currentRank
            });
            operations++;

            if (operations >= 490) {
                await batch.commit();
                batch = db.batch(); // Successfully re-instantiate batch object
                operations = 0;
            }
            
            currentRank++;
        }

        if (operations > 0) {
            await batch.commit();
        }

        console.log("Leaderboard calculation completed successfully!");
        
    } catch (error) {
        console.error("Error in leaderboards processing:", error);
    }
});