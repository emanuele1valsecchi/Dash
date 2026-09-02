import 'package:cloud_firestore/cloud_firestore.dart';

class FollowService {
  /// Collaborators default to the real Firebase singletons, so an
  /// existing `FollowService()` call behaves exactly as before. Tests pass
  /// fakes instead, which is the only way to exercise this class at
  /// all: `FirebaseFirestore.instance` throws with no initialised app.
  FollowService({
    FirebaseFirestore? db,
  })  :         _dbOverride = db;

  final FirebaseFirestore? _dbOverride;

  // Resolved on first use, never at construction: a screen that
  // builds this service in a field initializer must not throw
  // `[core/no-app]` before its widget tree even exists.
  late final FirebaseFirestore _db = _dbOverride ?? FirebaseFirestore.instance;

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