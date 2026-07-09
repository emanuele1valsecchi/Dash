class HomeBadgeUiModel {
  final String badgeId;
  final String title;
  final String description;
  final String imageUrl;
  final double progress;
  final bool unlocked;

  HomeBadgeUiModel({
    required this.badgeId,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.progress,
    required this.unlocked,
  });
}