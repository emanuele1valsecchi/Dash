const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const serviceAccount = require('./serviceAccountKey.json');
const badges = require('./badges.json');

initializeApp({
  credential: cert(serviceAccount),
});

const db = getFirestore();

async function seedBadges() {
  for (const badge of badges) {
    const { id, ...data } = badge;
    await db.collection('badges').doc(id).set(data, { merge: true });
    console.log(`Badge ${id} caricato`);
  }
  console.log('Fatto');
}

seedBadges().catch(console.error);