import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/services/badge_service.dart';
import 'package:dash/services/storage_service.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BadgePage extends StatefulWidget {
  final String userId;

	const BadgePage({
    super.key, 
    required this.userId
  });

	@override
	State<BadgePage> createState() => _BadgePageState();
}

class _BadgePageState extends State<BadgePage> {
  static const int _badgesColumn = 3;

  bool _isLoading = true;
  List<HomeBadgeUiModel> _badges = [];
  StreamSubscription<QuerySnapshot>? _badgeSub;
  final StorageService _storageService = StorageService();

  static final Map<String, String> _urlCache = {};

  @override
  void initState() {
    super.initState();
    _startBadgesStream();
  }

  @override
  void dispose() {
    _badgeSub?.cancel();
    super.dispose();
  }
  
	@override
	Widget build(BuildContext context) {
		return Scaffold(
      appBar: DashNavigationTopBar(
        title: "Badges"
      ),

      body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : GridView.builder(
          padding: context.paddingMd,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _badgesColumn,
            crossAxisSpacing: ResponsiveSpacing().sm,
            mainAxisSpacing: ResponsiveSpacing().lg,
            childAspectRatio: 0.8
          ),
          itemCount: _badges.length,
          itemBuilder: (context, index) {
            final badge = _badges[index];
            return Align(
              alignment: Alignment.topCenter,
              child: DashBadge(
                badge: badge,
                progress: badge.progress,
                dimFactor: 0.16,
                clickable: true,
              ) 
            );
          },
        ),
    );
	}

  void _startBadgesStream() async {
    
    final staticBadges = await BadgeService().getAllBadges(widget.userId);
    final prefs = await SharedPreferences.getInstance();

    for (final badge in staticBadges) {
      if (!_urlCache.containsKey(badge.imagePath)) {
        final String cacheKey = 'badge_url_${badge.imagePath}';
        final String? diskCachedUrl = prefs.getString(cacheKey);

        if (diskCachedUrl != null && diskCachedUrl.isNotEmpty) {
          _urlCache[badge.imagePath] = diskCachedUrl;
        } else {
          final url = await _storageService.getDownloadUrlSafe(badge.imagePath) ?? '';
          _urlCache[badge.imagePath] = url;
          if (url.isNotEmpty) {
            await prefs.setString(cacheKey, url);
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
            imageUrl: _urlCache[badge.imagePath] ?? '',
            
            progress: prefs.getDouble('progress_${widget.userId}_${badge.id}') ?? 0.0,
            unlocked: prefs.getBool('unlocked_${widget.userId}_${badge.id}') ?? false,
          );
        }).toList();
        
        _isLoading = false; 
      });
    }

    _badgeSub = FirebaseFirestore.instance
      .collection('profiles')
      .doc(widget.userId)
      .collection('badge_progress')
      .snapshots()
      .listen((snap) {
        final updatedBadges = <HomeBadgeUiModel>[];

        for (final badge in staticBadges) {
          String imageUrl = _urlCache[badge.imagePath] ?? '';
          final progressDoc = snap.docs.where((d) => d.id == badge.id).firstOrNull;
          
          double progress = 0.0;
          bool unlocked = false;
          
          if (progressDoc != null) {
            final data = progressDoc.data();
            final rawProgress = (data['progress'] as num?)?.toDouble() ?? 0.0;
            progress = (rawProgress / 100).clamp(0.0, 1.0);
            unlocked = data['unlocked'] == true || progress >= 1.0;
          }

          prefs.setDouble('progress_${widget.userId}_${badge.id}', progress);
          prefs.setBool('unlocked_${widget.userId}_${badge.id}', unlocked);

          updatedBadges.add(HomeBadgeUiModel(
            badgeId: badge.id,
            title: badge.title,
            description: badge.description,
            imageUrl: imageUrl,
            progress: progress,
            unlocked: unlocked,
          ));
        }

        if (mounted) {
          setState(() {
            _badges = updatedBadges;
            _isLoading = false;
          });
        }
      });
  }
}