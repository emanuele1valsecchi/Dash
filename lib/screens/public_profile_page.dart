import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/screens/share_profile_page.dart';
import 'package:dash/services/badge_service.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/services/storage_service.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_route_card.dart';
import 'package:dash/widgets/dash_section_container.dart';
import 'package:dash/widgets/profile/bio_text_box.dart';
import 'package:dash/widgets/profile/profile_badge_section.dart';
import 'package:dash/widgets/profile/profile_header.dart';
import 'package:dash/widgets/profile/route_source.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class PublicProfilePage extends StatefulWidget {
  final String userId;

  const PublicProfilePage({
    super.key,
    required this.userId,
  });

  @override
  State<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<PublicProfilePage> {
  bool _isLoading = true;
  bool _userNotFound = false;

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
  List<RouteEntry> _createdRoutes = [];

  List<RouteEntry> get _allRoutes => [..._ownedRoutes, ..._favoriteRoutes, ..._createdRoutes]
    ..sort((a, b) => b.route.createdAt.compareTo(a.route.createdAt));

  StreamSubscription<DocumentSnapshot>? _profileSub;
  StreamSubscription<QuerySnapshot>? _badgeSub;
  StreamSubscription<QuerySnapshot>? _ownedRoutesSub;
  StreamSubscription<QuerySnapshot>? _favoriteRoutesSub;
  StreamSubscription<QuerySnapshot>? _createdRoutesSub;

  final StorageService _storageService = StorageService();
  
  static final Map<String, String> _publicUrlCache = {};

  @override
  void initState() {
    super.initState();
    _startProfileStream();
    _startBadgesStream();
    _startRoutesStream();
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _badgeSub?.cancel();
    _ownedRoutesSub?.cancel();
    _favoriteRoutesSub?.cancel();
    _createdRoutesSub?.cancel();
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

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: ResponsiveSpacing().lg,
        children: [
          ProfileHeader(
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
          _buildActivitiesSection(),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {    
    return Row(
      spacing: ResponsiveSpacing().sm,
      children: [
        Expanded(
          child: DashActionButton(
            onPressed: () {
              // TODO: Implement Follow functionality
              context.showInformationSnackBar('Follow feature coming soon!');
            },
            icon: Symbols.person_add_rounded,
            label: "Follow",
          )
        ),

        DashActionButton(
          onPressed: _shareProfilePage,
          icon: Symbols.share_rounded,
        ),
      ],
    );
  }

  Widget _buildActivitiesSection() {
    return DashSectionContainer(
      title: "Activities",
      child: _allRoutes.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _allRoutes.length,
              itemBuilder: (context, i) => DashRouteCard(
                entry: _allRoutes[i],
                onTap: () {
                  // TODO: navigate to info path
                },
                onActionTap: () {},
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    ThemeData contextTheme = Theme.of(context);

    TextStyle bodyLargeTextStyle = contextTheme.textTheme.bodyLarge!.copyWith(
      color: contextTheme.colorScheme.outlineVariant,
    );

    return Center(
      child: Column(
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
            style: bodyLargeTextStyle.copyWith(fontWeight: FontWeight.bold),
          ),
          SizedBox(
            width: MediaQuery.widthOf(context) * 2 / 3,
            child: Text(
              '$_name hasn\'t completed or favorited any routes yet.',
              textAlign: TextAlign.center,
              style: bodyLargeTextStyle,
            ),
          ),
        ],
      ),
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
    // Notice we use widget.userId instead of the current user
    _profileSub = FirebaseFirestore.instance
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
    final staticBadges = await BadgeService().getProfileBadges(widget.userId);

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

    _badgeSub = FirebaseFirestore.instance
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

  void _startRoutesStream() {
    final db = FirebaseFirestore.instance;

    _ownedRoutesSub = db
        .collection('routes')
        .where('userId', isEqualTo: widget.userId)
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
        .where('userId', isEqualTo: widget.userId)
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
          debugPrint('Skipping live public favourite $routeId: $e');
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
        .where("userId", isEqualTo: widget.userId)
        .snapshots()
        .listen((snap) async {
      final created = <RouteEntry>[];

      for (final doc in snap.docs) {
        final data = doc.data();
        final String? routeId = data['routeId'];

        if (routeId == null) continue;

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
          debugPrint('Skipping live public created $routeId: $e');
        }
      }

      if (mounted) {
        setState(() {
          _createdRoutes = created; // Note: In your original code this was a typo assigning to _favoriteRoutes
        });
      }
    });
  }
}