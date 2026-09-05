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
  final String city; 
  final List<PreviewPin> pins; 

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

class MonthlyStatsRaw {
  final double avgDurationMs;
  final int bestDurationMs;
  final double avgMaxSpeedKmh;
  final double bestSpeedKmh;
  final double avgSpeedKmh;
  final double bestAvgSpeedKmh;
  final double avgDistanceMeters;
  final double bestDistanceMeters;
  final int completedActivities;
  final int previousCompletedActivities;
  final double activitiesProgress;
  final double avgCalories;
  final double bestCalories;
  final String avgDurationStr;
  
  const MonthlyStatsRaw({
    required this.avgDurationMs,
    required this.bestDurationMs,
    required this.avgMaxSpeedKmh,
    required this.bestSpeedKmh,
    required this.avgSpeedKmh,
    required this.bestAvgSpeedKmh,
    required this.avgDistanceMeters,
    required this.bestDistanceMeters,
    required this.completedActivities,
    required this.previousCompletedActivities,
    required this.activitiesProgress,
    required this.avgCalories,
    required this.bestCalories,
    required this.avgDurationStr,
  });
}