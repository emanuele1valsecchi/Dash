import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/screens/calendar_page.dart';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/home_models.dart';
import '../models/home_badge_ui_model.dart';
import '../services/badge_service.dart';
import '../services/location_service.dart';
import '../services/storage_service.dart';
import '../services/unit_preferences.dart';
import '../utils/unit_formatter.dart';
import '../widgets/units_scope.dart';
import '../services/water_fountain_service.dart';
import 'route_create_page.dart';
import 'route_search_page.dart';
import 'package:dash_watch_protocol/dash_watch_protocol.dart';

import 'run_tracking_page.dart';
import '../services/run_session_controller.dart';
import '../services/wear_bridge.dart';
import '../widgets/home/badge_progress_section.dart';
import '../widgets/home/leaderboard_preview_card.dart';
import '../widgets/home/start_run_overlay.dart';
import '../widgets/home/monthly_stats_section.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'leaderboard_page.dart';
import 'notifications_page.dart';


class _NoOverscrollBehavior extends ScrollBehavior {
  const _NoOverscrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showRunOverlay = false;
  HomeBadgeUiModel? _selectedBadge;

  // Leaderboard Carousel
  List<LeaderboardPreviewData>? _leaderboards;
  final PageController _pageController = PageController();
  int _currentLeaderboardPage = 0;

  // State management for distance and last 30 days statistics
  double _monthlyMeters = 0.0;
  bool _isLoadingKm = true;
  List<LeaderboardPreviewData> _rawLeaderboards = [];

  /// The raw, always-metric figures behind the monthly stat cards. Kept as
  /// numbers rather than formatted strings so that changing a unit re-renders
  /// them from `build` — formatting them at fetch time would have frozen
  /// whatever units were active when the Firestore query ran, and refreshing
  /// them would have meant re-querying.
  _MonthlyStatsRaw? _monthlyRaw; 

  final StorageService _storageService = StorageService();

  String _greetingName = '';

  StreamSubscription<DocumentSnapshot>? _profileSub;
  StreamSubscription<QuerySnapshot>? _sessionsSub;
  StreamSubscription<DocumentSnapshot>? _statsSub;
  StreamSubscription<QuerySnapshot>? _badgeProgressSub;
  StreamSubscription<QuerySnapshot>? _globalSessionsSub;

  List<HomeBadgeUiModel> _badges = [];
  QuerySnapshot<Map<String, dynamic>>? _latestSessionsSnap;
  DocumentSnapshot<Map<String, dynamic>>? _latestStatsSnap;

  @override
  void initState() {
    super.initState();
    LocationService.instance.start();
    WaterFountainService.instance.warmUp();
    UnitPreferences.instance.syncFromCloud();
    WearBridge.instance.start();
    _watchCommands = WearBridge.instance.commands.listen(_onWatchCommand);
    _watchImports = WearBridge.instance.importMessages.listen(_onWatchImportMessage);

    _startProfileStream();
    _startMonthlyStatsStreams();
    _startBadgesStream();
    _startLeaderboardStream();
  }

  /// Commands the watch cannot action on its own. Only `start` is handled here;
  /// `finish` belongs to whichever run screen is live.
  void _onWatchCommand(WatchCommand command) {
    if (command != WatchCommand.start) return;
    if (!mounted) return;

    // Only act when the app is actually on screen. A backgrounded phone can
    // receive the message and push the run screen, but cannot finish starting:
    // Android refuses a foreground-service start from the background, so the
    // run sits on "getting GPS position" until the user happens to open the
    // app — at which point it springs to life and collides with the run the
    // watch has been recording in the meantime. Ignoring it here is what lets
    // the watch keep the run it already started.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    // This screen stays mounted underneath the run screen, so without this
    // guard a stray start from the watch would stack a second RunTrackingPage
    // on top of a live run — and the new one would reset the controller.
    final session = RunSessionController.instance;
    if (session.hasStarted || session.isCountingDown) return;
    _startRunNow();
  }

