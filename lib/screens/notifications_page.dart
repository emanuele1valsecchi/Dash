import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import '../widgets/units_scope.dart';
import 'leaderboard_page.dart';
//import 'home_screen.dart';
import 'explore_page.dart';

// ==========================================
// MODELLI DATI
// ==========================================
enum NotificationType {
  newFollower,         // Nuovo follower
  newRoutePublished,   // Nuovo percorso pubblicato da seguito
  leaderboardOvertake, // Sorpasso / cambio posizione
  leaderboardCityEntry,// Ingresso nella leaderboard di una città
  leaderboardGlobalEntry, // Ingresso nella leaderboard globale
  areaStolen,          // Qualcuno ha sottratto la tua area
  routeSaved,          // Qualcuno ha salvato il tuo percorso
  routeRunFaster,      // Qualcuno ha corso più velocemente il tuo percorso
  badgeUnlocked,       // Sblocco di un nuovo badge
}

class NotificationItem {
  final String id;
  final NotificationType type;
  final String boldText;    // Es: L'utente che ha compiuto l'azione
  final String regularText; // L'azione ("ha salvato il tuo percorso")
  final DateTime createdAt;
  final bool isRead;
  final String? imageUrl;   // Avatar utente
  final String? routeId;    // Payload extra se clicchi sulla notifica
  final String? actorId;    // Chi ha causato la notifica (utile per follow back)
  final String? cityName;   // Payload extra per la leaderboard cittadina
  final String? sessionId;  // Payload extra per l'area rubata

  NotificationItem({
    required this.id,
    required this.type,
    required this.boldText,
    required this.regularText,
    required this.createdAt,
    this.isRead = false,
    this.imageUrl,
    this.routeId,
    this.actorId,
    this.cityName,
    this.sessionId,
  });

  // Metodo per convertire un documento Firestore in un NotificationItem
  factory NotificationItem.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    
    // Converti la stringa del DB nell'enum corretto (con un fallback di sicurezza)
    NotificationType type = NotificationType.values.firstWhere(
      (e) => e.name == data['type'],
      orElse: () => NotificationType.newFollower,
    );

    return NotificationItem(
      id: doc.id,
      type: type,
      boldText: data['actorName'] ?? '',
      regularText: data['message'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRead: data['isRead'] ?? false,
      imageUrl: data['actorImageUrl'],
      routeId: data['routeId'],
      actorId: data['actorId'],
      cityName: data['cityName'],
      sessionId: data['sessionId'],
    );
  }
}

