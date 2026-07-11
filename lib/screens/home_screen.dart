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

  // Interroga Firestore per aggregare la distanza e tutte le 6 statistiche degli ultimi 30 giorni
  Future<void> _loadMonthlyDistance() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final db = FirebaseFirestore.instance;

      // 1. Eseguiamo due richieste in parallelo: le sessioni degli ultimi 30gg E le statistiche globali (Record)
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
      
      final results = await Future.wait([
        db.collection('runningSessions')
          .where('userId', isEqualTo: user.uid)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(thirtyDaysAgo))
          .get(),
        db.collection('userStats').doc(user.uid).get(),
      ]);

      final querySnapshot = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final statsDoc = results[1] as DocumentSnapshot<Map<String, dynamic>>;

      // --- ESTRAZIONE RECORD ASSOLUTI DAL NUOVO DOC `userStats` ---
      final globalStats = statsDoc.data() ?? {};
      final bestOverall = globalStats['bestOverall'] ?? {};
      
      final bestDistance = (bestOverall['maxDistanceMeters'] as num?)?.toDouble() ?? 0.0;
      final bestDurationMs = (bestOverall['maxDurationMs'] as num?)?.toInt() ?? 0;
      final bestSpeedKmh = (bestOverall['maxSpeedKmh'] as num?)?.toDouble() ?? 0.0;
      final bestCalories = (bestOverall['maxCaloriesBurned'] as num?)?.toDouble() ?? 0.0;
      final bestLoops = (bestOverall['maxLoopsCompleted'] as num?)?.toInt() ?? 0;

      // --- CALCOLO AGGREGAZIONE ULTIMI 30 GIORNI ---
      double totalMeters = 0;
      double totalCalories = 0;
      int completedActivities = querySnapshot.docs.length;
      int maxDurationMs = 0;
      int totalDurationMs = 0;
      double minPace = double.infinity; 

      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        
        totalMeters += (data['distanceMeters'] as num?)?.toDouble() ?? 0.0;
        totalCalories += (data['caloriesBurned'] as num?)?.toDouble() ?? 0.0;
        
        int duration = (data['durationMs'] as num?)?.toInt() ?? 0;
        totalDurationMs += duration;
        if (duration > maxDurationMs) maxDurationMs = duration;

        double pace = (data['maxPaceMinPerKm'] as num?)?.toDouble() ?? 0.0;
        if (pace > 0 && pace < minPace) minPace = pace;
      }

      // Formattazione Tempo Massimo (30gg)
      String durationStr = '--';
      if (maxDurationMs > 0) {
        Duration d = Duration(milliseconds: maxDurationMs);
        durationStr = d.inHours > 0 ? '${d.inHours}h ${d.inMinutes.remainder(60)}min' : '${d.inMinutes.remainder(60)} min';
      }

      // Formattazione Velocità Massima (30gg)
      String maxSpeedStr = '--';
      double maxSpeedProgress = 0.0;
      if (minPace != double.infinity && minPace > 0) {
        double kmh = 60 / minPace;
        maxSpeedStr = '${kmh.toStringAsFixed(1)} km/h';
        maxSpeedProgress = (kmh / 20.0).clamp(0.0, 1.0); 
      }

      // Calcolo Velocità Media (30gg)
      String avgSpeedStr = '--';
      double avgSpeedProgress = 0.0;
      if (totalDurationMs > 0 && totalMeters > 0) {
        double totalHours = totalDurationMs / 3600000;
        double avgKmh = (totalMeters / 1000) / totalHours;
        avgSpeedStr = '${avgKmh.toStringAsFixed(1)} km/h';
        avgSpeedProgress = (avgKmh / 15.0).clamp(0.0, 1.0); 
      }

      // Costruzione dinamica di TUTTE e 6 le metriche integrando i "Best Overall" dal DB
      final calculatedStats = [
        MonthlyStatData(
          title: 'Max running\nsession time',
          value: durationStr,
          icon: Icons.timer_outlined,
          progress: (maxDurationMs / 7200000).clamp(0.0, 1.0),
          bottomText: bestDurationMs > 0 
              ? 'Best overall: ${Duration(milliseconds: bestDurationMs).inMinutes} min' 
              : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Max speed\nreached',
          value: maxSpeedStr,
          icon: Icons.speed_rounded,
          progress: maxSpeedProgress,
          bottomText: bestSpeedKmh > 0 ? 'Best overall: ${bestSpeedKmh.toStringAsFixed(1)} km/h' : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Average\nspeed',
          value: avgSpeedStr,
          icon: Icons.shutter_speed_rounded,
          progress: avgSpeedProgress,
          bottomText: '-', // O puoi calcolare un all-time average, ma solitamente per l'avg speed non c'è un best overall
        ),
        MonthlyStatData(
          title: 'Total\ndistance',
          value: totalMeters >= 1000 
              ? '${(totalMeters / 1000).toStringAsFixed(1)} km' 
              : '${totalMeters.toStringAsFixed(0)} m',
          icon: Icons.swap_horiz_rounded,
          progress: (totalMeters / 50000).clamp(0.0, 1.0), 
          bottomText: bestDistance > 0 ? 'Best overall: ${(bestDistance/1000).toStringAsFixed(1)} km' : 'No records yet',
        ),
        MonthlyStatData(
          title: 'Completed\nactivities',
          value: '$completedActivities',
          icon: Icons.directions_run_rounded,
          progress: (completedActivities / 15).clamp(0.0, 1.0),
          bottomText: bestLoops > 0 ? 'Max loops in one run: $bestLoops' : '-',
        ),
        MonthlyStatData(
          title: 'Calories',
          value: '${totalCalories.toStringAsFixed(0)} kCal',
          icon: Icons.local_fire_department_rounded,
          progress: (totalCalories / 10000).clamp(0.0, 1.0), 
          bottomText: bestCalories > 0 ? 'Best overall: ${bestCalories.toStringAsFixed(0)} kCal' : 'No records yet',
        ),
      ];

      if (mounted) {
        setState(() {
          _monthlyKm = totalMeters / 1000;
          _monthlyStats = calculatedStats;
          _isLoadingKm = false;
        });
      }
    } catch (e) {
      debugPrint('Errore calcolo statistiche mensili: $e');
      if (mounted) {
        setState(() => _isLoadingKm = false);
      }
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
    _loadMonthlyDistance();
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
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
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
                                          child: Image.network(
                                            _selectedBadge!.imageUrl,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) {
                                              return Container(
                                                color: const Color(0xFFE5E9DF),
                                                alignment: Alignment.center,
                                                child: const Icon(
                                                  Icons.image_not_supported_outlined,
                                                  color: Color(0xFF7A8377),
                                                  size: 34,
                                                ),
                                              );
                                            },
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