  /// Watch commands this screen listens for. The bridge itself is app-lifetime
  /// and deliberately not disposed here — only this subscription is.
  StreamSubscription<WatchCommand>? _watchCommands;
  StreamSubscription<String>? _watchImports;

  /// A run arriving from the watch happens with no interaction at all — it can
  /// land minutes after the user opened the app. A snackbar is the least
  /// intrusive way to say so; anything modal would interrupt whatever they
  /// actually opened the app to do.
  void _onWatchImportMessage(String message) {
    if (!mounted) return;
    context.showInformationSnackBar(message);
  }

  @override
  void dispose() {
    _watchCommands?.cancel();
    _watchImports?.cancel();
    _profileSub?.cancel();
    _sessionsSub?.cancel();
    _statsSub?.cancel();
    _badgeProgressSub?.cancel();
    _globalSessionsSub?.cancel();
    _pageController.dispose();

    super.dispose();
  }

  void _startProfileStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _profileSub = FirebaseFirestore.instance
        .collection('profiles')
        .doc(user.uid)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data()!;
      final nickname = data['username'] ?? data['nickname'] ?? data['name'];
      if (nickname is String && nickname.trim().isNotEmpty) {
        setState(() => _greetingName = nickname.trim());
      }
    });
  }

  void _startMonthlyStatsStreams() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final sixtyDaysAgo = DateTime.now().subtract(const Duration(days: 60));

    _sessionsSub = FirebaseFirestore.instance
      .collection('runningSessions')
      .where('userId', isEqualTo: user.uid)
      .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(sixtyDaysAgo))
      .snapshots()
      .listen((snap) {
        _latestSessionsSnap = snap;
        _calculateMonthlyStats();
      });

    _statsSub = FirebaseFirestore.instance
        .collection('userStats')
        .doc(user.uid)
        .snapshots()
        .listen((snap) {
      _latestStatsSnap = snap;
      _calculateMonthlyStats(); 
    });
  }

  void _calculateMonthlyStats() {
    if (_latestSessionsSnap == null || _latestStatsSnap == null || !mounted) return;
    
    try{
      final now = DateTime.now();
      final thirtyDaysAgo = now.subtract(const Duration(days: 30));

      final currentMonthDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final previousMonthDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

      for (var doc in _latestSessionsSnap!.docs) {
        final data = doc.data();
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        if (createdAt == null) continue;

        if (createdAt.isAfter(thirtyDaysAgo) || createdAt.isAtSameMomentAs(thirtyDaysAgo)) {
          currentMonthDocs.add(doc);
        } else {
          previousMonthDocs.add(doc);
        }
      }

      final globalStats = _latestStatsSnap!.data() ?? {};
      final bestOverall = globalStats['bestOverall'] ?? {};
      
      final bestDistance = (bestOverall['maxDistanceMeters'] as num?)?.toDouble() ?? 0.0;
      final bestDurationMs = (bestOverall['maxDurationMs'] as num?)?.toInt() ?? 0;
      final bestSpeedKmh = (bestOverall['maxSpeedKmh'] as num?)?.toDouble() ?? 0.0;
      final bestAvgSpeedKmh = (bestOverall['maxAvgSpeedKmh'] as num?)?.toDouble() ?? 0.0;
      final bestCalories = (bestOverall['maxCaloriesBurned'] as num?)?.toDouble() ?? 0.0;

      double totalMeters = 0;
      double totalCalories = 0;
      int totalDurationMs = 0;
      double sumMaxSpeedsKmh = 0.0;

      final int completedActivities = currentMonthDocs.length;
      final int previousCompletedActivities = previousMonthDocs.length;

      for (var doc in currentMonthDocs) {
        final data = doc.data();
        
        totalMeters += (data['distanceMeters'] as num?)?.toDouble() ?? 0.0;
        totalCalories += (data['caloriesBurned'] as num?)?.toDouble() ?? 0.0;
        totalDurationMs += (data['durationMs'] as num?)?.toInt() ?? 0;

        double pace = (data['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;
        if (pace > 0) {
          sumMaxSpeedsKmh += (60 / pace);
        }
      }

      double avgDistanceMeters = completedActivities > 0 ? totalMeters / completedActivities : 0.0;
      double avgDurationMs = completedActivities > 0 ? totalDurationMs / completedActivities : 0.0;
      double avgCalories = completedActivities > 0 ? totalCalories / completedActivities : 0.0;
      double avgMaxSpeedKmh = completedActivities > 0 ? sumMaxSpeedsKmh / completedActivities : 0.0;

      double avgSpeed30d = 0.0;
      if (totalDurationMs > 0 && totalMeters > 0) {
        double totalHours = totalDurationMs / 3600000;
        avgSpeed30d = (totalMeters / 1000) / totalHours;
      }

      String avgDurationStr = '--';
      if (avgDurationMs > 0) {
        Duration d = Duration(milliseconds: avgDurationMs.toInt());
        avgDurationStr = d.inHours > 0 ? '${d.inHours}h ${d.inMinutes.remainder(60)}m' : '${d.inMinutes.remainder(60)} min';
      }

      double activitiesProgress = 0.0;
      if (previousCompletedActivities > 0) {
        activitiesProgress = (completedActivities / previousCompletedActivities).clamp(0.0, 1.0);
      } else if (completedActivities > 0) {
        activitiesProgress = 1.0; 
      }

      if (mounted) {
        setState(() {
          _monthlyMeters = totalMeters;
          _monthlyRaw = _MonthlyStatsRaw(
            avgDurationMs: avgDurationMs,
            bestDurationMs: bestDurationMs,
            avgMaxSpeedKmh: avgMaxSpeedKmh,
            bestSpeedKmh: bestSpeedKmh,
            avgSpeedKmh: avgSpeed30d,
            bestAvgSpeedKmh: bestAvgSpeedKmh,
            avgDistanceMeters: avgDistanceMeters,
            bestDistanceMeters: bestDistance,
            completedActivities: completedActivities,
            previousCompletedActivities: previousCompletedActivities,
            activitiesProgress: activitiesProgress,
            avgCalories: avgCalories,
            bestCalories: bestCalories,
            avgDurationStr: avgDurationStr,
          );
          _isLoadingKm = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading statistics: $e');
      if (mounted) setState(() => _isLoadingKm = false);
    }
  }

  /// Formats the monthly stat cards from the raw figures, in the units
  /// currently selected. Called from `build`, so a change of units re-renders
  /// the cards without touching Firestore.
  ///
  /// The three rate cards follow the pace/speed preference — including their
  /// titles, since "Average speed" over a pace figure would be simply wrong.
  List<MonthlyStatData> _buildMonthlyStats(UnitFormatter units) {
    final raw = _monthlyRaw;
    if (raw == null) return const [];

    final rateWord = units.rateLabel.toLowerCase();

    return [
      MonthlyStatData(
        title: 'Average\nsession time',
        value: raw.avgDurationStr,
        icon: Icons.timer_outlined,
        progress: raw.bestDurationMs > 0
            ? (raw.avgDurationMs / raw.bestDurationMs).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestDurationMs > 0
            ? 'Best overall: ${Duration(milliseconds: raw.bestDurationMs).inMinutes} min'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Average best\n$rateWord',
        value: units.rateFromSpeedKmh(raw.avgMaxSpeedKmh),
        icon: Icons.speed_rounded,
        progress: raw.bestSpeedKmh > 0
            ? (raw.avgMaxSpeedKmh / raw.bestSpeedKmh).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestSpeedKmh > 0
            ? 'Best overall: ${units.rateFromSpeedKmh(raw.bestSpeedKmh)}'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Average\n$rateWord',
        value: units.rateFromSpeedKmh(raw.avgSpeedKmh),
        icon: Icons.shutter_speed_rounded,
        progress: raw.bestAvgSpeedKmh > 0
            ? (raw.avgSpeedKmh / raw.bestAvgSpeedKmh).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestAvgSpeedKmh > 0
            ? 'Best overall: ${units.rateFromSpeedKmh(raw.bestAvgSpeedKmh)}'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Average\ndistance',
        value: raw.avgDistanceMeters > 0
            ? units.distance(raw.avgDistanceMeters, decimals: 1)
            : '--',
        icon: Icons.swap_horiz_rounded,
        progress: raw.bestDistanceMeters > 0
            ? (raw.avgDistanceMeters / raw.bestDistanceMeters).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestDistanceMeters > 0
            ? 'Best overall: ${units.distance(raw.bestDistanceMeters, decimals: 1)}'
            : 'No records yet',
      ),
      MonthlyStatData(
        title: 'Completed\nactivities',
        value: '${raw.completedActivities}',
        icon: Icons.directions_run_rounded,
        progress: raw.activitiesProgress,
        bottomText: 'Previous 30 days: ${raw.previousCompletedActivities}',
      ),
      MonthlyStatData(
        title: 'Average\ncalories',
        value: raw.avgCalories > 0 ? units.energy(raw.avgCalories) : '--',
        icon: Icons.local_fire_department_rounded,
        progress: raw.bestCalories > 0
            ? (raw.avgCalories / raw.bestCalories).clamp(0.0, 1.0)
            : 0.0,
        bottomText: raw.bestCalories > 0
            ? 'Best overall: ${units.energy(raw.bestCalories)}'
            : 'No records yet',
      ),
    ];
  }

  void _startLeaderboardStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    
    final db = FirebaseFirestore.instance;

    // Listen to the entire runningSessions collection in real-time
    _globalSessionsSub = db.collection('runningSessions').snapshots().listen((sessionsSnap) async {
      if (!mounted) return;

      try {
        // 1. Fetch your following list (we use .get() here to keep it simple, 
        // but you could stream this too if you wanted instant friend updates)
        final followsSnap = await db.collection('follows').where('followerId', isEqualTo: user.uid).get();
        final List<String> followingIds = followsSnap.docs.map((d) => d.data()['followingId'] as String).toList();

        Map<String, Map<String, int>> cityUserPoints = {};
        Map<String, int> globalUserPoints = {};
        Map<String, DateTime> currentUserCities = {};

        // 2. Tally up all the points from the streamed data
        for (var doc in sessionsSnap.docs) {
          final data = doc.data();
          final userId = data['userId'] as String?;
          final points = (data['pointsEarned'] as num?)?.toInt() ?? 0;
          final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

          final rawLocality = (data['startLocality'] as String?)?.trim() ?? '';
          final rawTerritory = (data['territoryCity'] as String?)?.trim() ?? '';
          final city = rawLocality.isNotEmpty ? rawLocality : (rawTerritory.isNotEmpty ? rawTerritory : 'Unknown');

          if (userId != null && createdAt != null) {
            globalUserPoints[userId] = (globalUserPoints[userId] ?? 0) + points;

            if (city != 'Unknown') {
              cityUserPoints.putIfAbsent(city, () => {});
              cityUserPoints[city]![userId] = (cityUserPoints[city]![userId] ?? 0) + points;

              if (userId == user.uid) {
                if (!currentUserCities.containsKey(city) || createdAt.isAfter(currentUserCities[city]!)) {
                  currentUserCities[city] = createdAt;
                }
              }
            }
          }
        }

        // 3. Sort user cities
        var sortedCities = currentUserCities.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        var allUserCities = sortedCities.map((e) => e.key).toList();

        List<LeaderboardPreviewData> previews = [];

        // 4. Helper function to build the card data (identical to your original logic)
        Future<LeaderboardPreviewData> buildCardData(Map<String, int> pointsMap, String title) async {
          if (!pointsMap.containsKey(user.uid)) pointsMap[user.uid] = 0;
          var sortedMap = pointsMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
          final currentUserPoints = pointsMap[user.uid]!;
          final currentRank = sortedMap.indexWhere((e) => e.key == user.uid) + 1;

          Set<String> selectedUserIds = {user.uid};
          for (var id in followingIds) {
            if (pointsMap.containsKey(id) && selectedUserIds.length < 10) selectedUserIds.add(id);
          }

          int upIndex = currentRank - 2;
          int downIndex = currentRank;
          while (selectedUserIds.length < 10 && (upIndex >= 0 || downIndex < sortedMap.length)) {
            if (upIndex >= 0) { selectedUserIds.add(sortedMap[upIndex].key); upIndex--; }
            if (selectedUserIds.length < 10 && downIndex < sortedMap.length) {
              selectedUserIds.add(sortedMap[downIndex].key); downIndex++;
            }
          }

          List<PreviewPin> pins = [];
          int maxPointsInSelection = 1;
          for (var id in selectedUserIds) {
            if ((pointsMap[id] ?? 0) > maxPointsInSelection) maxPointsInSelection = pointsMap[id]!;
          }

          for (var id in selectedUserIds) {
            final profileDoc = await db.collection('profiles').doc(id).get();
            final profileImageUrl = profileDoc.data()?['profileImageUrl'] as String? ?? '';

            final pts = pointsMap[id] ?? 0;
            double normalized = pts / maxPointsInSelection;
            if (id != user.uid) normalized += (id.hashCode % 10) / 1000.0;

            pins.add(PreviewPin(
              userId: id,
              profileImageUrl: profileImageUrl,
              normalizedPosition: normalized.clamp(0.0, 1.0),
              isCurrentUser: id == user.uid,
            ));
          }

          return LeaderboardPreviewData(
            position: currentRank,
            points: currentUserPoints,
            variation: null,
            city: title,
            pins: pins,
          );
        }

        // 5. Generate the preview cards
        for (var city in allUserCities) {
          previews.add(await buildCardData(cityUserPoints[city]!, city));
        }

        previews.add(await buildCardData(globalUserPoints, 'Global Leaderboard'));

        // Salviamo i dati grezzi in memoria e applichiamo subito l'ordinamento
        _rawLeaderboards = previews;
        await _applyLeaderboardPreferences();
        
      } catch (e) {
        debugPrint("Error in Leaderboard Stream Widget: $e");
      }
    });
  }

  Future<void> _applyLeaderboardPreferences() async {
    if (_rawLeaderboards.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final String? savedData = prefs.getString('home_leaderboard_config');

    // Lavoriamo su una copia dei dati grezzi
    List<LeaderboardPreviewData> currentPreviews = List.from(_rawLeaderboards);

    if (savedData != null) {
      final List<dynamic> decoded = jsonDecode(savedData);
      List<LeaderboardPreviewData> sortedAndFilteredPreviews = [];

      // Read the preferred order saved by the user
      for (var item in decoded) {
        final String title = item['title'];
        
        // --- NEW: Force Global Leaderboard to always be visible ---
        final bool isVisible = (title == 'Global Leaderboard') ? true : (item['isVisible'] ?? true);

        if (isVisible) {
          // Check if a card exists for that newly generated city in the raw data
          final index = currentPreviews.indexWhere((p) => p.city == title);
          if (index != -1) {
            sortedAndFilteredPreviews.add(currentPreviews[index]);
            currentPreviews.removeAt(index); // Remove to avoid duplication
          }
        } else {
          // Remove hidden cities
          currentPreviews.removeWhere((p) => p.city == title);
        }
      }

      // Aggiungi eventuali "città nuove" scoperte che non erano ancora salvate nelle impostazioni
      sortedAndFilteredPreviews.addAll(currentPreviews);
      currentPreviews = sortedAndFilteredPreviews;
    }

    if (mounted) {
      setState(() {
        _leaderboards = currentPreviews;
      });
    }
  }
  
  void _startBadgesStream() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 1. Fetch the static global badge definitions once
    final staticBadges = await BadgeService().getHomeBadges(user.uid);
    
    // 2. Stream the user's specific progress for those badges
    _badgeProgressSub = FirebaseFirestore.instance
      .collection('profiles')
      .doc(user.uid)
      .collection('badge_progress')
      .snapshots()
      .listen((snap) async {
      
        final updatedBadges = <HomeBadgeUiModel>[];
        
        for (final badge in staticBadges) {
          String imageUrl = '';
          try {
            imageUrl = await _storageService.getDownloadUrl(badge.imagePath);
          } catch (_) {}

          // Find the matching progress document from the stream snapshot
          final progressDoc = snap.docs.where((d) => d.id == badge.id).firstOrNull;
          
          double progress = 0.0;
          bool unlocked = false;
          
          if (progressDoc != null) {
            final data = progressDoc.data();
            final rawProgress = (data['progress'] as num?)?.toDouble() ?? 0.0;
            progress = (rawProgress / 100).clamp(0.0, 1.0);
            unlocked = data['unlocked'] == true || progress >= 1.0;
          }

          updatedBadges.add(HomeBadgeUiModel(
            badgeId: badge.id,
            title: badge.title,
            description: badge.description,
            imageUrl: imageUrl,
            progress: progress,
            unlocked: unlocked,
          ));
        }

        if (mounted) setState(() => _badges = updatedBadges);
      });
  }

  void _openLeaderboard(String city) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LeaderboardScreen(cityFilter: city)),
    );
  }

  void _openNotifications() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CalendarScreen()),
    );
  }

  Future<void> _searchRoute() async {
    setState(() => _showRunOverlay = false);
    final runRoute = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(builder: (_) => const RouteSearchPage()),
    );
    if (runRoute != null && mounted) {
      await _pushRunTracking(plannedRoute: runRoute);
    }
  }

  Future<void> _createRoute() async {
    setState(() => _showRunOverlay = false);
    final runRoute = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(builder: (_) => const RouteCreatePage()),
    );
    if (runRoute != null && mounted) {
      await _pushRunTracking(plannedRoute: runRoute);
    }
  }

  Future<void> _startRunNow() async {
    setState(() => _showRunOverlay = false);
    await _pushRunTracking();
  }

  Future<void> _pushRunTracking({List<LatLng>? plannedRoute}) async {
    final summary = await Navigator.of(context).push<RunSummary>(
      MaterialPageRoute(
        builder: (_) => RunTrackingPage(plannedRoute: plannedRoute),
      ),
    );
    if (summary == null || !mounted) return;

    if (!summary.saved) {
      context.showWarningSnackBar("Run discarded");
      return;
    }

    // A snackbar is a one-shot string, so a snapshot of the units is right
    // here — nothing would redraw it if they changed a second later anyway.
    final distance = Units.current.distanceMajor(summary.distanceMeters);
    final minutes = summary.elapsed.inMinutes;
    final loopsText = summary.loopsCompleted > 0
        ? ', ${summary.loopsCompleted} loop${summary.loopsCompleted == 1 ? '' : 's'} closed'
        : '';
    context.showSuccessSnackBar(
        'Run saved — $distance in $minutes min$loopsText');
  }

  void _openBadgePopup(HomeBadgeUiModel badge) {
    setState(() {
      _selectedBadge = badge;
    });
  }

  void _closeBadgePopup() {
    setState(() {
      _selectedBadge = null;
    });
  }

  String _buildProgressLabel(HomeBadgeUiModel badge) {
    if (badge.unlocked) {
      return 'Unlocked';
    }

    final percent = (badge.progress * 100).clamp(0.0, 100.0);
    return '${percent.toStringAsFixed(0)}% Completed';
  }

  @override
  Widget build(BuildContext context) {
    final greetingText =
        _greetingName.trim().isEmpty ? 'Hi!' : 'Hi $_greetingName!';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "",
        actions: [
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
              .collection('notifications')
              .where('userId', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
              .where('isRead', isEqualTo: false)
              .snapshots(),

            builder: (context, snapshot) {
              final bool hasUnread = snapshot.hasData && snapshot.data!.docs.isNotEmpty;

              return Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    onPressed: _openNotifications,
                    icon: Icon(
                      Symbols.notifications_none_rounded,
                    ),
                  ),
                  if (hasUnread)
                    Positioned(
                      right: 12, 
                      top: 12,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          IconButton(
            onPressed: _openHistory,
            icon: const Icon(
              Symbols.history_rounded,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: ScrollConfiguration(
              behavior: const _NoOverscrollBehavior(),
              child: NotificationListener<OverscrollIndicatorNotification>(
                onNotification: (notification) {
                  notification.disallowIndicator();
                  return true;
                },
                child: Column(
                  children: [
                    Expanded(
                      child: RefreshIndicator(
                        color: const Color(0xFF425143),
                        backgroundColor: const Color(0xFFCAF0B8),
                        onRefresh: () async {
                          await _applyLeaderboardPreferences();
                        },
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 85),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                greetingText,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF2A3028),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    _isLoadingKm
                                        ? '-- ${Units.of(context).distanceUnitLabel}'
                                        : Units.of(context).distanceMajor(
                                            _monthlyMeters,
                                            decimals: 1),
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF1F3020),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      'ran in the last 30 days',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Color(0xFF5E655C),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              const Row(
                                children: [
                                  Icon(
                                    Icons.bar_chart_rounded,
                                    color: Color(0xFF4A554A),
                                    size: 24,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Leaderboards',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF394137),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              
                              if (_leaderboards != null && _leaderboards!.isNotEmpty)
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      height: 255, 
                                      child: PageView.builder(
                                        controller: _pageController,
                                        onPageChanged: (index) {
                                          setState(() => _currentLeaderboardPage = index);
                                        },
                                        itemCount: _leaderboards!.length,
                                        itemBuilder: (context, index) {
                                          final data = _leaderboards![index];
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 2), 
                                            child: LeaderboardPreviewCard(
                                              data: data,
                                              onTap: () => _openLeaderboard(data.city),
                                            ),
                                          );
                                        }
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    
                                    // SMART FLUID INDICATOR
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: List.generate(
                                        _leaderboards!.length,
                                        (index) {
                                          final dist = (index - _currentLeaderboardPage).abs();
                                          
                                          double width;
                                          double height;
                                          double margin;

                                          if (dist == 0) {
                                            width = 16; height = 6; margin = 4; // Active (Long)
                                          } else if (dist <= 2) { 
                                            width = 6; height = 6; margin = 4; // Near (Normal)
                                          } else if (dist == 3) {
                                            width = 4; height = 4; margin = 3; // Far (Small/Faded)
                                          } else {
                                            width = 0; height = 0; margin = 0; // Too far (Invisible)
                                          }

                                          return AnimatedContainer(
                                            duration: const Duration(milliseconds: 300),
                                            curve: Curves.easeOutCubic,
                                            margin: EdgeInsets.symmetric(horizontal: margin),
                                            height: height,
                                            width: width,
                                            decoration: BoxDecoration(
                                              color: _currentLeaderboardPage == index
                                                  ? const Color(0xFF4A8C52) 
                                                  : const Color(0xFFD3D6CE), 
                                              borderRadius: BorderRadius.circular(3),
                                            ),
                                          );
                                        },
                                      ),
                                    )
                                  ],
                                )
                              else
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: CircularProgressIndicator(color: Color(0xFF4A8C52)),
                                  ),
                                ),
                                
                              const SizedBox(height: 28),
                              if (_badges.isEmpty)
                                const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else
                                BadgeProgressSection(
                                  badges: _badges,
                                  onBadgeTap: _openBadgePopup,
                                ),
                              const SizedBox(height: 28),
                              MonthlyStatsSection(
                                  stats: _buildMonthlyStats(Units.of(context))),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          StartRunOverlay(
            isOpen: _showRunOverlay,
            onClose: () => setState(() => _showRunOverlay = false),
            onSearchRoute: _searchRoute,
            onCreateRoute: _createRoute,
            onStartRun: _startRunNow,
          ),
          if (_selectedBadge != null) ...[
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeBadgePopup,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.22),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.10),
                  ),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: 320,
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F6EF),
                      borderRadius: BorderRadius.circular(26),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 18,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: 24),
                            const Spacer(),
                            GestureDetector(
                              onTap: _closeBadgePopup,
                              child: const Icon(
                                Icons.close,
                                color: Color(0xFF6B7367),
                                size: 24,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: 128,
                          height: 128,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF6F8C63),
                              width: 7,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: ClipOval(
                              child: _selectedBadge!.imageUrl.isNotEmpty
                                  ? Builder(
                                      builder: (context) {
                                        final progress = _selectedBadge!.progress.clamp(0.0, 1.0);
                                        final isUnlocked = _selectedBadge!.unlocked || progress >= 1.0;
                                        final isActive = progress > 0.0;

                                        return ColorFiltered(
                                          colorFilter: isUnlocked || isActive
                                              ? const ColorFilter.mode(
                                                  Colors.transparent,
                                                  BlendMode.multiply,
                                                )
                                              : const ColorFilter.matrix(<double>[
                                                  0.2126, 0.7152, 0.0722, 0, 0,
                                                  0.2126, 0.7152, 0.0722, 0, 0,
                                                  0.2126, 0.7152, 0.0722, 0, 0,
                                                  0, 0, 0, 1, 0,
                                                ]),
                                          child: CachedNetworkImage(
                                            imageUrl: _selectedBadge!.imageUrl,
                                            fit: BoxFit.cover,
                                            placeholder: (context, url) => Container(
                                              color: const Color(0xFFE5E9DF),
                                              alignment: Alignment.center,
                                              child: const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Color(0xFF6F8C63),
                                                ),
                                              ),
                                            ),
                                            errorWidget: (context, url, error) => Container(
                                              color: const Color(0xFFE5E9DF),
                                              alignment: Alignment.center,
                                              child: const Icon(
                                                Icons.image_not_supported_outlined,
                                                color: Color(0xFF7A8377),
                                                size: 34,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    )
                                  : Container(
                                      color: const Color(0xFFE5E9DF),
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.image_outlined,
                                        color: Color(0xFF7A8377),
                                        size: 34,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _selectedBadge!.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF5A6256),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF2EA),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFE2E6DC),
                            ),
                          ),
                          child: Text(
                            _buildProgressLabel(_selectedBadge!),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF6D7468),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          _selectedBadge!.description,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.65,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF687161),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      floatingActionButton: !_showRunOverlay
          ? FloatingActionButton(
              onPressed: () => setState(() => _showRunOverlay = true),
              backgroundColor: const Color(0xFFCAF0B8),
              elevation: 2,
              child: const Icon(
                Icons.directions_run_rounded,
                color: Color(0xFF425143),
                size: 30,
              ),
            )
          : null,
    );
  }
}

