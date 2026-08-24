const functions = require("firebase-functions/v1"); // Gen 1 Module
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore"); // Gen 2 Module
const admin = require('firebase-admin');
const { getFirestore, FieldValue, GeoPoint, Timestamp } = require('firebase-admin/firestore');
const geo = require('./geo');
const territory = require('./territory');
const routing = require('./routing');
const { onSchedule } = require("firebase-functions/v2/scheduler");

admin.initializeApp();
const db = getFirestore(); // Safe initialization

// Server-side ORS proxy — see routing.js for why this exists (moves the
// OpenRouteService API key out of the client entirely).
exports.orsRoute = routing.orsRoute;

const BADGE_RULES = {
  // ── SESSIONS & LOOPS ──
  'rookie': {
    // Goes from 0 to 1 session (reads stats.allTime)
    calculateProgress: (session, stats) => stats.allTime.totalSessions || 0,
    target: 1
  },
  'is_it_a_triangle_or_a_square': {
    // Unlocked when at least one shape is closed.
    calculateProgress: (session, stats) => stats.allTime.totalLoopsCompleted || 0,
    target: 1
  },

  // ── DISTANCE (Working directly in meters) ──
  'warming_up': {
    calculateProgress: (session, stats) => stats.allTime.totalDistanceMeters || 0,
    target: 10000 // 10 km in meters
  },
  'hot_feet': {
    calculateProgress: (session, stats) => stats.allTime.totalDistanceMeters || 0,
    target: 100000 // 100 km in meters
  },
  'smoldering_feet': {
    calculateProgress: (session, stats) => stats.allTime.totalDistanceMeters || 0,
    target: 1000000 // 1000 km in meters
  },

  // ── DURATION (Working in milliseconds fetching maxDurationMs) ──
  'starter': {
    calculateProgress: (session, stats) => stats.bestOverall?.maxDurationMs || 0,
    target: 1200000 // 20 min (20 * 60 * 1000 ms)
  },
  'need_a_break': {
    calculateProgress: (session, stats) => stats.bestOverall?.maxDurationMs || 0,
    target: 2400000 // 40 min
  },
  'great_stamina': {
    calculateProgress: (session, stats) => stats.bestOverall?.maxDurationMs || 0,
    target: 3600000 // 1 hour
  },
  'half_a_marathon': {
    calculateProgress: (session, stats) => stats.bestOverall?.maxDurationMs || 0,
    target: 7200000 // 2 hours
  },

  // ── TERRITORY & GAMEPLAY (Based on the current session) ──
  'its_all_mine': {
    calculateProgress: (session, stats) => session.stolenAreaM2 > 0 ? 1 : 0,
    target: 1
  },
  'cheater': {
    calculateProgress: (session, stats) => {
       const pace = session.maxPaceMinPerKm || 0;
       const kmh = pace > 0 ? (60 / pace) : 0;
       return kmh > 35 ? 1 : 0;
    },
    target: 1
  },
  'buuuu': {
    calculateProgress: (session, stats) => session.beatGhost === true ? 1 : 0,
    target: 1
  },
  'eat_my_dust': {
    calculateProgress: (session, stats) => session.wonChallenge === true ? 1 : 0,
    target: 1
  },
  'by_a_whisker': {
    calculateProgress: (session, stats) => session.stoppedNearEnd === true ? 1 : 0,
    target: 1
  }
};

// 1. PROFILE INITIALIZATION (Keeping Gen 1 for Auth)
exports.seedUserProfileAndBadges = functions
  .region('europe-west1')
  .auth.user().onCreate(async (user) => {
    const now = FieldValue.serverTimestamp();

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

// 2. AGGREGATE CALCULATION & BADGE EVALUATION
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

    // Execute the transaction and SAVE the final stats in finalStats
    const finalStats = await db.runTransaction(async (transaction) => {
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

      stats.updatedAt = FieldValue.serverTimestamp();
      transaction.set(statsRef, stats, { merge: true });
      
      return stats; // Return the object to use it later!
    });

    // ── BADGES EVALUATION ──
    if (finalStats) {
      await evaluateBadges(userId, sessionData, finalStats);
    }

    return null;
  }
);