// ==========================================
// SCHERMATA NOTIFICHE
// ==========================================
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final String _currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Questa funzione marca una notifica come letta
  Future<void> _markAsRead(String notificationId) async {
    try {
      await _db.collection('notifications').doc(notificationId).update({
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Errore durante la marcatura come letta: $e');
    }
  }

  // Gestione rudimentale del follow-back
  Future<void> _handleFollowBack(String targetUserId) async {
    if (_currentUserId.isEmpty) return;
    
    final followId = '${_currentUserId}_$targetUserId';
    final followRef = _db.collection('follows').doc(followId);
    final currentUserRef = _db.collection('profiles').doc(_currentUserId);
    final targetUserRef = _db.collection('profiles').doc(targetUserId);

    final batch = _db.batch();
    
    batch.set(followRef, {
      'followerId': _currentUserId,
      'followingId': targetUserId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(currentUserRef, {'followingCount': FieldValue.increment(1)});
    batch.update(targetUserRef, {'followersCount': FieldValue.increment(1)});

    try {
      await batch.commit();
      if (mounted) {
        context.showSuccessSnackBar("You follow this user to");
      }
    } catch (e) {
      debugPrint("Errore follow back: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F0),
      appBar: DashNavigationTopBar(
        title: "Notification"
      ),
      body: _currentUserId.isEmpty 
          ? const Center(child: Text("Non sei loggato."))
          : StreamBuilder<QuerySnapshot>(
              stream: _db
                  .collection('notifications')
                  .where('userId', isEqualTo: _currentUserId)
                  .orderBy('createdAt', descending: true)
                  .limit(50)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Errore: ${snapshot.error}'));
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFF4A8C52)));
                }

                final docs = snapshot.data?.docs ?? [];
                
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'There\'s nothing new',
                      style: TextStyle(color: Color(0xFF8A9389), fontSize: 16),
                    )
                  );
                }

                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    thickness: 1,
                    color: Colors.black.withValues(alpha: 0.06),
                  ),
                  itemBuilder: (context, index) {
                    final item = NotificationItem.fromFirestore(docs[index]);
                    return _buildNotificationTile(item);
                  },
                );
              },
            ),
    );
  }

  Widget _buildNotificationTile(NotificationItem item) {
    // The date half stays locale-formatted; only the clock half follows the
    // units setting, which `DateFormat`'s own `jm` pattern could not do —
    // it reads the device locale, not the user's choice.
    final dateStr = '${DateFormat("d MMMM yyyy").format(item.createdAt)}'
        ' - ${Units.of(context).time(item.createdAt)}';

    return InkWell(
      onTap: () {
        if (!item.isRead) {
          _markAsRead(item.id);
        }
        
        // ── GESTIONE NAVIGAZIONE IN BASE AL TIPO ──
        switch (item.type) {
          case NotificationType.newFollower:
            if (item.actorId != null) {
              // Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserProfileScreen(userId: item.actorId!)));
            }
            break;

          case NotificationType.routeSaved:
          case NotificationType.newRoutePublished:
          case NotificationType.routeRunFaster:
            if (item.routeId != null) {
              // Navigator.of(context).push(MaterialPageRoute(builder: (_) => RouteDetailsScreen(routeId: item.routeId!)));
            }
            break;

          case NotificationType.areaStolen:
            if (item.sessionId != null) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ExplorePage(targetSessionId: item.sessionId),
                ),
              );
            }
            break;

          case NotificationType.leaderboardCityEntry:
            if (item.cityName != null) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LeaderboardScreen(cityFilter: item.cityName!),
                ),
              );
            }
            break;

          case NotificationType.leaderboardGlobalEntry:
          case NotificationType.leaderboardOvertake:
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const LeaderboardScreen(cityFilter: 'Global Leaderboard'), 
              ),
            );
            break;

          case NotificationType.badgeUnlocked:
            // Non navighiamo da nessuna parte per ora, la segniamo solo come letta
            break;
        }
      },
      child: Container(
        color: item.isRead ? Colors.transparent : const Color(0xFFCAF0B8).withValues(alpha: 0.15),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildLeadingIcon(item),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF1E241D),
                        height: 1.3,
                      ),
                      children: [
                        if (item.boldText.isNotEmpty)
                          TextSpan(
                            text: item.boldText,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        TextSpan(
                          text: item.regularText.startsWith(' ') 
                              ? item.regularText 
                              : ' ${item.regularText}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    dateStr,
                    style: TextStyle(
                      fontSize: 13,
                      color: item.isRead ? const Color(0xFF8A9389) : const Color(0xFF4A8C52),
                      fontWeight: item.isRead ? FontWeight.normal : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildTrailingWidget(item),
          ],
        ),
      ),
    );
  }

  Widget _buildLeadingIcon(NotificationItem item) {
    Widget innerIcon = const SizedBox(); // Fallback sicuro

    switch (item.type) {
      case NotificationType.newFollower:
        if (item.imageUrl != null && item.imageUrl!.isNotEmpty) {
          return CircleAvatar(
            radius: 24,
            backgroundColor: Colors.grey.shade300,
            backgroundImage: NetworkImage(item.imageUrl!),
          );
        }
        innerIcon = const Icon(Icons.person_add_alt_1_rounded, color: Colors.white, size: 22);
        break;
      
      case NotificationType.newRoutePublished:
      case NotificationType.routeSaved:
      case NotificationType.routeRunFaster:
        if (item.imageUrl != null && item.imageUrl!.isNotEmpty) {
          return CircleAvatar(
            radius: 24,
            backgroundColor: Colors.grey.shade300,
            backgroundImage: NetworkImage(item.imageUrl!),
          );
        }
        innerIcon = const Icon(Icons.map_rounded, color: Colors.white, size: 22);
        break;

      case NotificationType.leaderboardOvertake:
      case NotificationType.leaderboardCityEntry:
      case NotificationType.leaderboardGlobalEntry: 
        innerIcon = const Icon(Icons.bar_chart_rounded, color: Colors.white, size: 24);
        break;

      case NotificationType.areaStolen:
        innerIcon = const Icon(Icons.share_location_rounded, color: Colors.white, size: 24);
        break;

      case NotificationType.badgeUnlocked: // ECCO DOVE ANDAVA MESSO!
        innerIcon = const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 24);
        break;
    }

    return CircleAvatar(
      radius: 24,
      backgroundColor: const Color(0xFF5C6B59),
      child: innerIcon,
    );
  }

  Widget _buildTrailingWidget(NotificationItem item) {
    if (item.type == NotificationType.newFollower && item.actorId != null) {
      return GestureDetector(
        onTap: () => _handleFollowBack(item.actorId!),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFCAF0B8),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            'Follow back',
            style: TextStyle(
              color: Color(0xFF2E4029),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    return const Icon(
      Icons.chevron_right_rounded,
      color: Color(0xFF8A9389),
      size: 24,
    );
  }
}