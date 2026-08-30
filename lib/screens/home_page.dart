import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/calendar_page.dart';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/home/leaderboard_section.dart';
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
import '../utils/run_estimates.dart';
import '../widgets/units_scope.dart';
import '../services/water_fountain_service.dart';
import 'route_create_page.dart';
import 'route_library_page.dart';
import 'package:dash_watch_protocol/dash_watch_protocol.dart';

import 'run_tracking_page.dart';
import '../services/run_session_controller.dart';
import '../services/wear_bridge.dart';
import '../widgets/home/badge_progress_section.dart';
import '../widgets/home/start_run_overlay.dart';
import '../widgets/home/monthly_stats_section.dart';
import '../utils/leaderboard_order.dart';
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final GlobalKey _fabKey = GlobalKey();

  // Leaderboard Carousel
  List<LeaderboardPreviewData>? _leaderboards;

  // State management for distance and last 30 days statistics
  double _monthlyMeters = 0.0;
  bool _isLoadingKm = true;
  List<LeaderboardPreviewData> _rawLeaderboards = [];

  /// The raw, always-metric figures behind the monthly stat cards. Kept as
  /// numbers rather than formatted strings so that changing a unit re-renders
  /// them from `build` — formatting them at fetch time would have frozen
  /// whatever units were active when the Firestore query ran, and refreshing
  /// them would have meant re-querying.
  MonthlyStatsRaw? _monthlyRaw; 

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

  /// Watch commands this screen listens for. The bridge itself is app-lifetime
  /// and deliberately not disposed here — only this subscription is.
  StreamSubscription<WatchCommand>? _watchCommands;
  StreamSubscription<String>? _watchImports;

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

  @override
  void dispose() {
    _watchCommands?.cancel();
    _watchImports?.cancel();
    _profileSub?.cancel();
    _sessionsSub?.cancel();
    _statsSub?.cancel();
    _badgeProgressSub?.cancel();
    _globalSessionsSub?.cancel();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme contextColorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "",
        actions: [
          _buildNotificationIconButton(),
          IconButton(
            onPressed: _openHistory,
            icon: const Icon(
              Symbols.history_rounded,
            ),
          ),
        ],
      ),
      body: SafeArea(
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
                    color: contextColorScheme.onPrimaryContainer,
                    backgroundColor: contextColorScheme.primaryContainer,
                    onRefresh: () async {
                      await _applyLeaderboardPreferences();
                    },
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 84),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: ResponsiveSpacing().xl,
                        children: [
                          _buildGreetingText(context),
                          _buildAchievementText(),
                          _buildLeaderBoard(),
                          _buildBadgesSection(),
                          MonthlyStatsSection( rawStats: _monthlyRaw ),
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

      floatingActionButton: FloatingActionButton(
        key: _fabKey,
        heroTag: null,
        onPressed: _showStartMenu,
        backgroundColor: contextColorScheme.primaryContainer,
        elevation: 2,
        child: Icon(
          Symbols.directions_run_rounded,
          color: contextColorScheme.onPrimaryContainer,
          size: Theme.of(context).textTheme.displaySmall!.fontSize,
        ),
      ),
    );
  }

  void _showStartMenu() {
    final RenderBox? fabRenderBox = _fabKey.currentContext?.findRenderObject() as RenderBox?;
    
    if (fabRenderBox == null) return;

    final fabPosition = fabRenderBox.localToGlobal(Offset.zero);
    final fabRect = fabPosition & fabRenderBox.size;

    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false, 
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) {
          return StartRunOverlay(
            animation: animation,
            fabRect: fabRect, 
            onSearchRoute: _searchRoute,
            onCreateRoute: _createRoute,
            onStartRun: _startRunNow,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return child;
        },
      ),
    );
  }

  Widget _buildNotificationIconButton(){
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
        .collection('notifications')
        .where('userId', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
        .where('isRead', isEqualTo: false)
        .snapshots(),
      
      builder: (context, snapshot) {
        final bool hasUnread = snapshot.hasData && snapshot.data!.docs.isNotEmpty;

        return IconButton(
          onPressed: _openNotifications, 
          icon: Badge(
            alignment: AlignmentGeometry.topRight,
            isLabelVisible: hasUnread,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Icon(
              Symbols.notifications_rounded,
              fill: (hasUnread) ? 1 : 0,
            ),
          )
        );
      }
    );
  }

  Widget _buildGreetingText(BuildContext context){
    final greetingText =
        _greetingName.trim().isEmpty ? 'Hi!' : 'Hi $_greetingName!';

    return Text(
      greetingText,
      style: Theme.of(context).textTheme.displaySmall
    );
  }

  Widget _buildAchievementText(){
    return Row(
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
    );
  }

  Widget _buildLeaderBoard(){
    if (_leaderboards != null && _leaderboards!.isNotEmpty) {
      return LeaderboardSection(
        leaderboards: _leaderboards!,
        onLeaderboardTap: _openLeaderboard,
      );
    }

    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget _buildBadgesSection(){
    if (_badges.isEmpty){
      return Center(
        child: Padding(
          padding: context.paddingSm,
          child: CircularProgressIndicator(),
        ),
      );
    }

    return BadgeProgressSection(
      badges: _badges,
    );
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
      int totalDurationMs = 0;
      double sumMaxSpeedsKmh = 0.0;

      final int completedActivities = currentMonthDocs.length;
      final int previousCompletedActivities = previousMonthDocs.length;

      for (var doc in currentMonthDocs) {
        final data = doc.data();

        totalMeters += (data['distanceMeters'] as num?)?.toDouble() ?? 0.0;
        totalDurationMs += (data['durationMs'] as num?)?.toInt() ?? 0;

        double pace = (data['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;
        if (pace > 0) {
          sumMaxSpeedsKmh += (60 / pace);
        }
      }

      double avgDistanceMeters = completedActivities > 0 ? totalMeters / completedActivities : 0.0;
      double avgDurationMs = completedActivities > 0 ? totalDurationMs / completedActivities : 0.0;
      // Derived from the distance already summed above rather than read per
      // session: energy is not stored (see `caloriesForDistance`), and the
      // average of `distance * k` is `k * average distance` exactly, so this
      // needs no extra field and no extra read.
      double avgCalories = caloriesForDistance(avgDistanceMeters);
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
          _monthlyRaw = MonthlyStatsRaw(
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

  void _startLeaderboardStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    
    final db = FirebaseFirestore.instance;

    _globalSessionsSub = db.collection('runningSessions').snapshots().listen((sessionsSnap) async {
      if (!mounted) return;

      try {
        final followsSnap = await db.collection('follows').where('followerId', isEqualTo: user.uid).get();
        final List<String> followingIds = followsSnap.docs.map((d) => d.data()['followingId'] as String).toList();

        Map<String, Map<String, int>> cityUserPoints = {};
        Map<String, int> globalUserPoints = {};
        Map<String, DateTime> currentUserCities = {};

        String? myMetroTerritory;
        DateTime? myMetroAt;

        for (var doc in sessionsSnap.docs) {
          final data = doc.data();
          final userId = data['userId'] as String?;
          final points = (data['pointsEarned'] as num?)?.toInt() ?? 0;
          final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

          final rawLocality = (data['startLocality'] as String?)?.trim() ?? '';
          final rawTerritory = (data['territoryCity'] as String?)?.trim() ?? '';
          final rawBroad = (data['territoryBroad'] as String?)?.trim() ?? '';
          
          final city = rawTerritory.isNotEmpty
              ? rawTerritory
              : rawBroad.isNotEmpty
                  ? rawBroad
                  : (rawLocality.isNotEmpty ? rawLocality : 'Unknown');

          if (userId != null && createdAt != null) {
            globalUserPoints[userId] = (globalUserPoints[userId] ?? 0) + points;

            if (city != 'Unknown') {
              cityUserPoints.putIfAbsent(city, () => {});
              cityUserPoints[city]![userId] = (cityUserPoints[city]![userId] ?? 0) + points;

              if (userId == user.uid) {
                if (!currentUserCities.containsKey(city) || createdAt.isAfter(currentUserCities[city]!)) {
                  currentUserCities[city] = createdAt;
                }
                if (rawTerritory.isNotEmpty &&
                    (myMetroAt == null || createdAt.isAfter(myMetroAt))) {
                  myMetroTerritory = rawTerritory;
                  myMetroAt = createdAt;
                }
              }
            }
          }
        }

        var sortedCities = currentUserCities.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        var allUserCities = sortedCities.map((e) => e.key).toList();

        List<LeaderboardPreviewData> previews = [];

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

        final orderedTitles = LeaderboardOrder.defaultOrder(
          allUserCities,
          metroTerritory: myMetroTerritory,
        );
        for (final title in orderedTitles) {
          if (title == LeaderboardOrder.globalTitle) {
            previews.add(await buildCardData(globalUserPoints, title));
          } else {
            final points = cityUserPoints[title];
            if (points != null) previews.add(await buildCardData(points, title));
          }
        }

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

    List<LeaderboardPreviewData> currentPreviews = List.from(_rawLeaderboards);

    if (savedData != null) {
      final List<dynamic> decoded = jsonDecode(savedData);
      List<LeaderboardPreviewData> sortedAndFilteredPreviews = [];

      for (var item in decoded) {
        final String title = item['title'];
        final bool isVisible = (title == LeaderboardOrder.globalTitle) ? true : (item['isVisible'] ?? true);

        if (isVisible) {
          final index = currentPreviews.indexWhere((p) => p.city == title);
          if (index != -1) {
            sortedAndFilteredPreviews.add(currentPreviews[index]);
            currentPreviews.removeAt(index);
          }
        } else {
          currentPreviews.removeWhere((p) => p.city == title);
        }
      }

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

    final staticBadges = await BadgeService().getHomeBadges(user.uid);
    
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
    final runRoute = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(builder: (_) => const RouteLibraryPage()),
    );
    if (runRoute != null && mounted) {
      await _pushRunTracking(plannedRoute: runRoute);
    }
  }

  Future<void> _createRoute() async {
    final runRoute = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(builder: (_) => const RouteCreatePage()),
    );
    if (runRoute != null && mounted) {
      await _pushRunTracking(plannedRoute: runRoute);
    }
  }

  Future<void> _startRunNow() async {
    await _pushRunTracking();
  }

  /// Delegates to the shared launcher in `run_tracking_page.dart` so every
  /// entry point into a run — here, and a route opened from a profile —
  /// reports the outcome identically.
  Future<void> _pushRunTracking({List<LatLng>? plannedRoute}) =>
      pushRunTracking(context, plannedRoute: plannedRoute);

  void _onWatchCommand(WatchCommand command) {
    if (command != WatchCommand.start) return;
    if (!mounted) return;

    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    
    final session = RunSessionController.instance;
    if (session.hasStarted || session.isCountingDown) return;
    _startRunNow();
  }

  void _onWatchImportMessage(String message) {
    if (!mounted) return;
    context.showInformationSnackBar(message);
  }
}