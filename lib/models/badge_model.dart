class BadgeModel {
  final String id;
  final String title;
  final String description;
  final String imagePath;
  final bool defaultVisible;
  final int order;
  final double requiredValue;
  // User specific state
  final double progress;
  final bool unlocked;

  const BadgeModel({
    required this.id,
    required this.title,
    required this.description,
    required this.imagePath,
    required this.defaultVisible,
    required this.order,
    required this.requiredValue,
    this.progress = 0.0,
    this.unlocked = false,
  });

  factory BadgeModel.fromMap(String id, Map<String, dynamic> map) {
    return BadgeModel(
      id: id,
      title: map['title'] ?? '',
      description: map['description'] ?? '',
      imagePath: map['imagePath'] ?? '',
      defaultVisible: map['defaultVisible'] ?? false,
      order: (map['order'] ?? 0) as int,
      requiredValue: (map['requiredValue'] as num?)?.toDouble() ?? 0.0,
      // We don't map progress and unlocked here because they don't live 
      // in the global 'badges' collection. They start at default values.
    );
  }

  // Helper method to create a copy of the model with updated user state
  BadgeModel copyWith({
    double? progress,
    bool? unlocked,
  }) {
    return BadgeModel(
      id: id,
      title: title,
      description: description,
      imagePath: imagePath,
      defaultVisible: defaultVisible,
      order: order,
      requiredValue: requiredValue,
      progress: progress ?? this.progress,
      unlocked: unlocked ?? this.unlocked,
    );
  }
}