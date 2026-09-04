import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class DetailedStatisticsPage extends StatefulWidget {
  final String userId;

  const DetailedStatisticsPage({
    super.key,
    required this.userId,
  });

  @override
  State<DetailedStatisticsPage> createState() => _DetailedStatisticsPageState();
}

class _DetailedStatisticsPageState extends State<DetailedStatisticsPage> {
  bool _isLoading = true;
  
  // Time
  String _maxTimeStr = '0 min';
  String _minTimeStr = '0 min';
  String _avgTimeStr = '0 min';

  // Speed
  String _maxSpeedStr = '0 km/h';
  String _minSpeedStr = '0 km/h';
  String _avgSpeedStr = '0 km/h';

  // Distance
  String _maxDistanceStr = '0 km';
  String _minDistanceStr = '0 km';
  String _avgDistanceStr = '0 km';

  // Activities
  int _activitiesCompleted = 0;
  String _avgWeeklyActivitiesStr = '0';
  String _avgMonthlyActivitiesStr = '0';

  // Calories
  String _totalCaloriesStr = '0 kCal';
  String _maxCaloriesStr = '0 kCal';
  String _minCaloriesStr = '0 kCal';
  String _avgCaloriesStr = '0 kCal';

  @override
  void initState() {
    super.initState();
    _fetchAndProcessStatistics();
  }

