import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/detailed_statistics_page.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ProfileStatisticsSection extends StatefulWidget {
  final String userId;

  const ProfileStatisticsSection({
    super.key,
    required this.userId,
  });

  @override
  State<ProfileStatisticsSection> createState() => _ProfileStatisticsSectionState();
}

class _ProfileStatisticsSectionState extends State<ProfileStatisticsSection> {
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _metrics = ['Time', 'Speed', 'Distance', 'Activities', 'Calories'];


  String _selectedMetric = _metrics[0];
  bool _isLoading = true;
  
  List<double> _timeData = List.filled(7, 0.0);
  List<double> _speedData = List.filled(7, 0.0);
  List<double> _distanceData = List.filled(7, 0.0);
  List<double> _activitiesData = List.filled(7, 0.0);
  List<double> _caloriesData = List.filled(7, 0.0);

  StreamSubscription<QuerySnapshot>? _sessionsSub;

  @override
  void initState() {
    super.initState();
    _startSessionsStream();
  }

  @override
  void dispose() {
    _sessionsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contextTheme = Theme.of(context);

    final TextStyle labelStyle = contextTheme.textTheme.labelSmall!;
    
    List<double> currentValues;
    if (_selectedMetric == _metrics[0]) {
      currentValues = _timeData;
    } else if (_selectedMetric == _metrics[1]) {
      currentValues = _speedData;
    } else if (_selectedMetric == _metrics[2]) {
      currentValues = _distanceData;
    } else if (_selectedMetric == _metrics[3]) {
      currentValues = _activitiesData;
    } else {
      currentValues = _caloriesData;
    }

    final double maxValue = currentValues.isNotEmpty ? currentValues.reduce((a, b) => a > b ? a : b) : 1.0;

    final bool hasData = maxValue > 0;
    final double safeMax = hasData ? maxValue : 1.0;

    final String topLabel = hasData ? _formatValueLabel(safeMax) : '';
    final double labelWidth= hasData ? _calculateMaxLabelWidth(topLabel, labelStyle) : 0;
    
    final double chartHeight = MediaQuery.heightOf(context) * 0.22;
    final double chartWidth = MediaQuery.widthOf(context);
    final double barWidth = chartWidth * 0.045;

    return DashSectionContainer(
      title: "Statistics",
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DetailedStatisticsPage(userId: widget.userId),
          ),
        );
      },
      child: _isLoading
          ? SizedBox(
              height: chartHeight,
              child: const Center(child: CircularProgressIndicator()),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: chartHeight,
                  child: Stack(
                    children: [

                      _buildBackLines(labelStyle, labelWidth, hasData, safeMax),

                      _buildAnimatedBars(currentValues, chartHeight, labelWidth, barWidth, safeMax),
                    ],
                  ),
                ),

                _buildDaysRow(labelStyle, barWidth, labelWidth),

                DashSectionContainer.noTitleFadeEdge(
                  child: Row(
                    spacing: ResponsiveSpacing().md,
                    children: [
                      _buildMetricButton(_metrics[0], Symbols.timer_rounded),
                      _buildMetricButton(_metrics[1], Symbols.sprint_rounded),
                      _buildMetricButton(_metrics[2], Symbols.arrow_range_rounded),
                      _buildMetricButton(_metrics[3], Symbols.steps_rounded),
                      _buildMetricButton(_metrics[4], Symbols.mode_heat_rounded),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String _formatValueLabel(double val) {
    if (val == 0) return '';
    
    if (_selectedMetric == _metrics[0]) {
      int totalMinutes = val.round();
      int h = totalMinutes ~/ 60;
      int m = totalMinutes % 60;
      
      if (h > 0 && m > 0) return '${h}h ${m}m';
      if (h > 0) return '${h}h';
      return '${m}m';
    } else if (_selectedMetric == _metrics[1]) {
      return '${val.toStringAsFixed(1)} km/h';
    } else if (_selectedMetric == _metrics[2]) {
      return '${val.toStringAsFixed(1)} km';
    } else if (_selectedMetric == _metrics[3]) {
      return '${val.toInt()}';
    } else if (_selectedMetric == _metrics[4]) {
      return '${val.toInt()} kCal';
    }
    
    return '';
  }

  double _calculateMaxLabelWidth(String topLabel, TextStyle style) {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: topLabel, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    
    return textPainter.size.width + ResponsiveSpacing().xs;
  }

  Widget _buildBackLines(TextStyle labelStyle, double labelWidth, bool hasData, double safeMax){
    return Positioned(
      top: 0.0,
      bottom: 0.0,
      left: 0.0,
      right: 0.0,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildReferenceLine(labelStyle, labelWidth, 1, hasData ? _formatValueLabel(safeMax) : ''),
          _buildReferenceLine(labelStyle, labelWidth, 1, hasData ? _formatValueLabel(safeMax * 2 / 3) : ''),
          _buildReferenceLine(labelStyle, labelWidth, 1, hasData ? _formatValueLabel(safeMax / 3) : ''),
          _buildReferenceLine(labelStyle, labelWidth, 3, ''),
        ],
      )
    );
  }

  Widget _buildReferenceLine(TextStyle labelStyle, double labelWidth, double labelHeight, String label) {
    return Row(
      spacing: ResponsiveSpacing().sm,
      children: [
        Expanded(
          child: Container(
            height: labelHeight,
            color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
          ),
        ),

        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          width: labelWidth,
          alignment: Alignment.centerRight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: Text(
              label,
              key: ValueKey<String>(label),
              maxLines: 1,
              textAlign: TextAlign.right,
              style: labelStyle.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAnimatedBars(List<double> currentValues, double chartHeight, double labelWidth, double barWidth, double safeMax){
    return Positioned(
      top: ResponsiveSpacing().sm,
      bottom: ResponsiveSpacing().sm,
      left: 0.0,
      right: 0.0,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        padding: EdgeInsetsGeometry.fromLTRB(0.0, 0.0, labelWidth, 0.0),
        child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_days.length, (index) {
          final val = currentValues[index];
          final heightFactor = (val / safeMax).clamp(0.0, 1.0);

          return AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            width: barWidth,
            height: chartHeight * heightFactor,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.vertical(top: Radius.circular(ResponsiveBorderRadius().xs)),
            ),
          );
        }),
      )
      ),
    );
  }

  Widget _buildDaysRow(TextStyle labelStyle, double barWidth, double labelWidth){
    final currentDayIndex = DateTime.now().weekday - 1;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      padding: EdgeInsetsGeometry.fromLTRB(0.0, 0.0, labelWidth, 0.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(_days.length, (index) {
          final isToday = index == currentDayIndex;

          return SizedBox(
            width: barWidth,
            child: Text(
              _days[index],
              maxLines: 1,
              textAlign: TextAlign.center,
              style: labelStyle.copyWith(
                color: isToday ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.outline,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        }),
      )
    );
  }

  Widget _buildMetricButton(String label, IconData icon) {
    final bool isSelected = _selectedMetric == label;

    if(isSelected){
      return DashActionButton.selected(
        onPressed: () {
          setState(() {
            _selectedMetric = label;
          });
        },
        label: label,
        icon: icon,
        iconFill: 1.0,
      );
    } else {
      return DashActionButton(
        onPressed: () {
          setState(() {
            _selectedMetric = label;
          });
        },
        label: label,
        icon: icon,
        iconFill: 0.0,
      );
    }   
  }

  void _startSessionsStream() {
    final now = DateTime.now();
    final currentWeekday = now.weekday; // 1 = Monday, 7 = Sunday
    // Isolate the start of the current week (Monday at 00:00:00)
    final startOfWeek = DateTime(now.year, now.month, now.day).subtract(Duration(days: currentWeekday - 1));

    _sessionsSub = FirebaseFirestore.instance
        .collection('runningSessions')
        .where('userId', isEqualTo: widget.userId)
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfWeek))
        .snapshots()
        .listen(
      (snapshot) {
        List<double> tempTime = List.filled(7, 0.0);
        List<double> tempSpeed = List.filled(7, 0.0);
        List<double> tempDistance = List.filled(7, 0.0);
        List<double> tempActivities = List.filled(7, 0.0);
        List<double> tempCalories = List.filled(7, 0.0);

        for (var doc in snapshot.docs) {
          final data = doc.data();
          final Timestamp? timestamp = data['createdAt'] as Timestamp?;
          if (timestamp == null) continue;

          final DateTime date = timestamp.toDate();
          int dayIndex = date.weekday - 1; // Map to 0-6 array index

          final double distanceMeters = (data['distanceMeters'] as num?)?.toDouble() ?? 0.0;
          final int durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;
          final double maxPace = (data['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;

          final double distanceKm = distanceMeters / 1000.0;
          final double timeMinutes = durationMs / 60000.0;
          final double speedKmh = maxPace > 0 ? (60 / maxPace) : 0.0;
          final double calories = distanceKm * 70.0; // Standard estimation fallback

          tempTime[dayIndex] += timeMinutes;
          tempDistance[dayIndex] += distanceKm;
          tempActivities[dayIndex] += 1;
          tempCalories[dayIndex] += calories;
          
          // Speed typically tracks the max or best for daily aggregations
          if (speedKmh > tempSpeed[dayIndex]) {
            tempSpeed[dayIndex] = speedKmh; 
          }
        }

        if (mounted) {
          setState(() {
            _timeData = tempTime;
            _speedData = tempSpeed;
            _distanceData = tempDistance;
            _activitiesData = tempActivities;
            _caloriesData = tempCalories;
            _isLoading = false;
          });
        }
      },
      onError: (e) {
        debugPrint('Error in profile statistics stream: $e');
        if (mounted) setState(() => _isLoading = false);
      },
    );
  }

}