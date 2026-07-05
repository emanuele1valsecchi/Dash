class BadgeModel {
  final String id;
  final String title;
  final String description;
  final String imagePath;
  final bool defaultVisible;
  final int order;
  final double requiredValue;

  const BadgeModel({
    required this.id,
    required this.title,
    required this.description,
    required this.imagePath,
    required this.defaultVisible,
    required this.order,
    required this.requiredValue,
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
    );
  }
}