  Future<void> _fetchAndProcessStatistics() async {
    try {
      final sessionsSnap = await FirebaseFirestore.instance
          .collection('runningSessions')
          .where('userId', isEqualTo: widget.userId)
          .get();

      final docs = sessionsSnap.docs;
      _activitiesCompleted = docs.length;

      if (docs.isNotEmpty) {
        // Trackers for min/max/total
        int maxDurationMs = 0;
        int minDurationMs = double.maxFinite.toInt();
        int totalDurationMs = 0;

        double maxSpeedKmh = 0;
        double minSpeedKmh = double.maxFinite.toDouble();

        double maxDistanceMeters = 0;
        double minDistanceMeters = double.maxFinite.toDouble();
        double totalDistanceMeters = 0;

        double maxCalories = 0;
        double minCalories = double.maxFinite.toDouble();
        double totalCalories = 0;

        DateTime? earliestRunDate;

        for (var doc in docs) {
          final data = doc.data();
          
          final double distanceMeters = (data['distanceMeters'] as num?)?.toDouble() ?? 0.0;
          final int durationMs = (data['durationMs'] as num?)?.toInt() ?? 0;
          final double maxPace = (data['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;
          final Timestamp? timestamp = data['createdAt'] as Timestamp?;
          
          if (timestamp != null) {
            final DateTime runDate = timestamp.toDate();
            if (earliestRunDate == null || runDate.isBefore(earliestRunDate)) {
              earliestRunDate = runDate;
            }
          }

          final double distanceKm = distanceMeters / 1000.0;
          final double speedKmh = maxPace > 0 ? (60.0 / maxPace) : 0.0;
          final double calories = distanceKm * 70.0; // Standard estimation

          // Time tracking
          if (durationMs > maxDurationMs) maxDurationMs = durationMs;
          if (durationMs < minDurationMs && durationMs > 0) minDurationMs = durationMs;
          totalDurationMs += durationMs;

          // Distance tracking
          if (distanceMeters > maxDistanceMeters) maxDistanceMeters = distanceMeters;
          if (distanceMeters < minDistanceMeters && distanceMeters > 0) minDistanceMeters = distanceMeters;
          totalDistanceMeters += distanceMeters;

          // Speed tracking
          if (speedKmh > maxSpeedKmh) maxSpeedKmh = speedKmh;
          if (speedKmh < minSpeedKmh && speedKmh > 0) minSpeedKmh = speedKmh;

          // Calories tracking
          if (calories > maxCalories) maxCalories = calories;
          if (calories < minCalories && calories > 0) minCalories = calories;
          totalCalories += calories;
        }

        // --- Time Strings ---
        _maxTimeStr = _formatDuration(maxDurationMs);
        _minTimeStr = minDurationMs == double.maxFinite.toInt() ? '0 min' : _formatDuration(minDurationMs);
        _avgTimeStr = _formatDuration((totalDurationMs / _activitiesCompleted).toInt());

        // --- Speed Strings ---
        _maxSpeedStr = '${maxSpeedKmh.toStringAsFixed(1)} km/h';
        _minSpeedStr = '${minSpeedKmh == double.maxFinite.toDouble() ? 0 : minSpeedKmh.toStringAsFixed(1)} km/h';
        
        final double totalHours = totalDurationMs / 3600000.0;
        final double avgOverallSpeed = totalHours > 0 ? (totalDistanceMeters / 1000.0) / totalHours : 0.0;
        _avgSpeedStr = '${avgOverallSpeed.toStringAsFixed(1)} km/h';

        // --- Distance Strings ---
        _maxDistanceStr = _formatDistance(maxDistanceMeters);
        _minDistanceStr = minDistanceMeters == double.maxFinite.toDouble() ? '0 m' : _formatDistance(minDistanceMeters);
        _avgDistanceStr = _formatDistance(totalDistanceMeters / _activitiesCompleted);

        // --- Activities (Weekly/Monthly Averages) ---
        if (earliestRunDate != null) {
          final int daysActive = DateTime.now().difference(earliestRunDate).inDays;
          final double weeksActive = (daysActive / 7.0).clamp(1.0, double.infinity);
          final double monthsActive = (daysActive / 30.44).clamp(1.0, double.infinity);

          _avgWeeklyActivitiesStr = (_activitiesCompleted / weeksActive).toStringAsFixed(1);
          _avgMonthlyActivitiesStr = (_activitiesCompleted / monthsActive).toStringAsFixed(1);
        } else {
          _avgWeeklyActivitiesStr = _activitiesCompleted.toString();
          _avgMonthlyActivitiesStr = _activitiesCompleted.toString();
        }

        // --- Calories Strings ---
        _totalCaloriesStr = '${totalCalories.toInt()} kCal';
        _maxCaloriesStr = '${maxCalories.toInt()} kCal';
        _minCaloriesStr = '${minCalories == double.maxFinite.toDouble() ? 0 : minCalories.toInt()} kCal';
        _avgCaloriesStr = '${(totalCalories / _activitiesCompleted).toInt()} kCal';
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error loading detailed statistics: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return '0 min';
    Duration d = Duration(milliseconds: ms);
    if (d.inHours > 0) {
      return '${d.inHours} h ${d.inMinutes.remainder(60)} min';
    }
    return '${d.inMinutes} min';
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.toInt()} m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Detailed Statistics",
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(ResponsiveSpacing().md),
              children: [
                _buildStatCategory(context, "Time", Symbols.timer_rounded, [
                  _StatRow(label: "Maximum", value: _maxTimeStr),
                  _StatRow(label: "Minimum", value: _minTimeStr),
                  _StatRow(label: "Average", value: _avgTimeStr),
                ]),
                _buildStatCategory(context, "Speed", Symbols.sprint_rounded, [
                  _StatRow(label: "Maximum", value: _maxSpeedStr),
                  _StatRow(label: "Minimum", value: _minSpeedStr),
                  _StatRow(label: "Average", value: _avgSpeedStr),
                ]),
                _buildStatCategory(context, "Distance", Symbols.arrow_range_rounded, [
                  _StatRow(label: "Maximum", value: _maxDistanceStr),
                  _StatRow(label: "Minimum", value: _minDistanceStr),
                  _StatRow(label: "Average", value: _avgDistanceStr),
                ]),
                _buildStatCategory(context, "Activities", Symbols.steps_rounded, [
                  _StatRow(label: "Completed activities", value: "$_activitiesCompleted"),
                  _StatRow(label: "Average week completed activities", value: _avgWeeklyActivitiesStr),
                  _StatRow(label: "Monthly average completed activities", value: _avgMonthlyActivitiesStr),
                ]),
                _buildStatCategory(context, "Calories", Symbols.mode_heat_rounded, [
                  _StatRow(label: "Total calories burnt using the app", value: _totalCaloriesStr),
                  _StatRow(label: "Maximum calories", value: _maxCaloriesStr),
                  _StatRow(label: "Minimum calories", value: _minCaloriesStr),
                  _StatRow(label: "Average Calories", value: _avgCaloriesStr),
                ]),
              ],
            ),
    );
  }

  Widget _buildStatCategory(BuildContext context, String title, IconData icon, List<_StatRow> rows) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: ResponsiveSpacing().lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: ResponsiveSpacing().sm,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...rows,
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: ResponsiveSpacing().sm / 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}