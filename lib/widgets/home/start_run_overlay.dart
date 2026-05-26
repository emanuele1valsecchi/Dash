import 'dart:ui';
import 'package:flutter/material.dart';

class StartRunOverlay extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onClose;
  final VoidCallback onSearchRoute;
  final VoidCallback onCreateRoute;
  final VoidCallback onStartRun;

  const StartRunOverlay({
    super.key,
    required this.isOpen,
    required this.onClose,
    required this.onSearchRoute,
    required this.onCreateRoute,
    required this.onStartRun,
  });

  @override
  Widget build(BuildContext context) {
    if (!isOpen) return const SizedBox.shrink();

    return Positioned.fill(
      child: Stack(
        children: [
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Container(
              color: Colors.black.withValues(alpha: 0.35),
            ),
          ),
          Positioned(
            right: 22,
            bottom: 92,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _OverlayAction(
                  label: 'Search for a route',
                  icon: Icons.search,
                  onTap: onSearchRoute,
                ),
                const SizedBox(height: 16),
                _OverlayAction(
                  label: 'Create a route',
                  icon: Icons.route_rounded,
                  onTap: onCreateRoute,
                ),
                const SizedBox(height: 16),
                _OverlayAction(
                  label: 'Start to run now',
                  icon: Icons.play_arrow_rounded,
                  onTap: onStartRun,
                ),
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    width: 66,
                    height: 66,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFCAF0B8),
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 34,
                      color: Color(0xFF425143),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OverlayAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _OverlayAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 14),
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 54,
            height: 54,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFCAF0B8),
            ),
            child: Icon(icon, color: const Color(0xFF425143), size: 28),
          ),
        ),
      ],
    );
  }
}