exports.matchDrawnPath = require('./routing').matchDrawnPath;

const XP_PER_KM = 100;
const AREA_M2_PER_XP = 1000;
const STOLEN_AREA_M2_PER_XP = 333;

// 3. AREA CLAIMS AND POINTS ASSIGNMENT
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

  const startLocality = sessionData.startLocality || null;
  const resolvedBroad = start ?
    await territory.resolveTerritory(start.latitude, start.longitude) :
    {broad: null, broadType: null};

  const city = startLocality;

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
    {totalPoints: FieldValue.increment(xp)},
    {merge: true}
  );
  await batch.commit();

  if (city) {
    await updateCityRankAndNotify({userId, city, xp});
  }
}

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
      updatedAt: FieldValue.serverTimestamp(),
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
      createdAt: FieldValue.serverTimestamp(),
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

    const result = geo.computeClaim({
      newLoopPoints: points,
      userId,
      sessionId,
      loopIndex,
      candidates,
      sessionData,
      now: Date.now(),
    });

    const toGeoPoint = (p) => new GeoPoint(p.latitude, p.longitude);
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
        conquestDate: Timestamp.fromMillis(c.conquestDateMillis),
      })),
      startLocality: result.newArea.startLocality,
      geohash: result.newArea.geohash,
      createdAt: result.newArea.earliestCreatedAtMillis != null
        ? Timestamp.fromMillis(result.newArea.earliestCreatedAtMillis)
        : FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      deleted: false,
    });

    for (const id of result.deletes) {
      tx.delete(areasRef.doc(id));
    }

    for (const u of result.otherOwnerUpdates) {
      const originalCandidate = candidates.find(c => c.id === u.id);
      const victimId = originalCandidate ? originalCandidate.userId : null;

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
            createdAt: FieldValue.serverTimestamp(),
            isRead: false,
         });
      }

      if (u.deleted) {
        tx.update(areasRef.doc(u.id), {
          deleted: true,
          polygon: [],
          updatedAt: FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(areasRef.doc(u.id), {
          polygon: polygonToFirestore(u.polygon),
          geohash: u.geohash,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    }

    return {totalAreaM2: result.totalAreaM2, stolenAreaM2: result.stolenAreaM2};
  });
}

/**
 * Evaluates badge progress based on the rules defined in BADGE_RULES.
 */
async function evaluateBadges(userId, sessionData, userStats) {
  const badgeProgressRef = db.collection('profiles').doc(userId).collection('badge_progress');
  const currentProgressSnap = await badgeProgressRef.get();
  
  const batch = db.batch();
  let badgesUpdated = 0;

  for (const doc of currentProgressSnap.docs) {
    const badgeId = doc.id;
    const currentData = doc.data();
    
    // Skip if already unlocked or not in BADGE_RULES
    if (currentData.unlocked || !BADGE_RULES[badgeId]) continue;

    const rule = BADGE_RULES[badgeId];
    const rawValue = rule.calculateProgress(sessionData, userStats);
    
    // Calculate 0-100 percentage (capped at 100)
    let newProgress = (rawValue / rule.target) * 100;
    if (newProgress > 100) newProgress = 100;
    
    // Round to one decimal (e.g. 45.5)
    newProgress = Math.round(newProgress * 10) / 10;

    // Update only if there is an advancement
    if (newProgress > (currentData.progress || 0)) {
      const isNowUnlocked = newProgress >= 100;
      
      batch.update(doc.ref, {
        progress: newProgress,
        unlocked: isNowUnlocked,
        updatedAt: FieldValue.serverTimestamp()
      });

      // If unlocked for the first time, notify the user
      if (isNowUnlocked && !currentData.unlocked) {
        const notifRef = db.collection('notifications').doc();
        batch.set(notifRef, {
          userId: userId,
          type: 'badgeUnlocked', // (Remember to add it to the Flutter enum!)
          actorName: 'System',
          message: `Congratulations! You unlocked the '${badgeId}' badge!`,
          actorImageUrl: "",
          actorId: "system",
          createdAt: FieldValue.serverTimestamp(),
          isRead: false
        });
      }
      badgesUpdated++;
    }
  }

  if (badgesUpdated > 0) {
    await batch.commit();
    console.log(`Aggiornati ${badgesUpdated} badge per l'utente ${userId}`);
  }
}

// ==============================================================================
// ── EVENT-DRIVEN BADGES HELPER ──
// ==============================================================================

/**
 * Helper function to instantly unlock event-driven badges (non-running related).
 * It checks if the badge is already unlocked, and if not, unlocks it and sends a notification.
 */
async function unlockEventBadge(uid, badgeId, notificationMessage) {
  const badgeRef = db.collection('profiles').doc(uid).collection('badge_progress').doc(badgeId);
  const badgeSnap = await badgeRef.get();

  if (badgeSnap.exists) {
    const badgeData = badgeSnap.data();
    
    if (badgeData.unlocked !== true) {
      const batch = db.batch();
      
      batch.update(badgeRef, {
        progress: 100,
        unlocked: true,
        updatedAt: FieldValue.serverTimestamp()
      });

      const notifRef = db.collection('notifications').doc();
      batch.set(notifRef, {
        userId: uid,
        type: 'badgeUnlocked',
        actorName: 'System',
        message: notificationMessage,
        actorImageUrl: "",
        actorId: "system",
        createdAt: FieldValue.serverTimestamp(),
        isRead: false
      });

      await batch.commit();
      console.log(`Badge '${badgeId}' unlocked for user ${uid}`);
    }
  }
}

exports.checkProfileBadges = onDocumentUpdated(
  {
    document: "profiles/{uid}",
    region: "europe-west1"
  },
  async (event) => {
    const after = event.data.after.data();
    const uid = event.params.uid;

    const hasImageNow = after.profileImageUrl && after.profileImageUrl.trim() !== "";
    const isCompletedNow = after.profileCompleted === true;

    if (hasImageNow && isCompletedNow) {
      await unlockEventBadge(uid, 'thats_me', `Congratulations! You unlocked the 'That's me' badge!`);
    }
    
    return null;
  }
);


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
                createdAt: FieldValue.serverTimestamp(),
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
                createdAt: FieldValue.serverTimestamp(),
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
            const now = FieldValue.serverTimestamp();

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

exports.notifyRouteRunFaster = onDocumentUpdated(
    {
        document: "runningSessions/{sessionId}",
        region: "europe-west1"
    },
    async (event) => {
        const before = event.data.before.data();
        const after = event.data.after.data();

        if (before.pointsProcessed === true || after.pointsProcessed !== true) return null;
        if (!after.routeId || !after.durationMs) return null;

        const runnerId = after.userId;
        const routeId = after.routeId;
        const currentDuration = Number(after.durationMs);

        try {
            const db = getFirestore();
            const routeRef = db.collection("routes").doc(routeId);
            const runnerProfileRef = db.collection("profiles").doc(runnerId); 

            await db.runTransaction(async (transaction) => {
                const routeDoc = await transaction.get(routeRef);
                
                if (!routeDoc.exists) return;
                const routeData = routeDoc.data();
                const authorId = routeData.userId;
                const routeName = routeData.name || "Untitled";
                
                if (authorId === runnerId) return;

                const previousBest = routeData.bestDurationMs ? Number(routeData.bestDurationMs) : Infinity;

                if (currentDuration < previousBest) {
                    const runnerProfileSnap = await transaction.get(runnerProfileRef);
                    const runnerName = runnerProfileSnap.exists ? (runnerProfileSnap.data().displayName || runnerProfileSnap.data().username) : "Someone";
                    const runnerImage = runnerProfileSnap.exists ? (runnerProfileSnap.data().profileImageUrl || "") : "";

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
                        createdAt: FieldValue.serverTimestamp(),
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
        let batch = db.batch(); 
        let operations = 0;
        const now = FieldValue.serverTimestamp();

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
                batch = db.batch(); 
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