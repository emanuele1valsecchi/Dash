import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_models.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/home/leaderboard_preview_card.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class LeaderboardSection extends StatefulWidget {
  final List<LeaderboardPreviewData> leaderboards;
  final void Function(String city) onLeaderboardTap;

  const LeaderboardSection({
    super.key,
    required this.leaderboards,
    required this.onLeaderboardTap,
  });

  @override
  State<LeaderboardSection> createState() => _LeaderboardSectionState();
}

class _LeaderboardSectionState extends State<LeaderboardSection> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.leaderboards.isEmpty){
      return Center(child: CircularProgressIndicator());
    }

    return DashSectionContainer(
      leadingIcon: Symbols.bar_chart_rounded,
      leadingIconFilled: true,
      title: "Leaderboards",
      hasForwardIcon: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ExcludeSemantics(
                child: Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Stack(
                    children: widget.leaderboards.map((data) {
                      return Padding(
                        padding: context.paddingSm,
                        child: LeaderboardPreviewCard(
                          data: data,
                          onTap: () {},
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),

              Positioned.fill(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() => _currentIndex = index);
                  },
                  itemCount: widget.leaderboards.length,
                  itemBuilder: (context, index) {
                    final data = widget.leaderboards[index];
                    return Padding(
                      padding: context.paddingSm, 
                      child: LeaderboardPreviewCard(
                        data: data,
                        onTap: () => widget.onLeaderboardTap(data.city),
                      ),
                    );
                  }
                ),
              ),
            ],
          ),

          _buildBottomAnimatedCarosel(),
        ],
      )
    );
  }

  Widget _buildBottomAnimatedCarosel(){

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: List.generate(
        widget.leaderboards.length,
        (index) {
          final dist = (index - _currentIndex).abs();

          double width = 0.0;
          double height = 0.0;
          double margin = 0.0;

          if (dist == 0) {
            width = ResponsiveSpacing().md; 
            height = ResponsiveSpacing().sm; 
            margin = ResponsiveSpacing().sm;

          } else if (dist <= 2) { 
            width = ResponsiveSpacing().sm; 
            height = ResponsiveSpacing().sm; 
            margin = ResponsiveSpacing().xs;

          } else if (dist == 3) {
            width = ResponsiveSpacing().xs; 
            height = ResponsiveSpacing().xs; 
            margin = ResponsiveSpacing().xs / 2;
          }

          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            margin: EdgeInsets.symmetric(horizontal: margin),
            height: height,
            width: width,
            decoration: BoxDecoration(
              color: _currentIndex == index
                  ? Theme.of(context).primaryColor 
                  : Theme.of(context).colorScheme.outlineVariant, 
              borderRadius: context.radiusXl,
            ),
          );
        },
      ),
    );
  }
}