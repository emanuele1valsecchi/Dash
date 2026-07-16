import 'package:flutter/material.dart';

/// Floating two-button panel for toggling claimed-area visibility by
/// ownership — the same grid ("other users' territory") / cable ("my own
/// territory") pair from the Explore page's settings panel, factored out so
/// every other screen that shows claimed areas can offer the same toggle
/// without duplicating the button styling.
class AreaVisibilityToggle extends StatelessWidget {
  final bool showOtherAreas;
  final bool showMyAreas;
  final ValueChanged<bool> onShowOtherAreasChanged;
  final ValueChanged<bool> onShowMyAreasChanged;

  const AreaVisibilityToggle({
    super.key,
    required this.showOtherAreas,
    required this.showMyAreas,
    required this.onShowOtherAreasChanged,
    required this.onShowMyAreasChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleButton(
            icon: Icons.grid_on_outlined,
            tooltip: 'Show other users\' areas',
            active: showOtherAreas,
            atTop: true,
            onTap: () => onShowOtherAreasChanged(!showOtherAreas),
          ),
          Container(
            height: 1,
            color: const Color(0xFFE8E8E8),
            margin: const EdgeInsets.symmetric(horizontal: 8),
          ),
          _ToggleButton(
            icon: Icons.cable_outlined,
            tooltip: 'Show my areas',
            active: showMyAreas,
            atTop: false,
            onTap: () => onShowMyAreasChanged(!showMyAreas),
          ),
        ],
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final bool atTop;
  final VoidCallback onTap;

  const _ToggleButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.atTop,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(12);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: atTop
            ? const BorderRadius.vertical(top: r)
            : const BorderRadius.vertical(bottom: r),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(
            icon,
            size: 22,
            color: active ? const Color(0xFF4A8C52) : const Color(0xFF425143),
          ),
        ),
      ),
    );
  }
}
