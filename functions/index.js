const functions = require("firebase-functions/v1"); // Gen 1 Module
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore"); // Gen 2 Module
const admin = require('firebase-admin');
const { getFirestore, FieldValue, GeoPoint, Timestamp } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging'); // <-- Add this new line!
const geo = require('./geo');
const territory = require('./territory');
const routing = require('./routing');
const routeCascade = require('./routeCascade');
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getAuth } = require('firebase-admin/auth');

admin.initializeApp();
const db = getFirestore();

// Server-side ORS proxy
exports.orsRoute = routing.orsRoute;

const BADGE_RULES = {
  // ── SESSIONS & LOOPS ──
  'rookie': {
    calculateProgress: (session, stats) => stats.allTime.totalSessions || 0,
    target: 1
  },
  'is_it_a_triangle_or_a_square': {
    calculateProgress: (session, stats) => stats.allTime.totalLoopsCompleted || 0,
    target: 1
  },

  // ── DISTANCE (Working directly in meters) ──
  'warming_up': {
    calculateProgress: (session, stats) => stats.allTime.totalDistanceMeters || 0,
    target: 10000 
  },
  'hot_feet': {
    calculateProgress: (session, stats) => stats.allTime.totalDistanceMeters || 0,
    target: 100000 
  },
  'smoldering_feet': {
    calculateProgress: (session, stats) => stats.allTime.totalDistanceMeters || 0,
    target: 1000000 
  },

  // ── DURATION (Working in milliseconds) ──
  'starter': {
    calculateProgress: (session, stats) => stats.bestOverall?.maxDurationMs || 0,
    target: 1200000 // 20 min
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

  // ── CIRCUITS & CITIES ──
  'home_sweet_home': {
    calculateProgress: (session, stats) => {
      const counts = stats.allTime?.cityCounts || {};
      const values = Object.values(counts);
      return values.length > 0 ? Math.max(...values) : 0;
    },
    target: 10
  },
  'traveller': {
    calculateProgress: (session, stats) => {
      const counts = stats.allTime?.cityCounts || {};
      const validCities = Object.keys(counts).filter(c => c !== 'Unknown');
      return validCities.length;
    },
    target: 5
  },
  'interrail': {
    calculateProgress: (session, stats) => {
      const counts = stats.allTime?.cityCounts || {};
      const validCities = Object.keys(counts).filter(c => c !== 'Unknown');
      return validCities.length;
    },
    target: 10
  },
  'the_foreigner': {
    calculateProgress: (session, stats) => {
      const counts = stats.allTime?.cityCounts || {};
      const validCities = Object.keys(counts).filter(c => c !== 'Unknown');
      return validCities.length > 1 ? 1 : 0;
    },
    target: 1
  },

  // ── CONSISTENCY & STREAKS ──
  'youre_looking_good': {
    calculateProgress: (session, stats) => {
      return stats.allTime?.streakStats?.maxRunsInAWeek || 0;
    },
    target: 2
  },
  'consistent': {
    calculateProgress: (session, stats) => {
      return stats.allTime?.streakStats?.maxConsecutiveWeeks || 0;
    },
    target: 4
  },

  // ── AREA CONQUEST (Cumulative) ──
  'aspiring_boss': {
    calculateProgress: (session, stats) => stats.allTime?.cumulativeAreaM2 || 0,
    target: 500000
  },
  'gym_bro': {
    calculateProgress: (session, stats) => stats.allTime?.cumulativeAreaM2 || 0,
    target: 2000000
  },
  'duke': {
    calculateProgress: (session, stats) => stats.allTime?.cumulativeAreaM2 || 0,
    target: 5000000
  },

  // ── TERRITORY & GAMEPLAY ──
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

// ==============================================================================
// ── PUSH NOTIFICATIONS DISPATCHER ──
// ==============================================================================

/**
 * Helper function that checks user preferences and sends an actual FCM push notification.
 */
async function dispatchPushNotification(userId, type, title, body, extraData = {}) {
    try {
        const userDoc = await db.collection("profiles").doc(userId).get();
        if (!userDoc.exists) return;

        const userData = userDoc.data();
        
        const prefs = userData.pushPreferences || {};
        // If the user opted out, abort.
        if (prefs[type] === false) {
            console.log(`User ${userId} opted out of '${type}' push notifications.`);
            return;
        }

        const tokens = userData.fcmTokens || [];
        if (!Array.isArray(tokens) || tokens.length === 0) {
            return; // No devices registered
        }

        const payload = {
            notification: {
                title: title,
                body: body,
            },
            data: {
                type: type,
                ...extraData
            },
            tokens: tokens
        };

        const response = await getMessaging().sendEachForMulticast(payload);
        
        // Cleanup stale/invalid tokens
        if (response.failureCount > 0) {
            const failedTokens = [];
            response.responses.forEach((resp, idx) => {
                if (!resp.success) {
                    if (resp.error.code === 'messaging/invalid-registration-token' || 
                        resp.error.code === 'messaging/registration-token-not-registered') {
                        failedTokens.push(tokens[idx]);
                    }
                }
            });

            if (failedTokens.length > 0) {
                await db.collection("profiles").doc(userId).update({
                    fcmTokens: FieldValue.arrayRemove(...failedTokens)
                });
            }
        }
    } catch (error) {
        console.error(`Error dispatching push notification to ${userId}:`, error);
    }
}

// ==============================================================================
// ── 1. PROFILE INITIALIZATION (Gen 1) ──
// ==============================================================================
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

// ==============================================================================
// ── 2. AGGREGATE CALCULATION & BADGE EVALUATION ──
// ==============================================================================
exports.onRunningSessionCompleted = onDocumentUpdated(
  {
    document: 'runningSessions/{sessionId}',
    region: 'europe-west1'
  }, 
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();

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
    const currentAreaM2 = Number(sessionData.totalAreaM2 || 0);
    
    const currentMaxPace = Number(sessionData.maxPaceMinPerKm || 0);
    const currentMaxSpeedKmh = currentMaxPace > 0 ? (60 / currentMaxPace) : 0;
    
    const durationHours = currentDuration / 3600000;
    const currentAvgSpeedKmh = durationHours > 0 ? (currentDistance / 1000) / durationHours : 0;

    const currentCity = sessionData.startLocality && sessionData.startLocality.trim() !== '' 
      ? sessionData.startLocality.trim() 
      : 'Unknown';

    // ── 🕒 STREAK ENGINE SETUP ──
    const runDate = sessionData.createdAt ? sessionData.createdAt.toDate() : new Date();
    const day = runDate.getDay();
    const diffToMonday = runDate.getDate() - day + (day === 0 ? -6 : 1);
    const mondayDate = new Date(runDate);
    mondayDate.setDate(diffToMonday);
    mondayDate.setHours(0, 0, 0, 0); 
    const currentWeekMondayMs = mondayDate.getTime();

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
          totalLoopsCompleted: currentLoops,
          cumulativeAreaM2: currentAreaM2,
          cityCounts: { [currentCity]: 1 },
          streakStats: {
            lastRunMondayMs: currentWeekMondayMs,
            runsThisWeek: 1,
            consecutiveWeeks: 1,
            maxRunsInAWeek: 1,
            maxConsecutiveWeeks: 1
          }
        }
      };

      if (statsDoc.exists) {
        const existingData = statsDoc.data();
        const existingBest = existingData.bestOverall || {};
        const existingAllTime = existingData.allTime || {};
        
        const existingCityCounts = existingAllTime.cityCounts || {};
        const updatedCityCounts = { ...existingCityCounts };
        updatedCityCounts[currentCity] = (updatedCityCounts[currentCity] || 0) + 1;

        // ── 🕒 STREAK ENGINE CALCULATION ──
        const existingStreak = existingAllTime.streakStats || {};
        const lastRunMondayMs = existingStreak.lastRunMondayMs || currentWeekMondayMs;
        const diffWeeks = Math.round((currentWeekMondayMs - lastRunMondayMs) / 604800000);

        let runsThisWeek = existingStreak.runsThisWeek || 0;
        let consecutiveWeeks = existingStreak.consecutiveWeeks || 0;

        if (diffWeeks === 0) {
          runsThisWeek += 1;
          if (consecutiveWeeks === 0) consecutiveWeeks = 1; 
        } else if (diffWeeks === 1) {
          runsThisWeek = 1;
          consecutiveWeeks += 1;
        } else {
          runsThisWeek = 1;
          consecutiveWeeks = 1;
        }

        const updatedStreakStats = {
          lastRunMondayMs: currentWeekMondayMs,
          runsThisWeek: runsThisWeek,
          consecutiveWeeks: consecutiveWeeks,
          maxRunsInAWeek: Math.max(existingStreak.maxRunsInAWeek || 0, runsThisWeek),
          maxConsecutiveWeeks: Math.max(existingStreak.maxConsecutiveWeeks || 0, consecutiveWeeks)
        };

        stats.allTime = {
          totalDistanceMeters: (existingAllTime.totalDistanceMeters || 0) + currentDistance,
          totalDurationMs: (existingAllTime.totalDurationMs || 0) + currentDuration,
          totalCaloriesBurned: (existingAllTime.totalCaloriesBurned || 0) + currentCalories,
          totalSessions: (existingAllTime.totalSessions || 0) + 1,
          totalLoopsCompleted: (existingAllTime.totalLoopsCompleted || 0) + currentLoops,
          cumulativeAreaM2: (existingAllTime.cumulativeAreaM2 || 0) + currentAreaM2,
          cityCounts: updatedCityCounts,
          streakStats: updatedStreakStats
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
      
      return stats; 
    });

    if (finalStats) {
      await evaluateBadges(userId, sessionData, finalStats);
    }

    return null;
  }
);

