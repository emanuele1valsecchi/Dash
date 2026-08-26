const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { initializeApp, cert } = require('firebase-admin/app');
const { getStorage } = require('firebase-admin/storage');
const serviceAccount = require('./serviceAccountKey.json');

// From android/app/google-services.json ("storage_bucket").
const STORAGE_BUCKET = 'dash-efb1d.firebasestorage.app';

initializeApp({
  credential: cert(serviceAccount),
  storageBucket: STORAGE_BUCKET,
});

const bucket = getStorage().bucket();
const imagesDir = path.join(__dirname, 'badge_images');

async function uploadBadges() {
  const files = fs.readdirSync(imagesDir).filter((f) => f.endsWith('.png'));

  for (const file of files) {
    const localPath = path.join(imagesDir, file);
    const destination = `badges/${file}`;

    // The Admin SDK doesn't auto-generate a download token the way the
    // Console/client SDK does, so getDownloadURL() (used by
    // lib/services/storage_service.dart) would 404 without one explicitly
    // set here.
    const downloadToken = crypto.randomUUID();

    await bucket.upload(localPath, {
      destination,
      metadata: {
        contentType: 'image/png',
        metadata: {
          firebaseStorageDownloadTokens: downloadToken,
        },
      },
    });

    console.log(`Uploaded ${destination}`);
  }

  console.log(`Done. ${files.length} badge images uploaded.`);
}

uploadBadges().catch(console.error);
