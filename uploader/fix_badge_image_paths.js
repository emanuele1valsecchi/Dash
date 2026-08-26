const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const serviceAccount = require('./serviceAccountKey.json');

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();

// Live Firestore imagePath was stale/wrong for these 10 badges (pointed at an
// old filename, or — for starter/need_a_break/great_stamina/
// youre_looking_good/consistent — at the shared "AspiringBoss.png" placeholder).
// The correctly-named files themselves are already uploaded to Storage
// (see uploader/badge_images/); this just repoints each doc's imagePath at its
// own file.
const fixes = {
  is_it_a_triangle_or_a_square: 'badges/IsItATriangleOrASquare.png',
  starter: 'badges/Starter.png',
  need_a_break: 'badges/NeedABreak.png',
  great_stamina: 'badges/GreatStamina.png',
  half_a_marathon: 'badges/HalfAMarathon.png',
  youre_looking_good: 'badges/YoureLookingGood.png',
  consistent: 'badges/Consistent.png',
  its_all_mine: 'badges/ItsAllMine.png',
  im_following_you: 'badges/ImFollowingYou.png',
  the_foreigner: 'badges/TheForeigner.png',
};

async function fixImagePaths() {
  for (const [id, imagePath] of Object.entries(fixes)) {
    await db.collection('badges').doc(id).update({ imagePath });
    console.log(`${id} -> ${imagePath}`);
  }
  console.log(`Done. ${Object.keys(fixes).length} badge docs updated.`);
}

fixImagePaths().catch(console.error);