exports.matchDrawnPath = routing.matchDrawnPath;

const XP_PER_KM = 100;
const AREA_M2_PER_XP = 1000;
const STOLEN_AREA_M2_PER_XP = 333;

// ==============================================================================
// ── 3. AREA CLAIMS AND POINTS ASSIGNMENT ──
// ==============================================================================
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
    let sessionVictims = new Set(); 

    for (let index = 0; index < closedLoops.length; index++) {
      const points = closedLoops[index] && closedLoops[index].points;
      if (!Array.isArray(points) || points.length < 3) continue;
      try {
        const loopResult = await claimLoop({userId, sessionId, loopIndex: index, points, sessionData});
        sessionTotalAreaM2 += loopResult.totalAreaM2;
        sessionStolenAreaM2 += loopResult.stolenAreaM2;
        
        if (loopResult.stolenFrom) {
          loopResult.stolenFrom.forEach(v => sessionVictims.add(v));
        }
      } catch (e) {
        console.error(`claimLoop failed for ${sessionId}_${index}:`, e);
      }
    }

    // ── LOGICA BADGE "COUP" ──
    for (const victimId of sessionVictims) {
      const dukeBadgeSnap = await db.collection('profiles').doc(victimId).collection('badge_progress').doc('duke').get();
      if (dukeBadgeSnap.exists && dukeBadgeSnap.data().unlocked === true) {
        await unlockEventBadge(userId, 'coup', "Masterstroke! You stole territory from a Duke!");
        break; 
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
    
    const message = `Congratulations, ${displayName}! You entered the Top 10 leaderboard for ${city}.`;

    await db.collection('notifications').add({
      userId,
      type: 'leaderboardCityEntry',
      actorName: '',
      message: message,
      cityName: city,
      rank: newRank,
      actorId: 'system',
      createdAt: FieldValue.serverTimestamp(),
      isRead: false,
    });

    await dispatchPushNotification(userId, 'leaderboardCityEntry', 'City Top 10!', message, { cityName: city });
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

    let victimsSet = new Set();

    for (const u of result.otherOwnerUpdates) {
      const originalCandidate = candidates.find(c => c.id === u.id);
      const victimId = originalCandidate ? originalCandidate.userId : null;

      if (victimId && victimId !== userId) {
         victimsSet.add(victimId);
         
         const messageStr = "has stolen a piece of your territory.";
         const notifRef = notificationsRef.doc();
         tx.set(notifRef, {
            userId: victimId, 
            type: "areaStolen", 
            actorName: thiefName,
            message: messageStr, 
            actorImageUrl: thiefImageUrl,
            actorId: userId,
            sessionId: sessionId, 
            createdAt: FieldValue.serverTimestamp(),
            isRead: false,
         });

         // Fire and forget push notification (it runs outside the strict transaction await)
         dispatchPushNotification(
            victimId, 
            'areaStolen', 
            'Territory Under Attack!', 
            `${thiefName} ${messageStr}`, 
            { sessionId: sessionId }
         ).catch(e => console.error("Error sending areaStolen push", e));
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

    return {
        totalAreaM2: result.totalAreaM2, 
        stolenAreaM2: result.stolenAreaM2,
        stolenFrom: Array.from(victimsSet)
    };
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
  const unlockedBadgesToPush = [];

  for (const doc of currentProgressSnap.docs) {
    const badgeId = doc.id;
    const currentData = doc.data();
    
    if (currentData.unlocked || !BADGE_RULES[badgeId]) continue;

    const rule = BADGE_RULES[badgeId];
    const rawValue = rule.calculateProgress(sessionData, userStats);
    
    let newProgress = (rawValue / rule.target) * 100;
    if (newProgress > 100) newProgress = 100;
    
    newProgress = Math.round(newProgress * 10) / 10;

    if (newProgress > (currentData.progress || 0)) {
      const isNowUnlocked = newProgress >= 100;
      
      batch.update(doc.ref, {
        progress: newProgress,
        unlocked: isNowUnlocked,
        updatedAt: FieldValue.serverTimestamp()
      });

      if (isNowUnlocked && !currentData.unlocked) {
        const message = `Congratulations! You unlocked the '${badgeId}' badge!`;
        const notifRef = db.collection('notifications').doc();
        batch.set(notifRef, {
          userId: userId,
          type: 'badgeUnlocked', 
          actorName: 'System',
          message: message,
          actorImageUrl: "",
          actorId: "system",
          createdAt: FieldValue.serverTimestamp(),
          isRead: false
        });
        unlockedBadgesToPush.push({ id: badgeId, message: message });
      }
      badgesUpdated++;
    }
  }

  if (badgesUpdated > 0) {
    await batch.commit();
    console.log(`Updated ${badgesUpdated} badges for user ${userId}`);
    
    // Dispatch push notifications for newly unlocked badges
    for (const b of unlockedBadgesToPush) {
        await dispatchPushNotification(userId, 'badgeUnlocked', 'New Badge Unlocked!', b.message, { badgeId: b.id });
    }
  }
}

// ==============================================================================
// ── EVENT-DRIVEN BADGES HELPER ──
// ==============================================================================
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
      
      // Dispatch push notification
      await dispatchPushNotification(uid, 'badgeUnlocked', 'New Badge Unlocked!', notificationMessage, { badgeId: badgeId });
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

    if (after.followingCount >= 1) {
      await unlockEventBadge(uid, 'im_following_you', `Congratulations! You unlocked the 'I'm following you' badge!`);
    }
    
    return null;
  }
);

exports.checkRouteBadges = onDocumentCreated(
  {
    document: "routes/{routeId}",
    region: "europe-west1"
  },
  async (event) => {
    const route = event.data.data();
    if (!route) return null;
    
    const uid = route.userId;
    const city = route.startLocality; 
    
    if (!city || city === 'Unknown') {
        return null;
    }

    const statsRef = db.collection('userStats').doc(uid);
    
    await db.runTransaction(async (tx) => {
        const statsDoc = await tx.get(statsRef);
        let stats = statsDoc.exists ? statsDoc.data() : {};
        let allTime = stats.allTime || {};
        
        let publishedRouteCities = allTime.publishedRouteCities || {};
        publishedRouteCities[city] = (publishedRouteCities[city] || 0) + 1;
        
        allTime.publishedRouteCities = publishedRouteCities;
        tx.set(statsRef, { allTime }, { merge: true });
    });

    const updatedStatsDoc = await statsRef.get();
    const updatedAllTime = updatedStatsDoc.data().allTime || {};
    
    const publishedRouteCities = updatedAllTime.publishedRouteCities || {};
    const runCities = updatedAllTime.cityCounts || {};

    const totalRoutesPublished = Object.values(publishedRouteCities).reduce((a, b) => a + b, 0);
    if (totalRoutesPublished >= 5) {
        await unlockEventBadge(uid, 'local_guide', "Congratulations! You unlocked the 'Local guide' badge!");
    }

    let homeCity = null;
    let maxRuns = 0;
    for (const [c, count] of Object.entries(runCities)) {
        if (count > maxRuns) {
            maxRuns = count;
            homeCity = c;
        }
    }

    if (homeCity && city !== homeCity) {
        await unlockEventBadge(uid, 'spy', "Congratulations! You unlocked the 'Spy' badge!");
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
            const message = "started following you.";

            await db.collection("notifications").add({
                userId: followingId, 
                type: "newFollower", 
                actorName: followerName, 
                message: message, 
                actorImageUrl: followerImageUrl,
                actorId: followerId, 
                createdAt: FieldValue.serverTimestamp(),
                isRead: false,
            });
            
            await dispatchPushNotification(
                followingId, 
                "newFollower", 
                "New Follower!", 
                `${followerName} ${message}`, 
                { actorId: followerId }
            );

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
            const message = `saved your route '${routeName}' to their favorites.`;

            await db.collection("notifications").add({
                userId: authorId, 
                type: "routeSaved", 
                actorName: saverName, 
                message: message, 
                actorImageUrl: saverImageUrl,
                actorId: saverId,
                routeId: routeId, 
                createdAt: FieldValue.serverTimestamp(),
                isRead: false,
            });
            
            await dispatchPushNotification(
                authorId, 
                "routeSaved", 
                "Route Saved!", 
                `${saverName} ${message}`, 
                { routeId: routeId }
            );

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
            const message = `published a new public route: '${routeName}'.`;

            const followersSnap = await db.collection("follows")
                .where("followingId", "==", authorId)
                .get();

            if (followersSnap.empty) return null;

            let batch = db.batch();
            let count = 0;
            const now = FieldValue.serverTimestamp();
            const followersList = [];

            for (const followDoc of followersSnap.docs) {
                const followerId = followDoc.data().followerId;
                if (followerId === authorId) continue;

                followersList.push(followerId);
                const notifRef = db.collection("notifications").doc();
                batch.set(notifRef, {
                    userId: followerId, 
                    type: "newRoutePublished", 
                    actorName: authorName, 
                    message: message, 
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
            
            // Dispatch push notifications to all followers
            for (const followerId of followersList) {
                await dispatchPushNotification(
                    followerId, 
                    "newRoutePublished", 
                    "New Route Available!", 
                    `${authorName} ${message}`, 
                    { routeId: routeId }
                );
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
            const routeRef = db.collection("routes").doc(routeId);
            const runnerProfileRef = db.collection("profiles").doc(runnerId); 
            
            let pushPayload = null;

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
                    const message = `set a new record on your route '${routeName}'!`;

                    transaction.update(routeRef, {
                        bestDurationMs: currentDuration,
                        recordHolderId: runnerId
                    });

                    const notifRef = db.collection("notifications").doc();
                    transaction.set(notifRef, {
                        userId: authorId,
                        type: "routeRunFaster", 
                        actorName: runnerName,
                        message: message,
                        actorImageUrl: runnerImage,
                        actorId: runnerId,
                        routeId: routeId,
                        createdAt: FieldValue.serverTimestamp(),
                        isRead: false,
                    });
                    
                    pushPayload = {
                        authorId,
                        runnerName,
                        message,
                        routeId
                    };
                }
            });
            
            if (pushPayload) {
                await dispatchPushNotification(
                    pushPayload.authorId, 
                    "routeRunFaster", 
                    "Record Beaten!", 
                    `${pushPayload.runnerName} ${pushPayload.message}`, 
                    { routeId: pushPayload.routeId }
                );
            }
            
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
        const pushesToDispatch = [];

        for (const doc of profilesSnap.docs) {
            const userData = doc.data();
            const userId = doc.id;
            const previousRank = userData.lastKnownGlobalRank || 999999;

            if (currentRank <= 10 && previousRank > 10) {
                const message = `Congratulations! You've entered the Global Top 10!`;
                const notifRef = db.collection("notifications").doc();
                batch.set(notifRef, {
                    userId: userId,
                    type: "leaderboardGlobalEntry", 
                    actorName: "",
                    message: message,
                    actorImageUrl: "",
                    actorId: "system",
                    createdAt: now,
                    isRead: false,
                });
                pushesToDispatch.push({userId, type: 'leaderboardGlobalEntry', title: 'Global Top 10!', body: message});
                operations++;
            }

            if (currentRank < previousRank && currentRank <= 100 && previousRank !== 999999) {
                const message = `You moved up in the leaderboard! You are now rank #${currentRank}.`;
                const notifRef = db.collection("notifications").doc();
                batch.set(notifRef, {
                    userId: userId,
                    type: "leaderboardOvertake",
                    actorName: "System",
                    message: message,
                    actorImageUrl: "",
                    actorId: "system",
                    createdAt: now,
                    isRead: false,
                });
                pushesToDispatch.push({userId, type: 'leaderboardOvertake', title: 'Rank Up!', body: message});
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
        
        for (const push of pushesToDispatch) {
            await dispatchPushNotification(push.userId, push.type, push.title, push.body);
        }

        console.log("Leaderboard calculation completed successfully!");
        
    } catch (error) {
        console.error("Error in leaderboards processing:", error);
    }
});

// ==============================================================================
// DATA MANAGEMENT (ACCOUNT PROGRESS WIPE)
// ==============================================================================

/**
 * Deletes all running progress while preserving the user's account,
 * profile data, social relationships, and published routes.
 */
exports.clearUserProgress = functions
  .region("europe-west1")
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "You must be logged in to clear your progress."
      );
    }

    const uid = context.auth.uid;
    const profileRef = db.collection("profiles").doc(uid);

    console.log(`[clearUserProgress] START uid=${uid}`);

    try {
      console.log("[clearUserProgress] Step 1: loading profile");

      const profileSnap = await profileRef.get();
      const profileData = profileSnap.exists ? profileSnap.data() : {};

      console.log(
        `[clearUserProgress] Step 1 OK: profileExists=${profileSnap.exists}`
      );

      console.log("[clearUserProgress] Step 2: deleting runningSessions");

      const sessionsSnap = await db
        .collection("runningSessions")
        .where("userId", "==", uid)
        .get();

      console.log(
        `[clearUserProgress] Step 2 found=${sessionsSnap.size}`
      );

      await deleteDocumentsInBatches(sessionsSnap.docs);

      console.log("[clearUserProgress] Step 2 OK");

      console.log("[clearUserProgress] Step 3: deleting claimedAreas");

      const areasSnap = await db
        .collection("claimedAreas")
        .where("userId", "==", uid)
        .get();

      console.log(
        `[clearUserProgress] Step 3 found=${areasSnap.size}`
      );

      await deleteDocumentsInBatches(areasSnap.docs);

      console.log("[clearUserProgress] Step 3 OK");

      console.log("[clearUserProgress] Step 4: deleting notifications");

      const notificationsSnap = await db
        .collection("notifications")
        .where("userId", "==", uid)
        .get();

      console.log(
        `[clearUserProgress] Step 4 found=${notificationsSnap.size}`
      );

      await deleteDocumentsInBatches(notificationsSnap.docs);

      console.log("[clearUserProgress] Step 4 OK");

      console.log("[clearUserProgress] Step 5: deleting city leaderboard entries");

      const cityStatsSnap = await db.collection("cityStats").get();
      const cityLeaderboardRefs = [];

      for (const cityDoc of cityStatsSnap.docs) {
        const cityUserRef = cityDoc.ref.collection("users").doc(uid);
        const cityUserSnap = await cityUserRef.get();

        if (cityUserSnap.exists) {
          cityLeaderboardRefs.push(cityUserRef);
        }
      }

      console.log(
        `[clearUserProgress] Step 5 found=${cityLeaderboardRefs.length}`
      );

      await deleteReferencesInBatches(cityLeaderboardRefs);

      console.log("[clearUserProgress] Step 5 OK");

      console.log("[clearUserProgress] Step 6: resetting profile score");

      await profileRef.set(
        {
          totalPoints: 0,
          lastKnownGlobalRank: FieldValue.delete(),
        },
        { merge: true }
      );

      console.log("[clearUserProgress] Step 6 OK");

      console.log("[clearUserProgress] Step 7: resetting badge progress");

      const hasProfileImage =
        (typeof profileData?.profileImageUrl === "string" &&
          profileData.profileImageUrl.trim().length > 0) ||
        (typeof profileData?.profileImagePath === "string" &&
          profileData.profileImagePath.trim().length > 0);

      const badgeProgressSnap = await profileRef
        .collection("badge_progress")
        .get();

      const badgeDocsToReset = badgeProgressSnap.docs.filter((doc) => {
        return !(doc.id === "thats_me" && hasProfileImage);
      });

      console.log(
        `[clearUserProgress] Step 7 found=${badgeProgressSnap.size} reset=${badgeDocsToReset.length} hasProfileImage=${hasProfileImage}`
      );

      await resetBadgeDocuments(badgeDocsToReset);

      console.log("[clearUserProgress] Step 7 OK");

      console.log("[clearUserProgress] Step 8: deleting userStats");

      await db.collection("userStats").doc(uid).delete();

      console.log("[clearUserProgress] Step 8 OK");
      console.log(`[clearUserProgress] SUCCESS uid=${uid}`);

      return {
        success: true,
        message: "Progress completely cleared.",
      };
    } catch (error) {
      console.error(`[clearUserProgress] FAILED uid=${uid}`, error);

      throw new functions.https.HttpsError(
        "internal",
        error instanceof Error ? error.message : String(error)
      );
    }
  });

