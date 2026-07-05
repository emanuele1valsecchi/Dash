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
import 'temp_profile_page.dart';
import '../widgets/home/badge_progress_section.dart';
import '../widgets/home/leaderboard_preview_card.dart';
import '../widgets/home/start_run_overlay.dart';
import '../widgets/home/weekly_stats_section.dart';

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

  final BadgeService _badgeService = BadgeService();
  final StorageService _storageService = StorageService();

  late Future<List<HomeBadgeUiModel>> _badgesFuture;

  String _greetingName = '';

  @override
  void initState() {
    super.initState();
    _badgesFuture = _loadBadges();
    _loadNickname();
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
      final nickname =
          data?['username'] ??
          data?['nickname'] ??
          data?['name'];

      if (nickname is String && nickname.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _greetingName = nickname.trim();
        });
      }
    } catch (_) {}
  }

  Future<List<HomeBadgeUiModel>> _loadBadges() async {
    final badges = await _badgeService.getDefaultBadges();
    final result = <HomeBadgeUiModel>[];

    for (final badge in badges) {
      final imageUrl = await _storageService.getDownloadUrl(badge.imagePath);

      result.add(
        HomeBadgeUiModel(
          title: badge.title,
          imageUrl: imageUrl,
          progress: 0.0,
        ),
      );
    }

    return result;
  }

  final leaderboardData = const LeaderboardPreviewData(
    position: 300,
    points: 10,
    variation: null,
    avatarAssets: [],
  );

  final weeklyStats = const [
    WeeklyStatData(
      title: 'Max running\nsession time',
      value: '--',
      icon: Icons.timer_outlined,
      progress: 0.30,
    ),
    WeeklyStatData(
      title: 'Total\ndistance',
      value: '--',
      icon: Icons.swap_horiz_rounded,
      progress: 0.42,
    ),
    WeeklyStatData(
      title: 'Routes\ncompleted',
      value: '--',
      icon: Icons.directions_run_rounded,
      progress: 0.18,
    ),
  ];

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

  void _startRunNow() {}

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
                              children: const [
                                Text(
                                  '12.5 km',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1F3020),
                                  ),
                                ),
                                SizedBox(width: 10),
                                Padding(
                                  padding: EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    'already ran this week',
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

                                return BadgeProgressSection(badges: badges);
                              },
                            ),
                            const SizedBox(height: 28),
                            WeeklyStatsSection(stats: weeklyStats),
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