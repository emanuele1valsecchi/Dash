import 'package:flutter/material.dart';

class LeaderboardPreviewData {
  final int? position;
  final int? points;
  final int? variation;
  final List<String> avatarAssets;

  const LeaderboardPreviewData({
    required this.position,
    required this.points,
    required this.variation,
    required this.avatarAssets,
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

class WeeklyStatData {
  final String title;
  final String value;
  final IconData icon;
  final double progress;

  const WeeklyStatData({
    required this.title,
    required this.value,
    required this.icon,
    required this.progress,
  });
}