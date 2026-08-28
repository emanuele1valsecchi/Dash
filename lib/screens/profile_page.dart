import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/screens/badge_page.dart';
import 'package:dash/screens/edit_profile_page.dart';
import 'package:dash/services/badge_service.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/services/storage_service.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:dash/widgets/dash_gesture_card_container.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_route_card.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/profile/bio_text_box.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'settings_page.dart';
import 'package:dash/utils/strings_utils.dart';

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
  List<RouteEntry> _ownedRoutes = [];
  List<RouteEntry> _favoriteRoutes = [];
  final List<RouteEntry> _createdRoutes = [];

  List<RouteEntry> get _allRoutes => [..._ownedRoutes, ..._favoriteRoutes, ..._createdRoutes]
    ..sort((a, b) => b.route.createdAt.compareTo(a.route.createdAt));

  StreamSubscription<DocumentSnapshot>? _profileSub;
  StreamSubscription<QuerySnapshot>? _badgeSub;
  StreamSubscription<QuerySnapshot>? _ownedRoutesSub;
  StreamSubscription<QuerySnapshot>? _favoriteRoutesSub;
  StreamSubscription<QuerySnapshot>? _createdRoutesSub;

  final StorageService _storageService = StorageService();

  static final Map<String, String> _profileUrlCache = {};

  @override
  void initState() {
    super.initState();
    _startProfileStream();
    _startBadgesStream();
    _startRoutesStream();
  }

  @override
  void dispose(){
    _profileSub?.cancel();
    _badgeSub?.cancel();
    _ownedRoutesSub?.cancel();
    _favoriteRoutesSub?.cancel();
    _createdRoutesSub?.cancel();
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
        : SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: ResponsiveSpacing().lg,
              children: [
                _buildProfileHeader(),
                BioTextBox(bio: _bio),
                _buildActionButtons(),
                _buildBadgeSection(),
                _buildActivitiesSection(),
              ],
            ),
          ),
    );
  }

  Widget _buildProfileHeader(){
    final double screenWidth = MediaQuery.widthOf(context);
    final double screenHeight = MediaQuery.heightOf(context);

    return Row(
      children: [
        ProfilePictureAvatar(imageUrl: _profileImageUrl, initialNameSurname: getFirstLetters(_name, _surname),),
        SizedBox(width: screenWidth * 0.08),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$_name $_surname',
                style: Theme.of(context).textTheme.headlineSmall),
              Text(
                _email,
                style: Theme.of(context).textTheme.labelLarge!.copyWith(color: Theme.of(context).colorScheme.outline)
              ),
              SizedBox(height: screenHeight * 0.02),
              Row(
                children: [
                  _buildFollowersCount(formatNumber(_followers), 'Followers'),
                  _buildFollowersCount(formatNumber(_following), 'Following'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFollowersCount(String value, String label) {
    return Expanded(
      child:  Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.labelLarge!.copyWith(
              fontWeight: FontWeight.bold
            )
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium)
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        ProfileActionButton(
          type: ProfileActionButtonType.edit,
          onPressedOverride: () async {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const EditProfilePage()),
            );
          },
        ),
        Spacer(),
        ProfileActionButton(type: ProfileActionButtonType.share),
        ProfileActionButton(type: ProfileActionButtonType.add)
      ],
    );
  }

  Widget _buildBadgeSection(){
    if (_badges.isEmpty){
      return Center(
        child: Padding(
          padding: context.paddingSm,
          child: CircularProgressIndicator(),
        ),
      );
    }

    final displayBadges = _badges;

    return DashGestureCardContainer(
      title: "Badges",
      onTap: () => _showBadge(context),
      actions: [
        Icon(
          Symbols.arrow_forward_ios_rounded,
          color: Theme.of(context).colorScheme.outline,
          size: Theme.of(context).textTheme.bodySmall!.fontSize,
        )
      ],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: displayBadges.map((badge) {
          return DashBadge(
            badge: badge, 
            progress: badge.progress,
            dimFactor: 0.16,
            clickable: false,
          );
        }).toList()
      )
    );
  }

  void _showBadge(BuildContext context){
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => BadgePage()
      ),
    );
  }

  Widget _buildActivitiesSection(){
    return DashSectionContainer(
      title: "Activities", 
      child: _allRoutes.isEmpty
        ? _buildEmptyState()
        : ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _allRoutes.length,
            itemBuilder: (context, i) =>
                DashRouteCard(
                  entry: _allRoutes[i], 
                  onTap: () {
                    // TODO: navigate to info path
                  }, 
                  onActionTap: () => {}
                )
          ),
    );
  }

  Widget _buildEmptyState() {
    ThemeData contextTheme = Theme.of(context);

    TextStyle bodyLargeTextStyle = contextTheme.textTheme.bodyLarge!.copyWith(
      color: contextTheme.colorScheme.outlineVariant,
    );

    return Center(
      child:Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: ResponsiveSpacing().sm,
        children: [
          Icon(
            Symbols.route_rounded, 
            size: contextTheme.textTheme.displayLarge!.fontSize, 
            color: contextTheme.colorScheme.outlineVariant,
            fill: 1,
          ),
          Text(
            'No activities yet',
            style: bodyLargeTextStyle.copyWith(
              fontWeight: FontWeight.bold
            ),
          ),
          SizedBox(
            width: MediaQuery.widthOf(context) * 2 / 3,
            child: Text(
              'Complete a run, create a route or favourite one to see it here.',
              textAlign: TextAlign.center,
              style: bodyLargeTextStyle,
            ) 
          ),
        ],
      )
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

    for (final badge in staticBadges) {
      if (!_profileUrlCache.containsKey(badge.imagePath)) {
        try {
          _profileUrlCache[badge.imagePath] = 
              await _storageService.getDownloadUrl(badge.imagePath);
        } catch (_) {
          _profileUrlCache[badge.imagePath] = '';
        }
      }
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
  
  void _startRoutesStream() {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    final db = FirebaseFirestore.instance;

    _ownedRoutesSub = db
      .collection('routes')
      .where('userId', isEqualTo: user.uid)
      .snapshots()
      .listen((snap) {
        final owned = snap.docs.map((doc) {
            return RouteEntry(SavedRoute.fromDoc(doc), RouteSource.owned);
          }).toList();

        if (mounted) {
          setState(() {
            _ownedRoutes = owned;
          });
        }
      });

    _favoriteRoutesSub = db
      .collection('favoriteRoutes')
      .where('userId', isEqualTo: user.uid)
      .snapshots()
      .listen((snap) async {
        final favorites = <RouteEntry>[];

        for (final doc in snap.docs) {
          final data = doc.data();
          final String? routeId = data['routeId'];
          if (routeId == null) continue;

          try {
            final routeSnap = await db.collection('routes').doc(routeId).get();
            if (routeSnap.exists) {
              favorites.add(
                RouteEntry(
                  SavedRoute.fromSharedRoute(
                    routeSnap,
                    name: data['name'] ?? 'Favourited run',
                  ),
                  RouteSource.favorite,
                ),
              );
            }
          } catch (e) {
            debugPrint('Skipping live favourite $routeId: $e');
          }
        }

        if (mounted) {
          setState(() {
            _favoriteRoutes = favorites;
          });
        }
      });

    _createdRoutesSub = db
      .collection("created")
      .where("userId", isEqualTo: user.uid)
      .snapshots()
      .listen((snap) async{
        final created = <RouteEntry>[];

        for (final doc in snap.docs){
          final data = doc.data();
          final String? routeId = data['routeId'];

          if( routeId == null ) continue;

          try {
            final routeSnap = await db.collection('routes').doc(routeId).get();

            if (routeSnap.exists) {
              created.add(
                RouteEntry(
                  SavedRoute.fromSharedRoute(
                    routeSnap,
                    name: data['name'] ?? 'Created run',
                  ),
                  RouteSource.created,
                ),
              );
            }
          } catch (e) {
            debugPrint('Skipping live created $routeId: $e');
          }
        }

        if (mounted) {
          setState(() {
            _favoriteRoutes = created;
          });
        }
      });
  }
}

enum ProfileActionButtonType{
  edit(Symbols.person_edit_rounded, label: 'Edit Profile', action: _editProfile),
  share(Symbols.share_rounded, label: 'Share Profile', action: _shareProfile),
  add(Symbols.person_add_rounded, action: _addFriend);

  final IconData iconData;
  final String label;
  final void Function(BuildContext context) action;

  const ProfileActionButtonType(
    this.iconData, {
    this.label = '',
    required this.action,
  });
}

class ProfileActionButton extends StatelessWidget{
  final ProfileActionButtonType type;
  final VoidCallback? onPressedOverride;
  
  const ProfileActionButton({
    super.key, 
    required this.type,
    this.onPressedOverride,
  });

  @override
  Widget build(BuildContext context) {
    final ButtonStyle style = ElevatedButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.secondary,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      textStyle: Theme.of(context).textTheme.bodySmall
    );

    final Icon icon = Icon(
      type.iconData,
      size: Theme.of(context).iconTheme.size,
    );

    if (type == ProfileActionButtonType.add){
      return ElevatedButton(
        onPressed: onPressedOverride ?? () => type.action(context),
        style: style.copyWith(
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.all(1)),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(CircleBorder())
        ),
        child: icon,
      );
    }

    return ElevatedButton.icon(
      style: style,
      icon: icon,
      label: Text(
        type.label
      ),
      onPressed: onPressedOverride ?? () => type.action(context),
    );
  }
}

void _editProfile(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (context) => EditProfilePage()
    ),
  );
}

void _shareProfile(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Share profile')),
  );
}

void _addFriend(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Add friend')),
  );
}