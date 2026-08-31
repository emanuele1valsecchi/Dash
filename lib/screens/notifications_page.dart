import 'dart:async';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:dash/screens/public_profile_page.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/screens/saved_route_detail_page.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:dash/screens/run_session_detail_page.dart';

import '../widgets/units_scope.dart';
import 'leaderboard_page.dart';
import 'explore_page.dart';
import 'badge_page.dart';

// ==========================================
// data model for notifications
// ==========================================
enum NotificationType {
  newFollower,
  newRoutePublished,
  leaderboardOvertake,
  leaderboardCityEntry,
  leaderboardGlobalEntry,
  areaStolen,
  routeSaved,
  routeRunFaster,
  badgeUnlocked,
}

class NotificationItem {
  final String id;
  final NotificationType type;
  final String boldText;
  final String regularText;
  final DateTime createdAt;
  final bool isRead;
  final String? imageUrl;
  final String? routeId;
  final String? actorId;
  final String? cityName;
  final String? sessionId;

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

  factory NotificationItem.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};

    final type = NotificationType.values.firstWhere(
      (e) => e.name == data['type'],
      orElse: () => NotificationType.newFollower,
    );

    final rawActorName = (data['actorName'] as String? ?? '').trim();
    final boldText = rawActorName.toLowerCase() == 'system' ? '' : rawActorName;

    return NotificationItem(
      id: doc.id,
      type: type,
      boldText: boldText,
      regularText: data['message'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRead: data['isRead'] as bool? ?? false,
      imageUrl: data['actorImageUrl'] as String?,
      routeId: data['routeId'] as String?,
      actorId: data['actorId'] as String?,
      cityName: data['cityName'] as String?,
      sessionId: data['sessionId'] as String?,
    );
  }
}

// ==========================================
// Notification Screen
// ==========================================
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final String _currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> _markAsRead(String notificationId) async {
    try {
      await _db.collection('notifications').doc(notificationId).update({
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Error marking notification as read: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F0),
      appBar: DashNavigationTopBar(title: 'Notifications'),
      body: _currentUserId.isEmpty
          ? const Center(child: Text('You are not logged in.'))
          : StreamBuilder<QuerySnapshot>(
              stream: _db
                  .collection('notifications')
                  .where('userId', isEqualTo: _currentUserId)
                  .orderBy('createdAt', descending: true)
                  .limit(50)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF4A8C52)),
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'There\'s nothing new',
                      style: TextStyle(color: Color(0xFF8A9389), fontSize: 16),
                    ),
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
    final dateStr =
        '${DateFormat('d MMMM yyyy').format(item.createdAt)}'
        ' - ${Units.of(context).time(item.createdAt)}';

    final messageText = item.boldText.isEmpty
        ? item.regularText.trimLeft()
        : item.regularText.startsWith(' ')
        ? item.regularText
        : ' ${item.regularText}';

    return InkWell(
      onTap: () async {
        if (!item.isRead) {
          _markAsRead(item.id);
        }

        switch (item.type) {
          case NotificationType.newFollower:
            final actorId = item.actorId;
            if (actorId != null && actorId.isNotEmpty && actorId != 'system') {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PublicProfilePage(userId: actorId),
                ),
              );
            }
            break;

          case NotificationType.routeSaved:
          case NotificationType.newRoutePublished:
          case NotificationType.routeRunFaster:
            
            // CASE 1: RUNNING SESSION 
            if (item.sessionId != null && item.sessionId!.isNotEmpty) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RunSessionDetailPage(
                    sessionId: item.sessionId!,
                    userId: item.actorId ?? '', 
                  ),
                ),
              );
            } 
            // CASE 2: IT'S A SAVED/PLANNED ROUTE
            else if (item.routeId != null && item.routeId!.isNotEmpty) {
              try {
                final routeDoc = await FirebaseFirestore.instance
                    .collection('routes')
                    .doc(item.routeId)
                    .get();

                if (routeDoc.exists && mounted) {
                  final data = routeDoc.data() ?? {};
                  final dbName = data['name'] as String? ?? 'Shared Route';

                  final route = SavedRoute.fromSharedRoute(
                    routeDoc,
                    name: dbName,
                  );

                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SavedRouteDetailPage(
                        route: route,
                        source: RouteSource.owned,
                        authorName: item.boldText.isNotEmpty ? item.boldText : null,
                      ),
                    ),
                  );
                }
              } catch (e) {
                debugPrint('Errore nel caricamento della route: $e');
              }
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
            final currentUser = FirebaseAuth.instance.currentUser;
            if (currentUser != null) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BadgePage(userId: currentUser.uid),
                ),
              );
            }
            break;
        }
      },
      child: Container(
        color: item.isRead
            ? Colors.transparent
            : const Color(0xFFCAF0B8).withValues(alpha: 0.15),
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
                        TextSpan(text: messageText),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    dateStr,
                    style: TextStyle(
                      fontSize: 13,
                      color: item.isRead
                          ? const Color(0xFF8A9389)
                          : const Color(0xFF4A8C52),
                      fontWeight: item.isRead
                          ? FontWeight.normal
                          : FontWeight.w600,
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
    Widget innerIcon = const SizedBox();

    switch (item.type) {
      case NotificationType.newFollower:
        if (item.imageUrl != null && item.imageUrl!.isNotEmpty) {
          return CircleAvatar(
            radius: 24,
            backgroundColor: Colors.grey.shade300,
            backgroundImage: NetworkImage(item.imageUrl!),
          );
        }
        innerIcon = const Icon(
          Icons.person_add_alt_1_rounded,
          color: Colors.white,
          size: 22,
        );
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
        innerIcon = const Icon(
          Icons.map_rounded,
          color: Colors.white,
          size: 22,
        );
        break;

      case NotificationType.leaderboardOvertake:
      case NotificationType.leaderboardCityEntry:
      case NotificationType.leaderboardGlobalEntry:
        innerIcon = const Icon(
          Icons.bar_chart_rounded,
          color: Colors.white,
          size: 24,
        );
        break;

      case NotificationType.areaStolen:
        innerIcon = const Icon(
          Icons.share_location_rounded,
          color: Colors.white,
          size: 24,
        );
        break;

      case NotificationType.badgeUnlocked:
        innerIcon = const Icon(
          Icons.workspace_premium_rounded,
          color: Colors.white,
          size: 24,
        );
        break;
    }

    return CircleAvatar(
      radius: 24,
      backgroundColor: const Color(0xFF5C6B59),
      child: innerIcon,
    );
  }

  Widget _buildTrailingWidget(NotificationItem item) {
    if (item.type == NotificationType.newFollower && item.actorId != null && _currentUserId.isNotEmpty) {
      return _FollowToggleWidget(
        currentUserId: _currentUserId,
        targetUserId: item.actorId!,
      );
    }

    return const Icon(
      Icons.chevron_right_rounded,
      color: Color(0xFF8A9389),
      size: 24,
    );
  }
}

