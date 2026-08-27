import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/badge_model.dart'; // Make sure this path is correct

class BadgeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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