/// The always-metric figures behind the home screen's monthly stat cards.
///
/// Split out from the Firestore fetch so the cards can be *formatted* during
/// `build` — that is what lets a change of units re-render them immediately
/// without another query. [avgDurationStr] is the one pre-formatted member:
/// a duration has no unit setting to respect.
class _MonthlyStatsRaw {
  const _MonthlyStatsRaw({
    required this.avgDurationMs,
    required this.bestDurationMs,
    required this.avgMaxSpeedKmh,
    required this.bestSpeedKmh,
    required this.avgSpeedKmh,
    required this.bestAvgSpeedKmh,
    required this.avgDistanceMeters,
    required this.bestDistanceMeters,
    required this.completedActivities,
    required this.previousCompletedActivities,
    required this.activitiesProgress,
    required this.avgCalories,
    required this.bestCalories,
    required this.avgDurationStr,
  });

  final double avgDurationMs;
  final int bestDurationMs;
  final double avgMaxSpeedKmh;
  final double bestSpeedKmh;
  final double avgSpeedKmh;
  final double bestAvgSpeedKmh;
  final double avgDistanceMeters;
  final double bestDistanceMeters;
  final int completedActivities;
  final int previousCompletedActivities;
  final double activitiesProgress;
  final double avgCalories;
  final double bestCalories;
  final String avgDurationStr;
}