/**
 * Scrubs a deleted user's personal data off the shared routes built from
 * their runs — WITHOUT deleting the routes themselves.
 *
 * A shared route (see `favoriteSession`) is the canonical copy of one run's
 * path, referenced by every user who favourited that run. It has no owner, so
 * the `where('userId', '==', uid)` sweep in `deleteMyAccount` never matches
 * it, and it correctly survives its original runner's account deletion: other
 * users' favourites point at it, and a path through public streets is a
 * geographic fact rather than something the runner authored.
 *
 * What must NOT survive is the part that describes the runner rather than the
 * route: `estimatedTimeMin`/`estimatedCalories` are that run's real measured
 * duration and burn, and `sourceSessionId` is a pointer to their activity
 * record. Those are replaced with distance-based estimates and removed
 * respectively, which also breaks the last link back to a now-deleted person.
 * `startLocality` and the polyline are deliberately kept: both describe where
 * the route goes, and the locality is derivable from the geometry anyway.
 *
 * Every referencing user's `favoriteRoutes` link carries a denormalized copy
 * of those same two measurements, so scrubbing only the route would leave
 * them behind — the links are updated in the same pass.
 *
 * Finding the routes needs no query, no index and no extra field: a shared
 * route's document ID *is* its source session's ID.
 */
