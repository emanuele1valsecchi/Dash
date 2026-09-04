import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/badge_model.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/screens/share_profile_page.dart';
import 'package:dash/services/badge_service.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:dash/services/storage_service.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/profile/bio_text_box.dart';
import 'package:dash/widgets/profile/profile_activity_sections.dart';
import 'package:dash/widgets/profile/profile_badge_section.dart';
import 'package:dash/widgets/profile/profile_header.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class PublicProfilePage extends StatefulWidget {
  final String userId;

  /// Injectable for tests, each defaulting to the real thing, so no call site
  /// changes.
  ///
  /// This screen needs the most of any so far — it runs three concurrent
  /// `snapshots()` subscriptions (profile, badge progress, follow state) and
  /// embeds `ProfileActivitySections`, which reads two repositories of its
  /// own. `FakeFirebaseFirestore` supports streams, so with `firestore`
  /// supplied all three become real queries over real in-memory documents.
  final FirebaseFirestore? firestore;
  final FirebaseAuth? auth;
  final BadgeService? badgeService;
  final RunSessionRepository? sessionRepository;
  final RouteRepository? routeRepository;

  const PublicProfilePage({
    super.key,
    required this.userId,
      this.firestore,
    this.auth,
    this.badgeService,
    this.sessionRepository,
    this.routeRepository,
  });

  @override
  State<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<PublicProfilePage> {
  bool _isLoading = true;
  bool _userNotFound = false;

  bool _isFollowing = false;
  bool _isLoadingFollowState = true;

  String _name = '';
  String _surname = '';
  String _email = '';
  String _bio = '';
  int _followers = 0;
  int _following = 0;
  String _profileImageUrl = '';

  List<HomeBadgeUiModel> _badges = [];

  StreamSubscription<DocumentSnapshot>? _profileSub;
  StreamSubscription<QuerySnapshot>? _badgeSub;
  StreamSubscription<DocumentSnapshot>? _followSub;

  /// Lets pull-to-refresh re-read the Runs/Routes rows, which are one-time
  /// cached reads rather than listeners (see `ProfileActivitySections`).
  final GlobalKey<ProfileActivitySectionsState> _activityKey =
      GlobalKey<ProfileActivitySectionsState>();

  late final _db = widget.firestore ?? FirebaseFirestore.instance;
  late final _auth = widget.auth ?? FirebaseAuth.instance;
  late final _badgeService = widget.badgeService ?? BadgeService();

  final StorageService _storageService = StorageService();
  
  static final Map<String, String> _publicUrlCache = {};

  @override
  void initState() {
    super.initState();
    _startProfileStream();
    _startBadgesStream();
    _startFollowStream();
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _badgeSub?.cancel();
    _followSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData contextTheme = Theme.of(context);

    return Scaffold(
      backgroundColor: contextTheme.scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "",
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    ThemeData contextTheme = Theme.of(context);
    TextStyle textStyle = contextTheme.textTheme.titleLarge!.copyWith(
      color: Theme.of(context).colorScheme.outline
    );

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_userNotFound) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: ResponsiveSpacing().md,
          children: [
            Icon(
              Symbols.person_off_rounded, 
              size: textStyle.fontSize, 
              color: contextTheme.colorScheme.outline,
            ),

            Text(
              "User not found",
              style: textStyle,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => await _activityKey.currentState?.reload(),
      color: contextTheme.colorScheme.tertiary,
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
        // Always scrollable, so the pull gesture works even when the profile
        // is short enough not to overflow.
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: ResponsiveSpacing().lg,
          children: [
            ProfileHeader(
              userId: widget.userId,
              name: _name,
              surname: _surname,
              email: _email,
              profileImageUrl: _profileImageUrl,
              followers: _followers,
              following: _following,
            ),
            if (_bio.isNotEmpty) BioTextBox(bio: _bio),
            _buildActionButtons(),
            ProfileBadgeSection(
              badges: _badges,
              userId: widget.userId,
            ),
            ProfileActivitySections(
              sessionRepository: widget.sessionRepository,
              routeRepository: widget.routeRepository,
              key: _activityKey,
              userId: widget.userId,
              isCurrentUser: false,
              displayName: _name,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() { 
    final currentUserId = _auth.currentUser?.uid;
    final isSelf = currentUserId == widget.userId;

    return Row(
      spacing: ResponsiveSpacing().sm,
      children: [
        if (!isSelf)
          Expanded(
            child: DashActionButton(
              onPressed: _isLoadingFollowState ? () {} : _toggleFollow,
              icon: _isFollowing 
                  ? Symbols.person_remove_rounded 
                  : Symbols.person_add_rounded,
              label: _isFollowing ? "Remove from Friend" : "Add as friend",
            )
          ),

        DashActionButton(
          onPressed: _shareProfilePage,
          icon: Symbols.share_rounded,
        ),
      ],
    );
  }

  void _shareProfilePage(){
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ShareProfilePage(
          userId: widget.userId,
          name: _name,
          surname: _surname,
          profileImageUrl: _profileImageUrl,
        ),
      ),
    );
  }

  void _startProfileStream() {
    _profileSub = _db
        .collection('profiles')
        .doc(widget.userId)
        .snapshots()
        .listen(
      (doc) {
        if (!mounted) return;

        if (!doc.exists) {
          setState(() {
            _userNotFound = true;
            _isLoading = false;
          });
          return;
        }

        final data = doc.data()!;

        setState(() {
          _name = data['name'] ?? 'No Name';
          _surname = data['surname'] ?? '';
          _email = data['email'] ?? 'No Email';
          _bio = data['bio'] ?? '';
          _followers = (data['followersCount'] as num?)?.toInt() ?? 0;
          _following = (data['followingCount'] as num?)?.toInt() ?? 0;
          _profileImageUrl = data['profileImageUrl'] as String? ?? '';
          _isLoading = false;
        });
      },
      onError: (e) {
        debugPrint('Error in public profile stream: $e');
        if (mounted) {
          setState(() {
            _isLoading = false;
            _userNotFound = true;
          });
        }
      },
    );
  }

  void _startBadgesStream() async {
    // Guarded because this is `async void`: nothing awaits it, so a throw
    // here escapes as an unhandled async error rather than being caught by a
    // caller. Badges are decoration on someone else's profile — a failed read
    // (a network blip, or a rules change like the one that used to deny
    // `badge_progress` outright) must cost the badges, not the page.
    final List<BadgeModel> staticBadges;
    try {
      staticBadges = await _badgeService.getProfileBadges(widget.userId);
    } catch (e) {
      debugPrint('Could not load badges for ${widget.userId}: $e');
      return;
    }

    for (final badge in staticBadges) {
      if (!_publicUrlCache.containsKey(badge.imagePath)) {
        try {
          _publicUrlCache[badge.imagePath] =
              await _storageService.getDownloadUrl(badge.imagePath);
        } catch (_) {
          _publicUrlCache[badge.imagePath] = '';
        }
      }
    }

    _badgeSub = _db
        .collection('profiles')
        .doc(widget.userId)
        .collection('badge_progress')
        .snapshots()
        .listen((snap) {
      final updatedBadges = <HomeBadgeUiModel>[];

      for (final badge in staticBadges) {
        String imageUrl = _publicUrlCache[badge.imagePath] ?? '';

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

  void _startFollowStream() {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return;

    // Use a composite ID to prevent duplicate follow records
    final followId = '${currentUser.uid}_${widget.userId}';

    _followSub = _db
        .collection('follows')
        .doc(followId)
        .snapshots()
        .listen((doc) {
      if (mounted) {
        setState(() {
          _isFollowing = doc.exists;
          _isLoadingFollowState = false;
        });
      }
    });
  }

  Future<void> _toggleFollow() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return;

    // Prevent following yourself
    if (currentUser.uid == widget.userId) return;

    final followId = '${currentUser.uid}_${widget.userId}';
    final followRef = _db.collection('follows').doc(followId);

    try {
      if (_isFollowing) {
        await followRef.delete();
      } else {
        await followRef.set({
          'followerId': currentUser.uid,
          'followingId': widget.userId,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to update follow status.');
      }
    }
  }
}
