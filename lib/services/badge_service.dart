import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/badge_model.dart'; // Make sure this path is correct

class BadgeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<List<BadgeModel>> getHomeBadges(String userId) async {
    // 1. Fetch all badges to get their base metadata
    final badgesSnapshot = await _firestore.collection('badges').get();
    
    final baseBadges = badgesSnapshot.docs
        .map((doc) => BadgeModel.fromMap(doc.id, doc.data()))
        .toList();

    // 2. Fetch the specific user's progress
    final progressSnapshot = await _firestore
        .collection('profiles')
        .doc(userId)
        .collection('badge_progress')
        .get();

    final progressMap = {
      for (var doc in progressSnapshot.docs) doc.id: doc.data()
    };

    // 3. Merge data securely creating a new immutable list
    final List<BadgeModel> userBadges = baseBadges.map((badge) {
      final pData = progressMap[badge.id];
      
      if (pData != null) {
        return badge.copyWith(
          progress: (pData['progress'] as num?)?.toDouble() ?? 0.0,
          unlocked: pData['unlocked'] ?? false,
        );
      }
      return badge; // Return the base badge if user has no progress doc yet
    }).toList();

    // 4. Apply the custom sorting logic
    userBadges.sort((a, b) {
      int getPriority(BadgeModel badge) {
        if (badge.unlocked) return 3; // Lowest priority (push to the end)
        if (badge.progress > 0) return 1; // Highest priority (in progress)
        return 2; // Medium priority (not started, 0%)
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

    // 5. Return only the top 5 badges for the Home Screen
    return userBadges.take(5).toList();
  }
}