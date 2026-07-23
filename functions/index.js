const functions = require("firebase-functions/v1"); // Modulo Gen 1
const { onDocumentCreated } = require("firebase-functions/v2/firestore"); // Modulo Gen 2
const admin = require('firebase-admin');
const geo = require('./geo');
const territory = require('./territory');
const routing = require('./routing');

admin.initializeApp();

// Server-side ORS proxy — see routing.js for why this exists (moves the
// OpenRouteService API key out of the client entirely).
exports.orsRoute = routing.orsRoute;

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

// XP formula constants (Cd/Ca/Cr from the design spec): Cd is XP per km, Ca
// is m^2 of total claimed area per XP, Cr is m^2 of *stolen* area per XP — an
// additional bonus stacked on top of Ca's area XP, not a replacement for it.
const XP_PER_KM = 100; // Cd
const AREA_M2_PER_XP = 1000; // Ca
const STOLEN_AREA_M2_PER_XP = 333; // Cr

// 3. CLAIM DELLE AREE (loop chiusi -> claimedAreas), con unione/sottrazione,
//    e ASSEGNAZIONE PUNTI/TERRITORIO per l'intera sessione
//
// Per ogni loop chiuso della sessione:
//   - trova le claimedAreas vicine tramite una query geohash (evita di
//     scansionare l'intera collezione ad ogni corsa);
//   - le aree già proprie dell'utente che si sovrappongono/toccano vengono
//     unite (turf.union) nell'area appena conquistata — un loop
//     completamente contenuto in un'area già propria produce quindi la
//     stessa geometria di prima (nessun doppione visibile), un loop che la
//     estende parzialmente produce un unico poligono senza bordo interno;
//   - le aree di altri utenti che si sovrappongono vengono ridotte
//     (turf.difference) — la parte in comune diventa dell'ultimo che ci ha
//     corso sopra; se non rimane nulla, l'area viene marcata `deleted`.
// La geometria pesante (union/difference/query) vive in geo.js, pura e
// testabile senza Firestore — qui c'è solo l'I/O transazionale.
//
// Dopo aver processato tutti i loop (anche zero — una corsa senza loop
// chiusi guadagna comunque XP per la sola distanza), la sessione riceve
// `pointsEarned` (formula XP, vedi XP_PER_KM/AREA_M2_PER_XP/
// STOLEN_AREA_M2_PER_XP sopra) e il territorio ("City"/"Broad", vedi
// territory.js) risolto dal punto di partenza reale (path[0]), non dalla
// stringa `startLocality` fornita dal client.
//
// L'ownership (aree, punti, territorio) deve essere assegnata lato server
// (Admin SDK) e non dal client: firestore.rules nega `create`/`update` su
// claimedAreas per lo stesso motivo per cui nega i write su userStats, e
// forza pointsEarned/territoryCity/territoryBroad/territoryBroadType
// invariati sui write client di runningSessions.
//
// Nota: niente colorHex — il colore ("mie" vs "altrui") è relativo a chi
// guarda la mappa, calcolato lato client (ClaimedAreasLayer).
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

    // Processed sequentially (not Promise.all) so a second loop in the same
    // session sees the first loop's already-committed result, and so we
    // never have two overlapping transactions racing on the same documents.
    for (let index = 0; index < closedLoops.length; index++) {
      const points = closedLoops[index] && closedLoops[index].points;
      if (!Array.isArray(points) || points.length < 3) continue;
      try {
        const loopResult = await claimLoop({userId, sessionId, loopIndex: index, points, sessionData});
        sessionTotalAreaM2 += loopResult.totalAreaM2;
        sessionStolenAreaM2 += loopResult.stolenAreaM2;
      } catch (e) {
        // One malformed/degenerate loop shouldn't stop the rest of the
        // session's loops from being claimed/scored.
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
 * real start coordinates, and writes both onto the session doc plus the
 * user's running `profiles.totalPoints` total — in a single batch, since
 * FieldValue.increment() is safe outside a transaction. */
async function awardSessionPoints({userId, sessionId, sessionData, totalAreaM2, stolenAreaM2}) {
  const distanceKm = Number(sessionData.distanceMeters || 0) / 1000;
  // Named separately (not just inlined into the sum) so they can be
  // persisted below — the client-facing "why did I get this many XP"
  // breakdown reads these back rather than re-deriving them from
  // XP_PER_KM/AREA_M2_PER_XP/STOLEN_AREA_M2_PER_XP, which are
  // server-authoritative game-balance constants that shouldn't be
  // duplicated client-side.
  const xpFromDistance = distanceKm * XP_PER_KM;
  const xpFromArea = totalAreaM2 / AREA_M2_PER_XP;
  const xpFromStolenArea = stolenAreaM2 / STOLEN_AREA_M2_PER_XP;
  const xp = Math.round(xpFromDistance + xpFromArea + xpFromStolenArea);

  const path = sessionData.path;
  const start = Array.isArray(path) && path.length > 0 ? path[0] : null;
  const resolved = start ?
    await territory.resolveTerritory(start.latitude, start.longitude) :
    {city: null, broad: null, broadType: null};

  const db = admin.firestore();
  const batch = db.batch();
  batch.update(db.collection('runningSessions').doc(sessionId), {
    pointsEarned: xp,
    territoryCity: resolved.city,
    territoryBroad: resolved.broad,
    territoryBroadType: resolved.broadType,
    totalAreaM2,
    stolenAreaM2,
    xpFromDistance,
    xpFromArea,
    xpFromStolenArea,
    // Explicit completion sentinel — pointsEarned alone can legitimately be
    // 0 for a negligible session, so clients waiting on this write (the run
    // results popup) can't use "pointsEarned != 0" to mean "done".
    pointsProcessed: true,
  });
  batch.set(
    db.collection('profiles').doc(userId),
    {totalPoints: admin.firestore.FieldValue.increment(xp)},
    {merge: true}
  );
  await batch.commit();
}

async function claimLoop({userId, sessionId, loopIndex, points, sessionData}) {
  const db = admin.firestore();
  const areasRef = db.collection('claimedAreas');
  const areaId = `${sessionId}_${loopIndex}`;
  const bounds = geo.geohashBoundsForLoop(points);

  return db.runTransaction(async (tx) => {
    // ── Reads first — a Firestore transaction requires every read to
    // happen before any write. Sequential (not Promise.all) to keep the
    // transaction's read-tracking straightforward.
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

    console.log(
      `claimLoop ${result.areaId}: ${candidates.length} candidate(s) found ` +
      `(${candidates.filter((c) => c.userId === userId).length} same-owner, ` +
      `${candidates.filter((c) => c.userId !== userId).length} other-owner) -> ` +
      `${result.newArea.polygon.length} piece(s), absorbed ${result.deletes.length} own doc(s), ` +
      `touched ${result.otherOwnerUpdates.length} other-owner doc(s)`
    );

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
        // FieldValue.serverTimestamp() isn't allowed inside array elements —
        // a concrete timestamp is the best available substitute.
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

    return {totalAreaM2: result.totalAreaM2, stolenAreaM2: result.stolenAreaM2};
  });
}