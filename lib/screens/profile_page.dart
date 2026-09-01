import 'dart:async';

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
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
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
                  builder: (context) => const SettingsPage(),
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
                    userId: FirebaseAuth.instance.currentUser!.uid,
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
                    userId: FirebaseAuth.instance.currentUser!.uid
                  ),
                  ProfileActivitySections(
                    key: _activityKey,
                    userId: FirebaseAuth.instance.currentUser!.uid,
                    isCurrentUser: true,
                    displayName: _name,
                  ),
                ],
              ),
            ),
          ),
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
        builder: (context) => EditProfilePage()
      ),
    );
  }

  void _shareProfile(){
    final user = FirebaseAuth.instance.currentUser;
            
    if (user == null) return;
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ShareProfilePage(
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
        builder: (context) => const SearchFriendPage(),
      ),
    );
  }

  void _startProfileStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _profileSub = FirebaseFirestore.instance
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
    final user =  FirebaseAuth.instance.currentUser;

    if (user == null) return;

    final staticBadges = await BadgeService().getProfileBadges(user.uid);
    final prefs = await SharedPreferences.getInstance();

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

    _badgeSub = FirebaseFirestore.instance
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
