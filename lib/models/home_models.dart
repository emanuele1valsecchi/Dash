import 'package:flutter/material.dart';

class PreviewPin {
  final String userId;
  final String profileImageUrl;
  final double normalizedPosition; // Valore da 0.0 a 1.0 per posizionarlo sulla barra
  final bool isCurrentUser;

  PreviewPin({
    required this.userId,
    required this.profileImageUrl,
    required this.normalizedPosition,
    required this.isCurrentUser,
  });
}

class LeaderboardPreviewData {
  final int position;
  final int points;
  final String? variation;
  final String city; // Nuova aggiunta
  final List<PreviewPin> pins; // Nuova aggiunta

  const LeaderboardPreviewData({
    required this.position,
    required this.points,
    this.variation,
    required this.city,
    required this.pins,
  });
}

class BadgeProgressData {
  final String title;
  final String imageAsset;
  final double progress;

  const BadgeProgressData({
    required this.title,
    required this.imageAsset,
    required this.progress,
  });
}

class MonthlyStatData {
  final String title;
  final String value;
  final IconData icon;
  final double progress;
  final String bottomText;

  const MonthlyStatData({
    required this.title,
    required this.value,
    required this.icon,
    required this.progress,
    required this.bottomText,
  });
}