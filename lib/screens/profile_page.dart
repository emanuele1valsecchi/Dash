import 'dart:async';
import 'package:dash/root_screen.dart';
import 'package:dash/widgets/dash_navigation_bar.dart';

import '../models/badge_model.dart';
import '../services/route_repository.dart';
import '../services/run_session_repository.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/screens/edit_profile_page.dart';
import 'package:dash/screens/search_friend_page.dart';
import 'package:dash/screens/share_profile_page.dart';
import 'package:dash/services/badge_service.dart';
import 'package:dash/services/storage_service.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/profile/bio_text_box.dart';
import 'package:dash/widgets/profile/profile_activity_sections.dart';
import 'package:dash/widgets/profile/profile_badge_section.dart';
import 'package:dash/widgets/profile/profile_header.dart';
import 'package:dash/widgets/profile/profile_statistics_section.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_page.dart';

class ProfilePage extends StatefulWidget {
  /// Injectable for tests, each defaulting to the real thing, so no call
  /// site changes. Mirrors `PublicProfilePage`'s seam set — the two screens
  /// are twins and should stay testable the same way.
  
  final bool isStandalone;

  @visibleForTesting
  final FirebaseFirestore? firestore;
  @visibleForTesting
  final FirebaseAuth? auth;
  @visibleForTesting
  final BadgeService? badgeService;
  @visibleForTesting
  final RunSessionRepository? sessionRepository;
  @visibleForTesting
  final RouteRepository? routeRepository;

  /// Test seams for the four places this page can go.
  ///
  /// Each destination builds its own Firebase-backed world — settings reads
  /// preferences, share resolves a profile link, friend search opens a live
  /// query — so a widget test cannot let the real page be constructed just
  /// to find out whether the button pushed anything. Substituting the
  /// destination is what makes the *tap* assertable, and the tap is the
  /// behaviour: which button leads where, and that Share carries the
  /// identity it is sharing. Same pattern as `SearchFriendPage`'s own
  /// `profilePageBuilder`. Production leaves all four null.
  @visibleForTesting
  final Widget Function()? settingsPageBuilder;
  @visibleForTesting
  final Widget Function()? editProfilePageBuilder;
  @visibleForTesting
  final Widget Function(String userId, String name, String surname)?
      shareProfilePageBuilder;
  @visibleForTesting
  final Widget Function()? searchFriendPageBuilder;

  const ProfilePage({
    super.key,
    this.isStandalone = false,
    this.firestore,
    this.auth,
    this.badgeService,
    this.sessionRepository,
    this.routeRepository,
    this.settingsPageBuilder,
    this.editProfilePageBuilder,
    this.shareProfilePageBuilder,
    this.searchFriendPageBuilder,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;
  late final FirebaseAuth _auth = widget.auth ?? FirebaseAuth.instance;
  late final BadgeService _badgeService = widget.badgeService ?? BadgeService();

  bool _isLoading = true;

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

  /// Lets pull-to-refresh re-read the Runs/Routes rows. They are one-time
  /// cached reads rather than listeners (see `ProfileActivitySections`), and
  /// this page lives in the bottom-nav shell, so without this a route saved
  /// elsewhere in the app wouldn't appear until the app restarted.
  final GlobalKey<ProfileActivitySectionsState> _activityKey =
      GlobalKey<ProfileActivitySectionsState>();

  final StorageService _storageService = StorageService();

  static final Map<String, String> _profileUrlCache = {};

  @override
  void initState() {
    super.initState();
    _startProfileStream();
    _startBadgesStream();
  }

  @override
  void dispose(){
    _profileSub?.cancel();
    _badgeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "",
        actions: [
          IconButton(
            icon: Icon(
              Symbols.settings_rounded,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      widget.settingsPageBuilder?.call() ??
                      const SettingsPage(),
                ),
              );
            },
          ),
        ],
      ),