async function anonymizeSessionDerivedRoutes(sessionIds) {
  for (const sessionId of sessionIds) {
    const routeRef = db.collection("routes").doc(sessionId);
    const routeSnap = await routeRef.get();
    if (!routeSnap.exists) continue;

    const route = routeSnap.data();
    // Only ownerless (shared) routes are session-derived. An owned route is
    // handled by anonymizeOrDeleteOwnedRoutes instead, and must not be
    // rewritten here even if its ID happened to collide.
    if (!routeCascade.isSharedRoute(route)) continue;

    const { estimatedTimeMin, estimatedCalories } =
      routeCascade.anonymizedRouteStats(route);

    await routeRef.update({
      estimatedTimeMin,
      estimatedCalories,
      sourceSessionId: FieldValue.delete(),
    });

    const links = await db
      .collection("favoriteRoutes")
      .where("routeId", "==", sessionId)
      .get();

    for (let i = 0; i < links.docs.length; i += 450) {
      const chunk = links.docs.slice(i, i + 450);
      const batch = db.batch();

      for (const link of chunk) {
        batch.update(link.ref, { estimatedTimeMin, estimatedCalories });
      }

      await batch.commit();
    }

    console.log(
      `[deleteMyAccount] Anonymized shared route ${sessionId} ` +
      `and ${links.docs.length} link(s) to it`
    );
  }
}

