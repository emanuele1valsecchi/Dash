const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const serviceAccount = require('./serviceAccountKey.json');

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();

async function listBadges() {
  const snapshot = await db.collection('badges').orderBy('order').get();
  const rows = snapshot.docs.map((doc) => {
    const d = doc.data();
    return {
      id: doc.id,
      order: d.order,
      title: d.title,
      imagePath: d.imagePath,
    };
  });
  console.log(JSON.stringify(rows, null, 2));
}

listBadges().catch(console.error);
