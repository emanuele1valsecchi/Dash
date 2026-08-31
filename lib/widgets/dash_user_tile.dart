import 'package:dash/utils/strings_utils.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';

class DashUserTile extends StatelessWidget{
  final String name;
  final String surname;
  final String email;
  final String profileImageUrl;

  final Function()? onTap;

  final IconButton? trailingIcon;

  const DashUserTile({
    super.key, 
    required this.name, 
    required this.surname, 
    required this.email, 
    required this.profileImageUrl, 
    this.trailingIcon,
    this.onTap, 
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: ProfilePictureAvatar(
        initialNameSurname: getFirstLetters(name, surname),
        imageUrl: profileImageUrl,
      ),

      title: Text(
        '$name $surname'.trim(),
        style: Theme.of(context).textTheme.bodyMedium!,
      ),
      subtitle: Text(
        email,
        style: Theme.of(context).textTheme.bodySmall!.copyWith(
          color: Theme.of(context).colorScheme.outline
        ),
      ),
      
      trailing: trailingIcon
    );
  }
}