import 'package:dash/screens/edit_profile_page.dart';
import 'package:dash/widgets/dash_navigation_bar.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.sizeOf(context).height;
    final double sizedBoxDim =  screenHeight * 0.02;
    final double elementsPadding = screenHeight * 0.02;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              Symbols.settings_rounded, 
              color: Theme.of(context).colorScheme.secondary),
            onPressed: () {
              // TODO: add settings
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: elementsPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: sizedBoxDim),
            _buildProfileHeader(),
            SizedBox(height: sizedBoxDim),
            BioTextBox(bio: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit.'),
            SizedBox(height: sizedBoxDim),
            _buildActionButtons(),
            SizedBox(height: sizedBoxDim),
          ],
        ),
      ),
      bottomNavigationBar: DashNavigationbar(),
    );
  }

  // --- WIDGET COMPONENTS ---

  Widget _buildProfileHeader() {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double screenHeight = MediaQuery.sizeOf(context).height;

    return Row(
      children: [
        ProfilePictureAvatar(),
        SizedBox(width: screenWidth * 0.08),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Name Surname",
                style: Theme.of(context).textTheme.headlineSmall),
              Text(
                "lamiaemail@polimi.it",
                style: Theme.of(context).textTheme.labelLarge!.copyWith(color: Theme.of(context).colorScheme.outline)
              ),
              SizedBox(height: screenHeight * 0.02),
              Row(
                children: [
                  _buildFollowersCount('10k', 'Followers'),
                  _buildFollowersCount('1000', 'Following'),
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
        ProfileActionButton(type: ProfileActionButtonType.edit),
        Spacer(),
        ProfileActionButton(type: ProfileActionButtonType.share),
        ProfileActionButton(type: ProfileActionButtonType.add)
      ],
    );
  }
}

class BioTextBox extends StatefulWidget {
  final String bio;

  const BioTextBox({super.key, required this.bio});

  @override
  State<BioTextBox> createState() => _BioTextBoxState();
}

class _BioTextBoxState extends State<BioTextBox> {
  final ScrollController _bioScrollController = ScrollController();

  _BioTextBoxState();

  @override
  void dispose() {
    // 2. Clean it up when the widget is destroyed
    _bioScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.sizeOf(context).height; 
    final double screenWidth = MediaQuery.sizeOf(context).width; 

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.16, // Maximum height before scrolling begins
      ),
      child: Scrollbar(
        controller: _bioScrollController,
        thumbVisibility: true,
        thickness: screenWidth * 0.02,
        radius: Radius.circular(screenHeight),
        child: SingleChildScrollView(
          controller: _bioScrollController,
          child: Padding(
            padding: EdgeInsets.only(right: screenWidth * 0.04),
            child: Text(
              widget.bio,
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: Theme.of(context).colorScheme.outline
              )), 
            ),
        ),
      )
    );
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
  
  const ProfileActionButton({super.key, required this.type});

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
        onPressed: () => type.action(context),
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
      onPressed: () => type.action(context),
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