// ==========================================
// Dynamic Follow Toggle Button
// ==========================================
class _FollowToggleWidget extends StatefulWidget {
  final String currentUserId;
  final String targetUserId;

  const _FollowToggleWidget({
    required this.currentUserId,
    required this.targetUserId,
  });

  @override
  State<_FollowToggleWidget> createState() => _FollowToggleWidgetState();
}

class _FollowToggleWidgetState extends State<_FollowToggleWidget> {
  bool _isFollowing = false;
  bool _isLoading = true;
  StreamSubscription<DocumentSnapshot>? _sub;

  @override
  void initState() {
    super.initState();
    final followId = '${widget.currentUserId}_${widget.targetUserId}';
    _sub = FirebaseFirestore.instance.collection('follows').doc(followId).snapshots().listen((doc) {
      if (mounted) {
        setState(() {
          _isFollowing = doc.exists;
          _isLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _toggleFollow() async {
    final followId = '${widget.currentUserId}_${widget.targetUserId}';
    final followRef = FirebaseFirestore.instance.collection('follows').doc(followId);

    try {
      if (_isFollowing) {
        await followRef.delete();
      } else {
        await followRef.set({
          'followerId': widget.currentUserId,
          'followingId': widget.targetUserId,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to update follow status.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        width: 24, 
        height: 24, 
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4A8C52))
      );
    }

    return GestureDetector(
      onTap: _toggleFollow,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _isFollowing ? Colors.transparent : const Color(0xFFCAF0B8),
          border: _isFollowing ? Border.all(color: const Color(0xFF8A9389)) : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          _isFollowing ? 'Stop following' : 'Follow back',
          style: TextStyle(
            color: _isFollowing ? const Color(0xFF8A9389) : const Color(0xFF2E4029),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}