      body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: () async =>
                await _activityKey.currentState?.reload(),
            color: Theme.of(context).colorScheme.tertiary,
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: ResponsiveSpacing().lg,
                children: [
                  ProfileHeader(
                    userId: _auth.currentUser!.uid,
                    name: _name,
                    surname: _surname,
                    email: _email,
                    profileImageUrl: _profileImageUrl,
                    followers: _followers,
                    following: _following,
                  ),
                  BioTextBox(bio: _bio),
                  _buildActionButtons(),
                  ProfileBadgeSection(
                    badges: _badges,
                    userId: _auth.currentUser!.uid
                  ),
                  ProfileStatisticsSection(
                    userId: _auth.currentUser!.uid,
                    firestore: widget.firestore,
                  ),
                  ProfileActivitySections(
                    sessionRepository: widget.sessionRepository,
                    routeRepository: widget.routeRepository,
                    key: _activityKey,
                    userId: _auth.currentUser!.uid,
                    isCurrentUser: true,
                    displayName: _name,
                  ),
                ],
              ),
            ),
          ),

      bottomNavigationBar: widget.isStandalone
        ? DashNavigationbar(
            selectedIndex: 2,
            onDestinationSelected: (index) {
              Navigator.popUntil(context, (route) => route.isFirst);
              RootScreen.tabNotifier.value = index;
            },
          )
        : null,
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,

      children: [
        DashActionButton(
          onPressed: _editProfile,
          label: "Edit Profile",
          icon: Symbols.person_edit_rounded,
        ),

        DashActionButton(
          onPressed: _shareProfile,
          label: "Share Profile",
          icon: Symbols.share_rounded
        ),

        DashActionButton(
          onPressed: _searchFriend,
          icon: Symbols.person_add_rounded,
        )
      ],
    );
  }

  void _editProfile(){
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) =>
            widget.editProfilePageBuilder?.call() ?? EditProfilePage(),
      ),
    );
  }

  void _shareProfile(){
    final user = _auth.currentUser;
            
    if (user == null) return;
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            widget.shareProfilePageBuilder?.call(user.uid, _name, _surname) ??
            ShareProfilePage(
              userId: user.uid,
              name: _name,
              surname: _surname,
              profileImageUrl: _profileImageUrl,
            ),
      ),
    );
  }

  void _searchFriend() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            widget.searchFriendPageBuilder?.call() ?? const SearchFriendPage(),
      ),
    );
  }

  void _startProfileStream() {
    final user = _auth.currentUser;
    if (user == null) return;

    _profileSub = _db
      .collection('profiles')
      .doc(user.uid)
      .snapshots()
      .listen(
        (doc) {
          if (!mounted || !doc.exists) return;

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
          debugPrint('Error in profile stream: $e');
          if (mounted) setState(() => _isLoading = false);
        }
      );
  }

  void _startBadgesStream() async {
    final user = _auth.currentUser;

    if (user == null) return;

    // Guarded because this is `async void`: nothing awaits it, so a throw
    // here escapes as an unhandled async error rather than being caught by a
    // caller. Badges are decoration — a failed read (a network blip, or a
    // rules change like the one that used to deny `badge_progress`
    // outright) must cost the badges, not the whole profile.
    //
    // Same fix, same reason, as `public_profile_page.dart` and
    // `badge_page.dart`; this was the third copy of the bug.
    final List<BadgeModel> staticBadges;
    final SharedPreferences prefs;
    try {
      staticBadges = await _badgeService.getProfileBadges(user.uid);
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('Could not load badges for ${user.uid}: $e');
      return;
    }

    for (final badge in staticBadges) {
      if (!_profileUrlCache.containsKey(badge.imagePath)) {
        final String cacheKey = 'badge_url_${badge.imagePath}';
        final String? diskCachedUrl = prefs.getString(cacheKey);

        if (diskCachedUrl != null && diskCachedUrl.isNotEmpty) {
          _profileUrlCache[badge.imagePath] = diskCachedUrl;
        } else {
          try {
            final url = await _storageService.getDownloadUrl(badge.imagePath);
            _profileUrlCache[badge.imagePath] = url;
            await prefs.setString(cacheKey, url); 
          } catch (_) {
            _profileUrlCache[badge.imagePath] = '';
          }
        }
      }
    }

    if (mounted && _badges.isEmpty) {
      setState(() {
        _badges = staticBadges.map((badge) {
          return HomeBadgeUiModel(
            badgeId: badge.id,
            title: badge.title,
            description: badge.description,
            imageUrl: _profileUrlCache[badge.imagePath] ?? '',
            progress: prefs.getDouble('progress_${badge.id}') ?? 0.0,
            unlocked: prefs.getBool('unlocked_${badge.id}') ?? false,
          );
        }).toList();
      });
    }

    _badgeSub = _db
      .collection('profiles')
      .doc(user.uid)
      .collection('badge_progress')
      .snapshots()
      .listen((snap) {
        final updatedBadges = <HomeBadgeUiModel>[];

        for (final badge in staticBadges) {
          String imageUrl = _profileUrlCache[badge.imagePath] ?? '';

          final progressDoc = snap.docs.where((d) => d.id == badge.id).firstOrNull;
                    
          double progress = 0.0;
          bool unlocked = false;
          
          if (progressDoc != null) {
            final data = progressDoc.data();
            final rawProgress = (data['progress'] as num?)?.toDouble() ?? 0.0;
            progress = (rawProgress / 100).clamp(0.0, 1.0);
            unlocked = data['unlocked'] == true || progress >= 1.0;
          }

          prefs.setDouble('progress_${badge.id}', progress);
          prefs.setBool('unlocked_${badge.id}', unlocked);

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
}
