import 'package:cloud_firestore/cloud_firestore.dart';

class FollowService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> toggleFollow({
    required String currentUserId, 
    required String targetUserId, 
    required bool isCurrentlyFollowing
  }) async {
    // Generiamo un ID univoco per la relazione
    final String docId = '${currentUserId}_$targetUserId';
    final followRef = _db.collection('follows').doc(docId);
    
    final currentUserRef = _db.collection('profiles').doc(currentUserId);
    final targetUserRef = _db.collection('profiles').doc(targetUserId);

    final batch = _db.batch();

    if (isCurrentlyFollowing) {
      // ── UNFOLLOW ──
      batch.delete(followRef);
      
      // Riduciamo i contatori
      batch.update(currentUserRef, {'followingCount': FieldValue.increment(-1)});
      batch.update(targetUserRef, {'followersCount': FieldValue.increment(-1)});
    } else {
      // ── FOLLOW ──
      batch.set(followRef, {
        'followerId': currentUserId,
        'followingId': targetUserId,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Aumentiamo i contatori
      batch.update(currentUserRef, {'followingCount': FieldValue.increment(1)});
      batch.update(targetUserRef, {'followersCount': FieldValue.increment(1)});
      
      // NOTA: Qui è il punto perfetto per inserire anche la logica che scrive
      // un documento nella collezione "notifications" del targetUser
    }

    // Eseguiamo tutte le scritture simultaneamente
    await batch.commit();
  }
}