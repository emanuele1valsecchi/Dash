import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/detailed_statistics_page.dart';
import 'package:dash/utils/run_estimates.dart';
import 'package:dash/utils/unit_formatter.dart';
import 'package:dash/widgets/units_scope.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ProfileStatisticsSection extends StatefulWidget {
  final String userId;

  /// Test seam. Production leaves it null and the state resolves `.instance`
  /// lazily — resolving it in a field initializer would throw
  /// `[core/no-app]` when the widget is *constructed*, before `runApp`, which
  /// is the same trap `NotificationsScreen` documents.
  @visibleForTesting
  final FirebaseFirestore? firestore;

  const ProfileStatisticsSection({
    super.key,
    required this.userId,
    this.firestore,
  });

  @override
  State<ProfileStatisticsSection> createState() => _ProfileStatisticsSectionState();
}

class _ProfileStatisticsSectionState extends State<ProfileStatisticsSection> {
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;

  static const _metrics = ['Time', 'Speed', 'Distance', 'Activities', 'Calories'];

  String _selectedMetric = _metrics[0];
  bool _isLoading = true;

  /// The week's runs, held in the units they are **stored** in.
  ///
  /// Bucketing into days and converting to the user's units both happen in
  /// `build`, not here. Which day the week starts on and whether distances
  /// read as km or miles are settings the user can change while this is on
  /// screen, and pre-computing either would freeze whatever was chosen when
  /// the query ran — the same reason `HomeScreen`'s monthly cards hold raw
  /// numbers and format them during build.
  List<_WeeklySession> _sessions = const [];

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
    final units = Units.of(context);

    final List<double> currentValues = _valuesFor(_selectedMetric, units);

    final double maxValue = currentValues.isNotEmpty ? currentValues.reduce((a, b) => a > b ? a : b) : 1.0;

    final bool hasData = maxValue > 0;
    final double safeMax = hasData ? maxValue : 1.0;

    final String topLabel = hasData ? _formatValueLabel(safeMax, units) : '';
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

                      _buildBackLines(labelStyle, labelWidth, hasData, safeMax, units),

