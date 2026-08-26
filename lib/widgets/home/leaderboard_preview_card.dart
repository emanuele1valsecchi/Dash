import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/widgets/dash_gesture_card_container.dart';
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
    final currentUserPin = data.pins.where((p) => p.isCurrentUser).firstOrNull;
    final progressPercent = currentUserPin?.normalizedPosition ?? 0.0;

    return DashGestureCardContainer(
      onTap: onTap,
      child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(
                  Icons.location_on_rounded, 
                  size: 14, 
                  color: Theme.of(context).colorScheme.outline,
                ),
                SizedBox(width: 4),
                Text(
                  data.city.isNotEmpty ? data.city : 'Unknown territory',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth;
                  final trackWidth = maxWidth - 42;

                  return Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        height: 8,
                        width: maxWidth,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.tertiaryContainer,
                          borderRadius: context.radiusXl,
                        ),
                      ),
                      Container(
                        height: 8,
                        width: (trackWidth * progressPercent) + 21,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.tertiary,
                          borderRadius: context.radiusXl,
                        ),
                      ),
                      ...data.pins.map((pin) {
                        return Positioned(
                          top: pin.isCurrentUser ? 50 : 0,
                          left: trackWidth * pin.normalizedPosition,
                          child: _MapPin(
                            key: ValueKey(pin.userId),
                            imageUrl: pin.profileImageUrl,
                            isCurrentUser: pin.isCurrentUser,
                            isTop: !pin.isCurrentUser,
                          ),
                        );
                      }),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildStatColumn('Position', '#${data.position}'),
                _buildStatColumn('Points', '${data.points} pt'),
                _buildStatColumn('Variation', data.variation?.toString() ?? '—'),
              ],
            ),
          ],
        ),
      );
  }

  Widget _buildStatColumn(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8A9389),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            color: Color(0xFF4A554A),
          ),
        ),
      ],
    );
  }
}

// ── Widget Custom per disegnare il Map Pin ──
// Convertito in StatefulWidget per gestire il fallback quando l'immagine
// fallisce (es. 403 da Firebase Storage con URL/token scaduto o inesistente).
class _MapPin extends StatefulWidget {
  final String imageUrl;
  final bool isCurrentUser;
  final bool isTop;

  const _MapPin({
    super.key,
    required this.imageUrl,
    required this.isCurrentUser,
    required this.isTop,
  });

  @override
  State<_MapPin> createState() => _MapPinState();
}

class _MapPinState extends State<_MapPin> {
  bool _imageFailed = false;

  @override
  void didUpdateWidget(covariant _MapPin oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Se l'URL cambia (es. dopo un refresh), riprova a mostrare l'immagine.
    if (oldWidget.imageUrl != widget.imageUrl) {
      _imageFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinColor = widget.isCurrentUser ? const Color(0xFF3B5E62) : const Color(0xFFD3D6CE);
    final size = widget.isCurrentUser ? 46.0 : 38.0;
    final hasValidImage = widget.imageUrl.isNotEmpty && !_imageFailed;

    return SizedBox(
      width: size,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: widget.isTop ? 0 : null,
            top: !widget.isTop ? 0 : null,
            child: Transform.rotate(
              angle: widget.isTop ? 0.785398 : 3.92699,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: pinColor,
                  borderRadius: const BorderRadius.only(
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: widget.isTop ? 0 : null,
            bottom: !widget.isTop ? 0 : null,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: pinColor,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(3.0),
                child: CircleAvatar(
                  backgroundColor: Colors.grey.shade300,
                  backgroundImage: hasValidImage ? NetworkImage(widget.imageUrl) : null,
                  onBackgroundImageError: hasValidImage
                      ? (exception, stackTrace) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() => _imageFailed = true);
                          });
                        }
                      : null,
                  child: !hasValidImage
                      ? Icon(Icons.person, size: widget.isCurrentUser ? 20 : 16, color: Colors.grey.shade600)
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
