import 'dart:math' as math;
import 'dart:ui';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_floating_action_button.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class StartRunOverlay extends StatelessWidget {
  final Animation<double> animation;
  final Rect fabRect;
  final VoidCallback onSearchRoute;
  final VoidCallback onCreateRoute;
  final VoidCallback onStartRun;

  const StartRunOverlay({
    super.key,
    required this.animation,
    required this.fabRect,
    required this.onSearchRoute,
    required this.onCreateRoute,
    required this.onStartRun,
  });

  @override
  Widget build(BuildContext context) {
    double spacingBetweenActionButton = ResponsiveSpacing().md;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        
        final curvedAnim = CurvedAnimation(
          parent: animation, 
          curve: Curves.easeOutCubic
        );

        final blurValue = curvedAnim.value > 0 ? (8.0 * curvedAnim.value) : 0.001; 
        final overlayAlpha = (140 * curvedAnim.value).toInt();

        final slideAnimation = Tween<Offset>(
          begin: const Offset(0.0, 0.4), 
          end: Offset.zero,
        ).animate(curvedAnim);

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: blurValue, sigmaY: blurValue),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      color: Theme.of(context).colorScheme.onSurface.withAlpha(overlayAlpha),
                    ),
                  ),
                ),
              ),

              Positioned(
                bottom: MediaQuery.heightOf(context) - fabRect.top + spacingBetweenActionButton,
                right: MediaQuery.widthOf(context) - fabRect.right,
                child: SlideTransition(
                  position: slideAnimation,
                  child: FadeTransition(
                    opacity: curvedAnim,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: spacingBetweenActionButton,
                      children: [
                        _OverlayAction(
                          label: 'Search for a route',
                          icon: Symbols.search_rounded,
                          onPressed: () {
                            Navigator.of(context).pop();
                            onSearchRoute();
                          },
                        ),

                        _OverlayAction(
                          label: 'Create a route',
                          icon: Symbols.route_rounded,
                          onPressed: () {
                            Navigator.of(context).pop();
                            onCreateRoute();
                          },
                        ),
                        
                        _OverlayAction(
                          label: 'Start to run now',
                          icon: Symbols.play_arrow_rounded,
                          onPressed: () {
                            Navigator.of(context).pop();
                            onStartRun();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              Positioned(
                left: fabRect.left,
                top: fabRect.top,
                width: fabRect.width,
                height: fabRect.height,
                child: DashFloatingActionButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: _buildAnimatedIcon(curvedAnim),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAnimatedIcon(Animation<double> anim) {
    return Transform.rotate(
      angle: anim.value * math.pi,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: (1.0 - anim.value).clamp(0.0, 1.0),
            child: const Icon(Symbols.directions_run_rounded),
          ),
          Opacity(
            opacity: anim.value.clamp(0.0, 1.0),
            child: const Icon(Symbols.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _OverlayAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _OverlayAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    TextStyle textStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Theme.of(context).colorScheme.onInverseSurface,
      fontWeight: FontWeight.bold
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.start,
      spacing: ResponsiveSpacing().md,
      children: [
        Text(
          label,
          style: textStyle,
        ),

        DashActionButton(
          onPressed: onPressed,
          icon: icon,
          iconFill: 1.0,
          labelSize: textStyle.fontSize! * 2,
        ),
      ],
    );
  }
}