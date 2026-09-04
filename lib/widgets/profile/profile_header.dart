import 'package:dash/screens/followings_followers_page.dart';
import 'package:dash/utils/strings_utils.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';

class ProfileHeader extends StatelessWidget{

  final String userId;

  final String name;
  final String surname;
  final String email;
  final String profileImageUrl;
  final int followers;
  final int following;

  const ProfileHeader({
    super.key, 
    required this.userId,
    required this.name, 
    required this.surname, 
    required this.email, 
    required this.profileImageUrl, 
    required this.followers, 
    required this.following, 
  });

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.widthOf(context);
    final double screenHeight = MediaQuery.heightOf(context);

    return Row(
      children: [
        ProfilePictureAvatar(
          imageUrl: profileImageUrl,
          initialNameSurname: getFirstLetters(name, surname),
        ),
        SizedBox(width: screenWidth * 0.08),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$name $surname',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                email,
                style: Theme.of(context).textTheme.labelLarge!.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              SizedBox(height: screenHeight * 0.02),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => FollowingsFollowersPage(
                              userId: userId,
                              initialSection: FollowingsFollowersPage.followersSection,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: _buildFollowersCount(context, formatNumber(followers), 'Followers'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => FollowingsFollowersPage(
                              userId: userId,
                              initialSection: FollowingsFollowersPage.followingSection,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: _buildFollowersCount(context, formatNumber(following), 'Following'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFollowersCount(BuildContext context, String value, String label) {
    // Deliberately NOT wrapped in `Expanded`. Both call sites are already
    // `Row > Expanded > InkWell > Padding`, so a second `Expanded` here lands
    // inside the `Padding` and throws "Incorrect use of ParentDataWidget" —
    // an `Expanded` may only be a direct child of a `Flex`. That assertion
    // fired on every render of a profile header. Caught by
    // `public_profile_page_test.dart`.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.labelLarge!.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
    );
  }


}