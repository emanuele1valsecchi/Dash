import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/badge_model.dart';

class BadgeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<List<BadgeModel>> getDefaultBadges() async {
    final snapshot = await _firestore
        .collection('badges')
        .where('defaultVisible', isEqualTo: true)
        .orderBy('order')
        .limit(5)
        .get();

    return snapshot.docs
        .map((doc) => BadgeModel.fromMap(doc.id, doc.data()))
        .toList();
  }
}