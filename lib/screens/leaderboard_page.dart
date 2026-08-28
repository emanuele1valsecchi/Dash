import 'package:dash/screens/public_profile_page.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_symbols_icons/symbols.dart';

class LeaderboardEntry {
  final String userId;
  final int totalPoints;
  final String name;
  final String surname;
  final String profileImageUrl;
  final int rank;

  LeaderboardEntry({
    required this.userId,
    required this.totalPoints,
    required this.name,
    required this.surname,
    required this.profileImageUrl,
    required this.rank,
  });
}

class LeaderboardScreen extends StatefulWidget {
  final String cityFilter; // Città specifica o 'Global Leaderboard'

  const LeaderboardScreen({
    super.key,
    required this.cityFilter,
  });

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  bool _isLoading = true;
  List<LeaderboardEntry> _leaderboard = [];
  LeaderboardEntry? _currentUserEntry;

  @override
  void initState() {
    super.initState();
    _fetchLeaderboardData();
  }

  Future<void> _fetchLeaderboardData() async {
    try {
      final sessionsSnapshot = await FirebaseFirestore.instance.collection('runningSessions').get();
      
      Map<String, int> userPointsMap = {};
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final isGlobal = widget.cityFilter == 'Global Leaderboard';

      for (var doc in sessionsSnapshot.docs) {
        final data = doc.data();
        final userId = data['userId'] as String?;
        final points = (data['pointsEarned'] as num?)?.toInt() ?? 0;
        final rawLocality = (data['startLocality'] as String?)?.trim() ?? '';
        final rawTerritory = (data['territoryCity'] as String?)?.trim() ?? '';
        final city = rawLocality.isNotEmpty ? rawLocality : (rawTerritory.isNotEmpty ? rawTerritory : 'Unknown');
        
        if (userId != null) {
          // Se non è globale, saltiamo tutte le sessioni non appartenenti a questa città
          if (!isGlobal && city != widget.cityFilter) continue;

          userPointsMap[userId] = (userPointsMap[userId] ?? 0) + points;
        }
      }

      var sortedUsers = userPointsMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      List<LeaderboardEntry> leaderboard = [];
      int currentRank = 1;

      for (var entry in sortedUsers) {
        final userId = entry.key;
        final totalPoints = entry.value;

        final profileDoc = await FirebaseFirestore.instance.collection('profiles').doc(userId).get();
        final profileData = profileDoc.data() ?? {};

        final name = profileData['name'] as String? ?? 'Unknown';
        final surname = profileData['surname'] as String? ?? '';

        final lbEntry = LeaderboardEntry(
          userId: userId,
          totalPoints: totalPoints,
          name: name,
          surname: surname,
          profileImageUrl: profileData['profileImageUrl'] as String? ?? '',
          rank: currentRank,
        );

        leaderboard.add(lbEntry);

        if (userId == currentUserId) {
          _currentUserEntry = lbEntry;
        }
        currentRank++;
      }

      if (mounted) {
        setState(() {
          _leaderboard = leaderboard;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Errore nel caricamento della leaderboard: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatName(String name, String surname) {
    final fullName = '$name $surname'.trim();
    if (fullName.isEmpty) return 'Unknown User';
    
    return fullName.split(' ').map((word) {
      if (word.isEmpty) return '';
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final isGlobal = widget.cityFilter == 'Global Leaderboard';

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE),
      appBar: DashNavigationTopBar(
        title: isGlobal ? "Global Leaderboard" : "${widget.cityFilter} Leaderboard",
        actions: [
          if( !isGlobal )
            IconButton(
              icon: Icon(
                Symbols.public_rounded, 
                color: Theme.of(context).colorScheme.outline
              ),
              tooltip: 'Global Leaderboard',
              onPressed: () {
                // Substitute current page with the global leaderboard
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => const LeaderboardScreen(cityFilter: 'Global Leaderboard'),
                  ),
                );
              },
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4A8C52)))
          : SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      if (_leaderboard.isNotEmpty) _buildPodiumSection(),
                      
                      // --- LINETTA DIVISORIA DECORATIVA ---
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // ------------------------------------
                      
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 100),
                          itemCount: _leaderboard.length > 3 ? _leaderboard.length - 3 : 0,
                          itemBuilder: (context, index) {
                            final entry = _leaderboard[index + 3];
                            return _buildListItem(entry);
                          },
                        ),
                      ),
                    ],
                  ),
                  
