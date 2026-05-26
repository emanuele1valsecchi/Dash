import 'package:flutter/material.dart';
import '../../models/home_models.dart';

class LeaderboardPreviewCard extends StatelessWidget {
  final LeaderboardPreviewData data;
  final VoidCallback onTap;

  const LeaderboardPreviewCard({
    super.key,
    required this.data,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatars = data.avatarAssets;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4EE),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFD8DBD2)),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 82,
              child: Stack(
                children: [
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 24,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF315865),
                            Color(0xFF315865),
                            Color(0xFFC7E3F2),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (int i = 0; i < avatars.length; i++)
                    Positioned(
                      left: i * 55,
                      top: i == 2 ? 34 : 0,
                      child: _AvatarPin(asset: avatars[i], highlighted: i == 2),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _MetricBlock(
                  label: 'Position',
                  value: data.position != null ? '#${data.position}' : '—',
                ),
                _MetricBlock(
                  label: 'Points',
                  value: data.points != null ? '${data.points} pt' : '—',
                ),
                _MetricBlock(
                  label: 'Variation',
                  value: data.variation != null
                      ? '${data.variation! > 0 ? '+' : ''}${data.variation}'
                      : '—',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarPin extends StatelessWidget {
  final String asset;
  final bool highlighted;

  const _AvatarPin({
    required this.asset,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: highlighted ? 42 : 34,
          height: highlighted ? 42 : 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: highlighted ? const Color(0xFF315865) : Colors.transparent,
              width: 3,
            ),
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: ClipOval(
            child: Image.asset(asset, fit: BoxFit.cover),
          ),
        ),
      ],
    );
  }
}

class _MetricBlock extends StatelessWidget {
  final String label;
  final String value;

  const _MetricBlock({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7266),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              color: Color(0xFF1E241D),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}