/**
 * Handles the routes a deleted user *owned* — planned by hand, or saved from
 * a parameter search.
 *
 * These were previously left untouched ("published routes are intentionally
 * preserved"), but nothing publishes: `publishRoute` always writes
 * `isPublic: false`, and the read rule only lets a non-owner read a route
 * when `isPublic == true`. So a preserved owned route was unreadable by
 * everyone, forever — the deleted user's personal data kept at cost with no
 * one able to see it.
 *
 * Anything genuinely marked public is preserved as the original comment
 * intended, but with `userId` cleared, so it survives as an ownerless shared
 * route rather than as a document still carrying a deleted user's ID.
 * Everything else is deleted.
 */
async function anonymizeOrDeleteOwnedRoutes(uid) {
  const ownedSnap = await db
    .collection("routes")
    .where("userId", "==", uid)
    .get();

  const toDelete = [];
  const toAnonymize = [];

  for (const doc of ownedSnap.docs) {
    if (routeCascade.ownedRouteDisposition(doc.data()) === "anonymize") {
      toAnonymize.push(doc.ref);
    } else {
      toDelete.push(doc);
    }
  }

  for (let i = 0; i < toAnonymize.length; i += 450) {
    const chunk = toAnonymize.slice(i, i + 450);
    const batch = db.batch();

    for (const ref of chunk) {
      batch.update(ref, { userId: null });
    }

    await batch.commit();
  }

  await deleteDocumentsInBatches(toDelete);

  console.log(
    `[deleteMyAccount] Owned routes: deleted ${toDelete.length}, ` +
    `anonymized ${toAnonymize.length}`
  );
}

