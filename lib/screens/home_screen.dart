import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/home_models.dart';
import '../models/home_badge_ui_model.dart';
import '../services/badge_service.dart';
import '../services/storage_service.dart';
import 'explore_page.dart';
import 'route_create_page.dart';
import 'route_search_page.dart';
import 'run_tracking_page.dart';
import 'temp_profile_page.dart';
import '../widgets/home/badge_progress_section.dart';
import '../widgets/home/leaderboard_preview_card.dart';
import '../widgets/home/start_run_overlay.dart';
import '../widgets/home/monthly_stats_section.dart';
import 'package:cached_network_image/cached_network_image.dart';

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
  int _currentIndex = 1;
  HomeBadgeUiModel? _selectedBadge;

  // Gestione stato distanza e statistiche degli ultimi 30 giorni
  double _monthlyKm = 0.0;
  bool _isLoadingKm = true;
  List<MonthlyStatData> _monthlyStats = []; 

  final BadgeService _badgeService = BadgeService();
  final StorageService _storageService = StorageService();

  late Future<List<HomeBadgeUiModel>> _badgesFuture;

  String _greetingName = '';

  @override
  void initState() {
    super.initState();
    _badgesFuture = _loadBadges();
    _loadNickname();
    _loadMonthlyDistance();
  }

  Future<void> _loadNickname() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(user.uid)
          .get();
      if (!doc.exists) return;

      final data = doc.data();
      final nickname = data?['username'] ?? data?['nickname'] ?? data?['name'];
      if (nickname is String && nickname.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _greetingName = nickname.trim();
        });
      }
    } catch (_) {}
  }

  // Interroga Firestore per calcolare le medie degli allenamenti degli ultimi 30 giorni 
  // e confrontarle con i record globali (best overall) e con il mese precedente (ultimi 60 giorni).
  Future<void> _loadMonthlyDistance() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final db = FirebaseFirestore.instance;

      // Andiamo indietro di 60 giorni per poter confrontare le attività con il mese precedente
      final now = DateTime.now();
      final thirtyDaysAgo = now.subtract(const Duration(days: 30));
      final sixtyDaysAgo = now.subtract(const Duration(days: 60));

      final results = await Future.wait([
        db.collection('runningSessions')
          .where('userId', isEqualTo: user.uid)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(sixtyDaysAgo))
          .get(),
        db.collection('userStats').doc(user.uid).get(),
      ]);

      final querySnapshot = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final statsDoc = results[1] as DocumentSnapshot<Map<String, dynamic>>;

      // Dividiamo i documenti tra gli ultimi 30 giorni e i 30 giorni ancora precedenti
      final currentMonthDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final previousMonthDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        if (createdAt == null) continue;

        if (createdAt.isAfter(thirtyDaysAgo) || createdAt.isAtSameMomentAs(thirtyDaysAgo)) {
          currentMonthDocs.add(doc);
        } else {
          previousMonthDocs.add(doc);
        }
      }

      // --- ESTRAZIONE RECORD ASSOLUTI DAL DOC `userStats` ---
      final globalStats = statsDoc.data() ?? {};
      final bestOverall = globalStats['bestOverall'] ?? {};
      
      final bestDistance = (bestOverall['maxDistanceMeters'] as num?)?.toDouble() ?? 0.0;
      final bestDurationMs = (bestOverall['maxDurationMs'] as num?)?.toInt() ?? 0;
      final bestSpeedKmh = (bestOverall['maxSpeedKmh'] as num?)?.toDouble() ?? 0.0;
      final bestAvgSpeedKmh = (bestOverall['maxAvgSpeedKmh'] as num?)?.toDouble() ?? 0.0;
      final bestCalories = (bestOverall['maxCaloriesBurned'] as num?)?.toDouble() ?? 0.0;

      // --- CALCOLO MEDIE DEGLI ULTIMI 30 GIORNI ---
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

      // Calcolo Valori Medi per Singolo Allenamento
      double avgDistanceMeters = completedActivities > 0 ? totalMeters / completedActivities : 0.0;
      double avgDurationMs = completedActivities > 0 ? totalDurationMs / completedActivities : 0.0;
      double avgCalories = completedActivities > 0 ? totalCalories / completedActivities : 0.0;
      double avgMaxSpeedKmh = completedActivities > 0 ? sumMaxSpeedsKmh / completedActivities : 0.0;

      // Velocità Media Complessiva dei 30 giorni
      double avgSpeed30d = 0.0;
      if (totalDurationMs > 0 && totalMeters > 0) {
        double totalHours = totalDurationMs / 3600000;
        avgSpeed30d = (totalMeters / 1000) / totalHours;
      }

      // --- FORMATTAZIONE E CALCOLO PROGRESSI ---
      
      // 1. Avg Session Time
      String avgDurationStr = '--';
      if (avgDurationMs > 0) {
        Duration d = Duration(milliseconds: avgDurationMs.toInt());
        avgDurationStr = d.inHours > 0 ? '${d.inHours}h ${d.inMinutes.remainder(60)}m' : '${d.inMinutes.remainder(60)} min';
      }

      // 2. Avg Max Speed
      String avgMaxSpeedStr = avgMaxSpeedKmh > 0 ? '${avgMaxSpeedKmh.toStringAsFixed(1)} km/h' : '--';

      // 3. Avg Speed
      String avgSpeedStr = avgSpeed30d > 0 ? '${avgSpeed30d.toStringAsFixed(1)} km/h' : '--';

      // 4. Avg Distance
      String avgDistanceStr = avgDistanceMeters >= 1000 ? '${(avgDistanceMeters / 1000).toStringAsFixed(1)} km' : '${avgDistanceMeters.toStringAsFixed(0)} m';

      // 5. Avg Calories
      String avgCaloriesStr = avgCalories > 0 ? '${avgCalories.toStringAsFixed(0)} kCal' : '--';

      // Progresso Activities (confronto mese corrente vs precedente)
      double activitiesProgress = 0.0;
      if (previousCompletedActivities > 0) {
        activitiesProgress = (completedActivities / previousCompletedActivities).clamp(0.0, 1.0);
      } else if (completedActivities > 0) {
        activitiesProgress = 1.0; // Se prima era 0 e ora > 0, 100% di progresso
      }

      // Costruzione statistiche UI
      final calculatedStats = [
        MonthlyStatData(
          title: 'Average\nsession time',
          value: avgDurationStr,
          icon: Icons.timer_outlined,
          progress: bestDurationMs > 0 ? (avgDurationMs / bestDurationMs).clamp(0.0, 1.0) : 0.0,
          bottomText: bestDurationMs > 0 ? 'Best overall: ${Duration(milliseconds: bestDurationMs).inMinutes} min' : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Average max\nspeed',
          value: avgMaxSpeedStr,
          icon: Icons.speed_rounded,
          progress: bestSpeedKmh > 0 ? (avgMaxSpeedKmh / bestSpeedKmh).clamp(0.0, 1.0) : 0.0,
          bottomText: bestSpeedKmh > 0 ? 'Best overall: ${bestSpeedKmh.toStringAsFixed(1)} km/h' : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Average\nspeed',
          value: avgSpeedStr,
          icon: Icons.shutter_speed_rounded,
          progress: bestAvgSpeedKmh > 0 ? (avgSpeed30d / bestAvgSpeedKmh).clamp(0.0, 1.0) : 0.0,
          bottomText: bestAvgSpeedKmh > 0 ? 'Best overall: ${bestAvgSpeedKmh.toStringAsFixed(1)} km/h' : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Average\ndistance',
          value: avgDistanceStr,
          icon: Icons.swap_horiz_rounded,
          progress: bestDistance > 0 ? (avgDistanceMeters / bestDistance).clamp(0.0, 1.0) : 0.0,
          bottomText: bestDistance > 0 ? 'Best overall: ${(bestDistance/1000).toStringAsFixed(1)} km' : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Completed\nactivities',
          value: '$completedActivities',
          icon: Icons.directions_run_rounded,
          progress: activitiesProgress,
          bottomText: 'Previous 30 days: $previousCompletedActivities',
        ),
        MonthlyStatData(
          title: 'Average\ncalories',
          value: avgCaloriesStr,
          icon: Icons.local_fire_department_rounded,
          progress: bestCalories > 0 ? (avgCalories / bestCalories).clamp(0.0, 1.0) : 0.0,
          bottomText: bestCalories > 0 ? 'Best overall: ${bestCalories.toStringAsFixed(0)} kCal' : 'No records yet',
        ),
      ];

      if (mounted) {
        setState(() {
          // Manteniamo la somma totale della distanza per il testo "X km ran in the last 30 days" in cima alla Home
          _monthlyKm = totalMeters / 1000;
          _monthlyStats = calculatedStats;
          _isLoadingKm = false;
        });
      }
    } catch (e) {
      debugPrint('Errore calcolo statistiche: $e');
      if (mounted) setState(() => _isLoadingKm = false);
    }
  }

  Future<List<HomeBadgeUiModel>> _loadBadges() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return [];

      final badges = await _badgeService.getDefaultBadges();
      final result = <HomeBadgeUiModel>[];
      for (final badge in badges) {
        String imageUrl = '';
        double progress = 0.0;
        bool unlocked = false;

        try {
          imageUrl = await _storageService.getDownloadUrl(badge.imagePath);
        } catch (e) {
          debugPrint('STORAGE BADGE ERROR ${badge.imagePath}: $e');
        }

        try {
          final progressDoc = await FirebaseFirestore.instance
              .collection('profiles')
              .doc(user.uid)
              .collection('badge_progress')
              .doc(badge.id)
              .get();
          if (progressDoc.exists) {
            final data = progressDoc.data();
            final rawProgress = (data?['progress'] as num?)?.toDouble() ?? 0.0;

            progress = rawProgress > 1.0
                ? (rawProgress / 100).clamp(0.0, 1.0)
                : rawProgress.clamp(0.0, 1.0);
            unlocked = data?['unlocked'] == true || progress >= 1.0;
          }
        } catch (e) {
          debugPrint('BADGE PROGRESS ERROR ${badge.id}: $e');
        }

        result.add(
          HomeBadgeUiModel(
            badgeId: badge.id,
            title: badge.title,
            description: badge.description,
            imageUrl: imageUrl,
            progress: progress,
            unlocked: unlocked,
          ),
        );
      }

      return result;
    } catch (e) {
      debugPrint('FIRESTORE BADGES ERROR: $e');
      rethrow;
    }
  }

  final leaderboardData = const LeaderboardPreviewData(
    position: 300,
    points: 10,
    variation: null,
    avatarAssets: [],
  );

  void _openLeaderboard() {}
  void _openNotifications() {}
  void _openHistory() {}

  void _searchRoute() {
    setState(() => _showRunOverlay = false);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RouteSearchPage()),
    );
  }

  void _createRoute() {
    setState(() => _showRunOverlay = false);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RouteCreatePage()),
    );
  }

  Future<void> _startRunNow() async {
    setState(() => _showRunOverlay = false);
    final summary = await Navigator.of(context).push<RunSummary>(
      MaterialPageRoute(builder: (_) => const RunTrackingPage()),
    );
    if (summary == null || !mounted) return;

    if (!summary.saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run discarded')),
      );
      return;
    }

    final km = (summary.distanceMeters / 1000).toStringAsFixed(2);
    final minutes = summary.elapsed.inMinutes;
    final loopsText = summary.loopsCompleted > 0
        ? ', ${summary.loopsCompleted} loop${summary.loopsCompleted == 1 ? '' : 's'} closed'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Run saved — $km km in $minutes min$loopsText')),
    );

    if (mounted) {
      _loadMonthlyDistance();
    }
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
      backgroundColor: const Color(0xFFF3F5EE),
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
                        onRefresh: _loadMonthlyDistance,
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 85),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Spacer(),
                                  IconButton(
                                    onPressed: _openNotifications,
                                    icon: const Icon(
                                      Icons.notifications_none_rounded,
                                      color: Color(0xFF495348),
                                      size: 28,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: _openHistory,
                                    icon: const Icon(
                                      Icons.history_rounded,
                                      color: Color(0xFF495348),
                                      size: 28,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
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
                                        ? '-- km' 
                                        : '${_monthlyKm.toStringAsFixed(1)} km',
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
                                    'Leaderboard preview',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF394137),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              LeaderboardPreviewCard(
                                data: leaderboardData,
                                onTap: _openLeaderboard,
                              ),
                              const SizedBox(height: 28),
                              FutureBuilder<List<HomeBadgeUiModel>>(
                                future: _badgesFuture,
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return const Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(24),
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }

                                  if (snapshot.hasError) {
                                    return Text(
                                      'Errore nel caricamento badge: ${snapshot.error}',
                                      style: const TextStyle(color: Colors.red),
                                    );
                                  }

                                  final badges = snapshot.data ?? [];

                                  if (badges.isEmpty) {
                                    return const Text('Nessun badge disponibile');
                                  }

                                  return BadgeProgressSection(
                                    badges: badges,
                                    onBadgeTap: _openBadgePopup,
                                  );
                                },
                              ),
                              const SizedBox(height: 28),
                              MonthlyStatsSection(stats: _monthlyStats),
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
      bottomNavigationBar: NavigationBar(
        height: 82,
        backgroundColor: const Color(0xFFECEFE6),
        selectedIndex: _currentIndex,
        indicatorColor: const Color(0xFFCFE8BD),
        onDestinationSelected: (index) {
          if (index == 0) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ExplorePage()),
            );
            return;
          }
          if (index == 2) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TempProfilePage()),
            );
            return;
          }
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Areas',
          ),
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}