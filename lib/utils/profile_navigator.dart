import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:dash/screens/profile_page.dart';
import 'package:dash/screens/public_profile_page.dart';

class ProfileNavigation {
  static void openProfile(BuildContext context, String targetUserId, {bool replace = false}) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final isSelf = currentUserId != null && currentUserId == targetUserId;

    final route = MaterialPageRoute<void>(
      builder: (context) => isSelf ? const ProfilePage() : PublicProfilePage(userId: targetUserId),
    );

    if (replace) {
      Navigator.pushReplacement(context, route);
    } else {
      Navigator.push(context, route);
    }
  }
}