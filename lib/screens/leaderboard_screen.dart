import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Modello di supporto per i dati della classifica
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
  const LeaderboardScreen({super.key});

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
      // 1. Aggrega i punti dalle runningSession
      final sessionsSnapshot = await FirebaseFirestore.instance.collection('runningSessions').get();
      
      Map<String, int> userPointsMap = {};
      for (var doc in sessionsSnapshot.docs) {
        final data = doc.data();
        final userId = data['userId'] as String?;
        final points = (data['pointsEarned'] as num?)?.toInt() ?? 0;
        
        if (userId != null) {
          userPointsMap[userId] = (userPointsMap[userId] ?? 0) + points;
        }
      }

      // 2. Ordina gli user per punteggio decrescente
      var sortedUsers = userPointsMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // 3. Recupera i profili degli utenti e crea la classifica
      List<LeaderboardEntry> leaderboard = [];
      int currentRank = 1;
      
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;

      for (var entry in sortedUsers) {
        final userId = entry.key;
        final totalPoints = entry.value;

        // Idealmente, qui potresti fare una query 'in' per ottimizzare, 
        // ma per semplicità recuperiamo i profili uno ad uno
        final profileDoc = await FirebaseFirestore.instance.collection('profiles').doc(userId).get();
        final profileData = profileDoc.data() ?? {};

        final name = profileData['name'] as String? ?? 'Unknown';
        final surname = profileData['surname'] as String? ?? 'User';
        final profileImageUrl = profileData['profileImageUrl'] as String? ?? '';

        final lbEntry = LeaderboardEntry(
          userId: userId,
          totalPoints: totalPoints,
          name: name,
          surname: surname,
          profileImageUrl: profileImageUrl,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5EE), // Sfondo panna
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF425143)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Track', // Come da design Figma
          style: TextStyle(
            color: Color(0xFF4A8C52), // Verde scuro
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4A8C52)))
          : Stack(
              children: [
                Column(
                  children: [
                    // PODIO (Top 3)
                    if (_leaderboard.isNotEmpty) _buildPodiumSection(),
                    
                    // LISTA (Dal 4° in poi)
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 100), // Spazio per la sticky bar
                        itemCount: _leaderboard.length > 3 ? _leaderboard.length - 3 : 0,
                        itemBuilder: (context, index) {
                          final entry = _leaderboard[index + 3]; // Salta i primi 3
                          return _buildListItem(entry);
                        },
                      ),
                    ),
                  ],
                ),
                
                // STICKY BOTTOM BAR (Utente Corrente)
                if (_currentUserEntry != null)
                  Positioned(
                    bottom: 24,
                    left: 20,
                    right: 20,
                    child: _buildCurrentUserStickyBar(_currentUserEntry!),
                  ),
              ],
            ),
    );
  }

  // ── Sezione Podio (Top 3) ──────────────────────────────────────────────────
  Widget _buildPodiumSection() {
    final first = _leaderboard.isNotEmpty ? _leaderboard[0] : null;
    final second = _leaderboard.length > 1 ? _leaderboard[1] : null;
    final third = _leaderboard.length > 2 ? _leaderboard[2] : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // SECONDO POSTO
          Expanded(child: _buildPodiumColumn(second, 2, 120, const Color(0xFFD3E0CA))),
          const SizedBox(width: 8),
          // PRIMO POSTO
          Expanded(child: _buildPodiumColumn(first, 1, 160, const Color(0xFFCAF0B8))),
          const SizedBox(width: 8),
          // TERZO POSTO
          Expanded(child: _buildPodiumColumn(third, 3, 100, const Color(0xFFC0CEC0))),
        ],
      ),
    );
  }

  Widget _buildPodiumColumn(LeaderboardEntry? entry, int rank, double barHeight, Color barColor) {
    if (entry == null) return const SizedBox.shrink();

    // Colori per il bordo dell'avatar in base al rank
    Color borderColor = rank == 1 ? const Color(0xFFF1C40F) : 
                        rank == 2 ? const Color(0xFFBDC3C7) : 
                        const Color(0xFFCD7F32); // Oro, Argento, Bronzo

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: borderColor,
              ),
              child: CircleAvatar(
                radius: rank == 1 ? 36 : 28, // Il primo è più grande
                backgroundColor: Colors.grey.shade300,
                backgroundImage: entry.profileImageUrl.isNotEmpty 
                    ? NetworkImage(entry.profileImageUrl) 
                    : null,
                child: entry.profileImageUrl.isEmpty 
                    ? Icon(Icons.person, color: Colors.grey.shade600) 
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
          '${entry.name} ${entry.surname}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2A3028)),
        ),
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
    );
  }

  // ── Elementi della Lista (Dal 4° in poi) ──────────────────────────────────
  Widget _buildListItem(LeaderboardEntry entry) {
    return Padding(
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
                  '${entry.name} ${entry.surname}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF2A3028)),
                ),
                Text(
                  '${entry.totalPoints} pt',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
          // Icona trend finta (come da mockup Figma)
          Icon(
            entry.rank % 2 == 0 ? Icons.arrow_drop_down : Icons.remove, 
            color: entry.rank % 2 == 0 ? Colors.red : Colors.grey,
            size: 24,
          ),
        ],
      ),
    );
  }

  // ── Sticky Bar Utente Corrente in basso ───────────────────────────────────
  Widget _buildCurrentUserStickyBar(LeaderboardEntry entry) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFD6ECC6), // Verde chiaro traslucido dal design
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
                  '${entry.name} ${entry.surname}',
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