                      _buildAnimatedBars(currentValues, chartHeight, labelWidth, barWidth, safeMax),
                    ],
                  ),
                ),

                _buildDaysRow(labelStyle, barWidth, labelWidth, units),

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

  /// Position of [at] within the user's week — 0 is whichever day they
  /// chose to start on, so the bars and the labels below them agree.
  int _dayIndex(DateTime at, int firstWeekday) =>
      (at.weekday - firstWeekday + 7) % 7;

  /// Midnight on the first day of the week containing [now].
  DateTime _startOfWeek(DateTime now, int firstWeekday) {
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(Duration(days: _dayIndex(today, firstWeekday)));
  }

  /// Day names rotated so index 0 is the user's first day of the week.
  List<String> _dayLabels(UnitFormatter units) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    // `firstWeekdayNumber` follows `DateTime.weekday`: Monday is 1.
    final first = units.firstWeekdayNumber;
    return [for (var i = 0; i < 7; i++) names[(first - 1 + i) % 7]];
  }

  /// The seven bars for [metric], already in the units the user reads.
  List<double> _valuesFor(String metric, UnitFormatter units) {
    final firstWeekday = units.firstWeekdayNumber;
    final start = _startOfWeek(DateTime.now(), firstWeekday);
    final values = List.filled(7, 0.0);

    for (final session in _sessions) {
      // The query reaches back further than one week so that either
      // week-start setting is covered; the extra days are dropped here.
      if (session.at.isBefore(start)) continue;
      final i = _dayIndex(session.at, firstWeekday);

      if (metric == _metrics[0]) {
        values[i] += session.durationMs / 60000.0;
      } else if (metric == _metrics[1]) {
        // The day's best pace, shown as a speed in the user's own distance
        // unit: min/km becomes metres per hour, then km/h or mph. Unlike the
        // others this is a maximum, not a total.
        if (session.maxPaceMinPerKm > 0) {
          final speed = units.metersToMajor(60000 / session.maxPaceMinPerKm);
          if (speed > values[i]) values[i] = speed;
        }
      } else if (metric == _metrics[2]) {
        values[i] += units.metersToMajor(session.distanceMeters);
      } else if (metric == _metrics[3]) {
        values[i] += 1;
      } else {
        // Energy is derived from distance in one place app-wide, and
        // mirrored server-side — never re-multiplied by a local constant.
        values[i] +=
            units.kcalToDisplay(caloriesForDistance(session.distanceMeters));
      }
    }
    return values;
  }

  String _formatValueLabel(double val, UnitFormatter units) {
    if (val == 0) return '';

    if (_selectedMetric == _metrics[0]) {
      int totalMinutes = val.round();
      int h = totalMinutes ~/ 60;
      int m = totalMinutes % 60;

      if (h > 0 && m > 0) return '${h}h ${m}m';
      if (h > 0) return '${h}h';
      return '${m}m';
    } else if (_selectedMetric == _metrics[1]) {
      return '${val.toStringAsFixed(1)} ${units.distanceUnitLabel}/h';
    } else if (_selectedMetric == _metrics[2]) {
      return '${val.toStringAsFixed(1)} ${units.distanceUnitLabel}';
    } else if (_selectedMetric == _metrics[3]) {
      return '${val.toInt()}';
    } else if (_selectedMetric == _metrics[4]) {
      return '${val.toInt()} ${units.energyUnitLabel}';
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

  Widget _buildBackLines(TextStyle labelStyle, double labelWidth,
      bool hasData, double safeMax, UnitFormatter units) {
    return Positioned(
      top: 0.0,
      bottom: 0.0,
      left: 0.0,
      right: 0.0,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildReferenceLine(labelStyle, labelWidth, 1, hasData ? _formatValueLabel(safeMax, units) : ''),
          _buildReferenceLine(labelStyle, labelWidth, 1, hasData ? _formatValueLabel(safeMax * 2 / 3, units) : ''),
          _buildReferenceLine(labelStyle, labelWidth, 1, hasData ? _formatValueLabel(safeMax / 3, units) : ''),
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
        children: List.generate(7, (index) {
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

  Widget _buildDaysRow(TextStyle labelStyle, double barWidth,
      double labelWidth, UnitFormatter units) {
    final labels = _dayLabels(units);
    final currentDayIndex =
        _dayIndex(DateTime.now(), units.firstWeekdayNumber);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      padding: EdgeInsetsGeometry.fromLTRB(0.0, 0.0, labelWidth, 0.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(7, (index) {
          final isToday = index == currentDayIndex;

          return SizedBox(
            width: barWidth,
            child: Text(
              labels[index],
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
    // Eight days rather than "since Monday": which day the week starts on is
    // a user setting that can change while this widget is on screen, and a
    // Sunday-start week can begin a day earlier than a Monday-start one. The
    // window is trimmed to the real week in `_valuesFor`, which knows the
    // current setting; fixing it here would freeze whatever was chosen when
    // the query ran.
    final since = DateTime.now().subtract(const Duration(days: 8));

    _sessionsSub = _db
        .collection('runningSessions')
        .where('userId', isEqualTo: widget.userId)
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
        .snapshots()
        .listen(
      (snapshot) {
        final sessions = <_WeeklySession>[];

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final Timestamp? timestamp = data['createdAt'] as Timestamp?;
          if (timestamp == null) continue;

          sessions.add(_WeeklySession(
            at: timestamp.toDate(),
            distanceMeters: (data['distanceMeters'] as num?)?.toDouble() ?? 0.0,
            durationMs: (data['durationMs'] as num?)?.toInt() ?? 0,
            maxPaceMinPerKm:
                (data['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0,
          ));
        }

        if (mounted) {
          setState(() {
            _sessions = sessions;
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

/// One run, kept in the units it is stored in — metres, milliseconds, and
/// minutes per kilometre.
///
/// Nothing here is converted or bucketed. Both of those depend on settings
/// the user can change without leaving this screen, so they happen during
/// `build` where the current choice is readable and a change rebuilds.
class _WeeklySession {
  const _WeeklySession({
    required this.at,
    required this.distanceMeters,
    required this.durationMs,
    required this.maxPaceMinPerKm,
  });

  final DateTime at;
  final double distanceMeters;
  final int durationMs;
  final double maxPaceMinPerKm;
}
