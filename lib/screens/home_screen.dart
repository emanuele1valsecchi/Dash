import 'package:flutter/material.dart';
import '../models/home_models.dart';
import '../widgets/home/badge_progress_section.dart';
import '../widgets/home/leaderboard_preview_card.dart';
import '../widgets/home/start_run_overlay.dart';
import '../widgets/home/weekly_stats_section.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showRunOverlay = false;
  int _currentIndex = 1;

  final leaderboardData = const LeaderboardPreviewData(
    position: 300,
    points: 10,
    variation: null,
    avatarAssets: [
      'assets/images/avatar_1.png',
      'assets/images/avatar_2.png',
      'assets/images/avatar_3.png',
      'assets/images/avatar_4.png',
      'assets/images/avatar_5.png',
    ],
  );

  final badgeData = const [
    BadgeProgressData(
      title: 'Rookie',
      imageAsset: 'assets/images/badge_1.png',
      progress: 0.08,
    ),
    BadgeProgressData(
      title: 'Warming up',
      imageAsset: 'assets/images/badge_2.png',
      progress: 0.22,
    ),
    BadgeProgressData(
      title: 'Traveler',
      imageAsset: 'assets/images/badge_3.png',
      progress: 0.35,
    ),
    BadgeProgressData(
      title: 'Explorer',
      imageAsset: 'assets/images/badge_4.png',
      progress: 0.48,
    ),
  ];

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

  void _openLeaderboard() {
    // TODO: Navigator.push(... leaderboard screen)
  }

  void _openNotifications() {
    // TODO
  }

  void _openHistory() {
    // TODO
  }

  void _searchRoute() {
    // TODO
  }

  void _createRoute() {
    // TODO
  }

  void _startRunNow() {
    // TODO
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
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
                        const Text(
                          'Hi name!',
                          style: TextStyle(
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
                        BadgeProgressSection(badges: badgeData),
                        const SizedBox(height: 28),
                        WeeklyStatsSection(stats: weeklyStats),
                      ],
                    ),
                  ),
                ),
              ],
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
          setState(() => _currentIndex = index);
          // TODO: navigation
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