/** Deletes documents in chunks below Firestore's 500-operation limit. */
async function deleteDocumentsInBatches(docs) {
  for (let i = 0; i < docs.length; i += 450) {
    const chunk = docs.slice(i, i + 450);
    const batch = db.batch();

    for (const doc of chunk) {
      batch.delete(doc.ref);
    }

    await batch.commit();

    console.log(
      `[clearUserProgress] Deleted ${chunk.length} documents`
    );
  }
}

/** Deletes document references in chunks below Firestore's 500-operation limit. */
async function deleteReferencesInBatches(refs) {
  for (let i = 0; i < refs.length; i += 450) {
    const chunk = refs.slice(i, i + 450);
    const batch = db.batch();

    for (const ref of chunk) {
      batch.delete(ref);
    }

    await batch.commit();

    console.log(
      `[clearUserProgress] Deleted ${chunk.length} references`
    );
  }
}

/** Resets badge documents in chunks below Firestore's 500-operation limit. */
async function resetBadgeDocuments(docs) {
  for (let i = 0; i < docs.length; i += 450) {
    const chunk = docs.slice(i, i + 450);
    const batch = db.batch();

    for (const doc of chunk) {
      batch.update(doc.ref, {
        progress: 0,
        unlocked: false,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();

    console.log(
      `[clearUserProgress] Reset ${chunk.length} badge documents`
    );
  }
}

// ==============================================================================
// FAVOURITE A RUN AS A ROUTE
// ============================================================================

/**
 * Favourites a completed run as a route the caller can re-run later.
 *
 * A favourited run is stored ONCE and shared by everyone who favourites it:
 * the geometry lives in a single `routes` doc whose ID is the source
 * session's ID, and each user gets a small `favoriteRoutes/{uid}_{sessionId}`
 * link pointing at it. The deterministic ID is what makes the sharing
 * collision-free — two users favouriting the same run resolve to the same
 * document without a lookup.
 *
 * This runs server-side, and `firestore.rules` denies the client any write to
 * both the shared route and the link, for one specific reason: the shared
 * document is read by OTHER users. If a client could write it, anyone could
 * pre-create `routes/{sessionId}` for a run nobody had favourited yet and
 * poison the geometry every later user would see. Rules can validate a
 * document's shape but cannot verify that a client-supplied polyline actually
 * matches the run it claims to come from — only a server that reads the
 * session itself can. So the client sends an ID, never geometry, and every
 * stored value here is copied from the session document under the Admin SDK.
 */
exports.favoriteSession = functions
  .region("europe-west1")
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "You must be logged in to favourite a run."
      );
    }

    const uid = context.auth.uid;
    const sessionId = typeof data?.sessionId === "string" ? data.sessionId.trim() : "";
    // Firestore document IDs may not contain '/', and '.'/'..' are reserved.
    if (!sessionId || sessionId.includes("/") || sessionId === "." || sessionId === "..") {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "A valid sessionId is required."
      );
    }

    const rawName = typeof data?.name === "string" ? data.name.trim() : "";
    // Bounded so a client cannot store an unbounded string on its own link.
    const name = (rawName || "Favourited run").slice(0, 120);

    const sessionSnap = await db.collection("runningSessions").doc(sessionId).get();
    if (!sessionSnap.exists) {
      throw new functions.https.HttpsError(
        "not-found",
        "That run no longer exists."
      );
    }

    const session = sessionSnap.data();
    const path = Array.isArray(session.path) ? session.path : [];
    if (path.length < 2) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "That run has no recorded path, so it cannot be favourited."
      );
    }

    const routeRef = db.collection("routes").doc(sessionId);
    const linkRef = db.collection("favoriteRoutes").doc(`${uid}_${sessionId}`);

    // Derived here, from the session, rather than trusted from the caller.
    const distanceMeters = Number(session.distanceMeters) || 0;
    const estimatedTimeMin = (Number(session.durationMs) || 0) / 60000;
    const estimatedCalories = Number(session.caloriesBurned) || 0;
    const isLoop = (Number(session.loopsCompleted) || 0) > 0;
    const loopAreaM2 = Number(session.totalAreaM2) || 0;

    await db.runTransaction(async (tx) => {
      const existingRoute = await tx.get(routeRef);

      // Created once, then never rewritten: later favourites of the same run
      // must not be able to reshape geometry earlier ones already reference.
      if (!existingRoute.exists) {
        tx.set(routeRef, {
          // No owner and no name. The name is per-user and lives on the link
          // below, so two users can call the same route whatever they like.
          userId: null,
          waypoints: [],
          routePolyline: path,
          distanceMeters,
          estimatedTimeMin,
          estimatedCalories,
          isLoop,
          loopAreaM2,
          // Lets every referencing user read it. Exposes nothing new: the
          // session it was copied from is already readable by any signed-in
          // user (see the runningSessions read rule).
          isPublic: true,
          startLocality: session.startLocality ?? null,
          sourceSessionId: sessionId,
          createdAt: FieldValue.serverTimestamp(),
        });
      }

      tx.set(linkRef, {
        userId: uid,
        routeId: sessionId,
        name,
        // Denormalized summary so a favourites list renders from one query
        // without loading a polyline per row. Safe to copy rather than
        // reference: the shared route is immutable once created.
        distanceMeters,
        estimatedTimeMin,
        estimatedCalories,
        isLoop,
        loopAreaM2,
        createdAt: FieldValue.serverTimestamp(),
      });
    });

    return { routeId: sessionId };
  });

