import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/public_profile_page.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_user_tile.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class FollowingsFollowersPage extends StatefulWidget {
  final String userId;
  final int initialSection; // 0 for Followers, 1 for Following

  static const int followersSection = 0;
  static const int followingSection = 1;

  const FollowingsFollowersPage({
    super.key,
    required this.userId,
    this.initialSection = followersSection,
  });

  @override
  State<FollowingsFollowersPage> createState() => _FollowingsFollowersPageState();
}

class _FollowingsFollowersPageState extends State<FollowingsFollowersPage> {
  late final PageController _pageController;
  late int _activeSection;

  @override
  void initState() {
    super.initState();
    _activeSection = widget.initialSection;
    _pageController = PageController(initialPage: widget.initialSection);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar.centerActions(
        titleWidget: _SectionTabs(
          activeSection: _activeSection, 
          onSelected: _goToSection
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                children: [
                  _UserListSection(
                    userId: widget.userId,
                    isFollowers: true,
                  ),
                  _UserListSection(
                    userId: widget.userId,
                    isFollowers: false,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onPageChanged(int section) {
    setState(() => _activeSection = section);
  }

  void _goToSection(int section) {
    if (section == _activeSection) return;
    _pageController.animateToPage(
      section,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }
}

class _SectionTabs extends StatelessWidget {
  final int activeSection;
  final ValueChanged<int> onSelected;

  const _SectionTabs({
    required this.activeSection,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(ResponsiveSpacing().sm / 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: context.radiusXl,
      ),
      child: Row(
        children: [
          Expanded(
            child: _Tab(
              label: 'Followers',
              icon: Symbols.group_rounded,
              selected: activeSection == FollowingsFollowersPage.followersSection,
              onTap: () => onSelected(FollowingsFollowersPage.followersSection),
            ),
          ),
          Expanded(
            child: _Tab(
              label: 'Following',
              icon: Symbols.person_pin_rounded,
              selected: activeSection == FollowingsFollowersPage.followingSection,
              onTap: () => onSelected(FollowingsFollowersPage.followingSection),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium!;

    final Color foreground = selected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          vertical: ResponsiveSpacing().sm,
          horizontal: ResponsiveSpacing().sm,
        ),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: context.radiusXl,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          spacing: ResponsiveSpacing().sm / 2,
          children: [
            Icon(icon, size: textStyle.fontSize, color: foreground),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserListSection extends StatelessWidget {
  final String userId;
  final bool isFollowers;

  const _UserListSection({
    required this.userId,
    required this.isFollowers,
  });

  @override
  Widget build(BuildContext context) {
    final queryField = isFollowers ? 'followingId' : 'followerId';
    final targetField = isFollowers ? 'followerId' : 'followingId';

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('follows')
          .where(queryField, isEqualTo: userId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Text(
              isFollowers ? "No followers yet" : "Not following anyone yet",
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          );
        }

        final userIds = snapshot.data!.docs
            .map((doc) => (doc.data() as Map<String, dynamic>)[targetField] as String?)
            .where((id) => id != null)
            .cast<String>()
            .toList();

        return ListView.builder(
          padding: EdgeInsets.symmetric(horizontal: ResponsiveSpacing().md),
          itemCount: userIds.length,
          itemBuilder: (context, index) {
            return _UserTileWrapper(targetUserId: userIds[index]);
          },
        );
      },
    );
  }
}

class _UserTileWrapper extends StatelessWidget {
  final String targetUserId;

  const _UserTileWrapper({required this.targetUserId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('profiles').doc(targetUserId).get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
        final name = data['name'] ?? 'Unknown';
        final surname = data['surname'] ?? '';
        final email = data['email'] ?? '';
        final profileImageUrl = data['profileImageUrl'] ?? '';

        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        final isSelf = currentUserId == targetUserId;

        return StreamBuilder<DocumentSnapshot>(
          stream: currentUserId != null
              ? FirebaseFirestore.instance
                  .collection('follows')
                  .doc('${currentUserId}_$targetUserId')
                  .snapshots()
              : const Stream.empty(),
          builder: (context, followSnapshot) {
            final isFollowing = followSnapshot.hasData && followSnapshot.data!.exists;

            return Padding(
              padding: EdgeInsets.symmetric(vertical: ResponsiveSpacing().sm / 2),
              child: DashUserTile(
                name: name,
                surname: surname,
                email: email,
                profileImageUrl: profileImageUrl,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PublicProfilePage(userId: targetUserId),
                    ),
                  );
                },
                trailingIcon: !isSelf
                    ? DashActionButton(
                        icon: isFollowing ? Symbols.person_remove_rounded : Symbols.person_add_rounded,
                        onPressed: () => _toggleFollow(context, targetUserId, isFollowing),
                      )
                    : null,
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleFollow(BuildContext context, String otherUserId, bool isFollowing) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || currentUser.uid == otherUserId) return;

    final followId = '${currentUser.uid}_$otherUserId';
    final followRef = FirebaseFirestore.instance.collection('follows').doc(followId);

    try {
      if (isFollowing) {
        await followRef.delete();
      } else {
        await followRef.set({
          'followerId': currentUser.uid,
          'followingId': otherUserId,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Failed to update follow status.');
      }
    }
  }
}