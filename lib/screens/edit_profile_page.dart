import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class EditProfilePage extends StatelessWidget{
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: 'Edit profile',
        actions: [IconButton(
          onPressed: (){
            // TODO: push changes to DB
          }, 
          tooltip: 'Confirm changes',
          icon: Icon(Symbols.check_rounded)
        )],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ProfilePictureAvatar(aspectRatio: 0.2,),
              _changeProfilePictureButton(context)
            ],
          ),
        ),
      ),
    );
  }

  Widget _changeProfilePictureButton(BuildContext context){
    return TextButton(
      onPressed: (){
        // TODO: handle gallery modification
      }, 
      child: Text(
        'Change Profile Picture',
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
          color: Theme.of(context).colorScheme.tertiary
        ),
      ) 
    );
  }
}