                  if (_currentUserEntry != null)
                    Positioned(
                      bottom: 24,
                      left: 20,
                      right: 20,
                      child: _buildCurrentUserStickyBar(_currentUserEntry!),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildPodiumSection() {
    final first = _leaderboard.isNotEmpty ? _leaderboard[0] : null;
    final second = _leaderboard.length > 1 ? _leaderboard[1] : null;
    final third = _leaderboard.length > 2 ? _leaderboard[2] : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: _buildPodiumColumn(second, 2, 120, const Color(0xFFD3E0CA))),
          const SizedBox(width: 8),
          Expanded(child: _buildPodiumColumn(first, 1, 160, const Color(0xFFCAF0B8))),
          const SizedBox(width: 8),
          Expanded(child: _buildPodiumColumn(third, 3, 100, const Color(0xFFC0CEC0))),
        ],
      ),
    );
  }

  Widget _buildPodiumColumn(LeaderboardEntry? entry, int rank, double barHeight, Color barColor) {
    if (entry == null) return const SizedBox.shrink();

    Color borderColor = rank == 1 ? const Color(0xFFF1C40F) : 
                        rank == 2 ? const Color(0xFFBDC3C7) : 
                        const Color(0xFFCD7F32);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (context) => PublicProfilePage(userId: entry.userId,)
          ),
        );
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                padding: EdgeInsets.all(rank == 1 ? 4 : 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: borderColor,
                ),
                child: CircleAvatar(
                  radius: rank == 1 ? 36 : 28,
                  backgroundColor: Colors.grey.shade300,
                  backgroundImage: entry.profileImageUrl.isNotEmpty 
                      ? NetworkImage(entry.profileImageUrl) 
                      : null,
                  child: entry.profileImageUrl.isEmpty 
                      ? Icon(Icons.person, color: Colors.grey.shade600, size: rank == 1 ? 36 : 28) 
                      : null,
                ),
              ),
              Positioned(
                bottom: -10,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: Colors.white,
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: borderColor,
                    child: Text(
                      '$rank',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _formatName(entry.name, entry.surname),
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2A3028), height: 1.1),
          ),
          const SizedBox(height: 2),
          Text(
            '${entry.totalPoints} pt',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Container(
            height: barHeight,
            width: double.infinity,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListItem(LeaderboardEntry entry) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (context) => PublicProfilePage(userId: entry.userId,)
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '#${entry.rank}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 14),
              ),
            ),
            CircleAvatar(
              radius: 20,
              backgroundColor: Colors.grey.shade300,
              backgroundImage: entry.profileImageUrl.isNotEmpty 
                  ? NetworkImage(entry.profileImageUrl) 
                  : null,
              child: entry.profileImageUrl.isEmpty 
                  ? Icon(Icons.person, color: Colors.grey.shade600) 
                  : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatName(entry.name, entry.surname),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF2A3028)),
                  ),
                  Text(
                    '${entry.totalPoints} pt',
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Icon(
              entry.rank % 2 == 0 ? Icons.arrow_drop_down : Icons.remove, 
              color: entry.rank % 2 == 0 ? Colors.red : Colors.grey,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentUserStickyBar(LeaderboardEntry entry) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFD6ECC6),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${entry.rank}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2A3028), fontSize: 15),
            ),
          ),
          CircleAvatar(
            radius: 22,
            backgroundColor: Colors.grey.shade300,
            backgroundImage: entry.profileImageUrl.isNotEmpty 
                ? NetworkImage(entry.profileImageUrl) 
                : null,
            child: entry.profileImageUrl.isEmpty 
                ? Icon(Icons.person, color: Colors.grey.shade600) 
                : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatName(entry.name, entry.surname),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF2A3028)),
                ),
                Text(
                  '${entry.totalPoints} pt',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF4A8C52), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const Icon(Icons.remove, color: Colors.grey),
        ],
      ),
    );
  }
}