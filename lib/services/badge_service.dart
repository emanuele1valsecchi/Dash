import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/badge_model.dart'; // Make sure this path is correct

class BadgeService {
  /// Collaborators default to the real Firebase singletons, so an
  /// existing `BadgeService()` call behaves exactly as before. Tests pass
  /// fakes instead, which is the only way to exercise this class at
  /// all: `FirebaseFirestore.instance` throws with no initialised app.
  BadgeService({
    FirebaseFirestore? firestore,
  })  :         _firestoreOverride = firestore;

  final FirebaseFirestore? _firestoreOverride;

  // Resolved on first use, never at construction: a screen that
  // builds this service in a field initializer must not throw
  // `[core/no-app]` before its widget tree even exists.
  late final FirebaseFirestore _firestore = _firestoreOverride ?? FirebaseFirestore.instance;

  Future<List<BadgeModel>> getAllBadges(String userId) async {
    final badgesSnapshot = await _firestore.collection('badges').get();
    
    final baseBadges = badgesSnapshot.docs
        .map((doc) => BadgeModel.fromMap(doc.id, doc.data()))
        .toList();

    final progressSnapshot = await _firestore
        .collection('profiles')
        .doc(userId)
        .collection('badge_progress')
        .get();

    final progressMap = {
      for (var doc in progressSnapshot.docs) doc.id: doc.data()
    };

    final List<BadgeModel> userBadges = baseBadges.map((badge) {
      final pData = progressMap[badge.id];
      
      if (pData != null) {
        return badge.copyWith(
          // **Kept in the stored scale: a percentage, 0-100.** The Cloud
          // Function writes it that way (`functions/index.js` caps at 100 and
          // writes `progress: 100` on unlock).
          //
          // Deliberately *not* converted to the 0..1 fraction `DashBadge`
          // wants, because nothing renders this value: every screen that draws
          // badges (`ProfilePage`, `PublicProfilePage`, `BadgePage`) builds its
          // own `HomeBadgeUiModel` from a live `badge_progress` snapshot and
          // does its own `/100` there. Here it is used only for *ordering*
          // (see the sort below), which is scale-invariant.
          //
          // Converting it looks like a tidy-up and is not: it would leave two
          // different meanings for the same field depending on the path taken.
          progress: (pData['progress'] as num?)?.toDouble() ?? 0.0,
          unlocked: pData['unlocked'] ?? false,
        );
      }
      return badge;
    }).toList();

    userBadges.sort((a, b) {
      int getPriority(BadgeModel badge) {
        if (badge.unlocked) return 3; 
        if (badge.progress > 0) return 1;
        return 2;
      }

      int priorityA = getPriority(a);
      int priorityB = getPriority(b);

      if (priorityA != priorityB) {
        return priorityA.compareTo(priorityB);
      }

      if (priorityA == 1) {
        return b.progress.compareTo(a.progress);
      }

      return a.order.compareTo(b.order); 
    });

    return userBadges;
  }

  Future<List<BadgeModel>> getHomeBadges(String userId) async {
    final allBadges = await getAllBadges(userId);
    return allBadges.take(5).toList();
  }

  Future<List<BadgeModel>> getProfileBadges(String userId) async {
    final allBadges = await getAllBadges(userId);
    return allBadges.take(3).toList();
  }
}