// ==============================================================================
// ACCOUNT DELETION
// ============================================================================

/**
 * Deletes all user-owned data while preserving published routes.
 * The Auth account is deleted only after Firestore cleanup succeeds.
 */
exports.deleteMyAccount = functions
  .region("europe-west1")
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "You must be logged in to delete your account."
      );
    }

    const uid = context.auth.uid;
    const profileRef = db.collection("profiles").doc(uid);

    console.log(`[deleteMyAccount] START uid=${uid}`);

    try {
      const profileSnap = await profileRef.get();
      const profileData = profileSnap.exists ? profileSnap.data() : {};

      // ── Route cascade, BEFORE anything is deleted ────────────────────────
      //
      // Order matters: a shared route derived from a run is found by its
      // document ID, which is that run's ID. Once the runningSessions docs
      // below are gone there is no way left to enumerate them, so the IDs
      // have to be captured first.
      //
      // Routes are deliberately NOT deleted wholesale. A route another user
      // favourited outlives its original runner — see
      // anonymizeSessionDerivedRoutes for the full reasoning — it is only
      // stripped of what described that runner.
      const ownSessionsSnap = await db
        .collection("runningSessions")
        .where("userId", "==", uid)
        .get();
      const ownSessionIds = ownSessionsSnap.docs.map((doc) => doc.id);

      await anonymizeSessionDerivedRoutes(ownSessionIds);
      await anonymizeOrDeleteOwnedRoutes(uid);

      // Delete user-owned documents from top-level collections.
      const collectionsToDelete = [
        "runningSessions",
        "claimedAreas",
        "notifications",
        "favoriteRoutes",
        "follows",
        "userStats",
      ];

      for (const collectionName of collectionsToDelete) {
        const snapshot = await db
          .collection(collectionName)
          .where("userId", "==", uid)
          .get();

        await deleteDocumentsInBatches(snapshot.docs);

        // Some relationship documents may use followerId/followingId
        // instead of userId.
        if (collectionName === "follows") {
          const followerSnapshot = await db
            .collection("follows")
            .where("followerId", "==", uid)
            .get();

          const followingSnapshot = await db
            .collection("follows")
            .where("followingId", "==", uid)
            .get();

          const relationshipDocs = new Map();
          for (const doc of followerSnapshot.docs) {
            relationshipDocs.set(doc.id, doc);
          }
          for (const doc of followingSnapshot.docs) {
            relationshipDocs.set(doc.id, doc);
          }

          await deleteDocumentsInBatches(
            Array.from(relationshipDocs.values())
          );
        }
      }

      // Remove the user from every city leaderboard.
      const cityStatsSnap = await db.collection("cityStats").get();
      const cityLeaderboardRefs = [];

      for (const cityDoc of cityStatsSnap.docs) {
        const cityUserRef = cityDoc.ref.collection("users").doc(uid);
        const cityUserSnap = await cityUserRef.get();

        if (cityUserSnap.exists) {
          cityLeaderboardRefs.push(cityUserRef);
        }
      }

      await deleteReferencesInBatches(cityLeaderboardRefs);

      // Delete all profile subcollections, including badge_progress.
      const profileSubcollections = ["badge_progress"];

      for (const subcollectionName of profileSubcollections) {
        const subcollectionSnap = await profileRef
          .collection(subcollectionName)
          .get();

        await deleteDocumentsInBatches(subcollectionSnap.docs);
      }

      // Delete the profile document itself.
      if (profileSnap.exists) {
        await profileRef.delete();
      }

      // Delete profile image from Storage if a storage path is available.
      const profileImagePath = profileData.profileImagePath;
      if (typeof profileImagePath === "string" && profileImagePath.length > 0) {
        try {
          await admin.storage().bucket().file(profileImagePath).delete();
        } catch (storageError) {
          if (storageError.code !== 404) {
            throw storageError;
          }
        }
      }

      // Routes were handled by the cascade at the top of this function:
      // session-derived shared routes survive (stripped of anything
      // describing this user), public owned routes survive without an owner,
      // and unpublished owned routes are gone.
      await getAuth().deleteUser(uid);

      console.log(`[deleteMyAccount] SUCCESS uid=${uid}`);

      return {
        success: true,
        message:
          "Account and user data deleted. Routes other users saved from your " +
          "runs were kept, with your run data removed from them.",
      };
    } catch (error) {
      console.error(`[deleteMyAccount] FAILED uid=${uid}`, error);

      throw new functions.https.HttpsError(
        "internal",
        error instanceof Error ? error.message : String(error)
      );
    }
  });