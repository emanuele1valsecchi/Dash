import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/screens/edit_profile_page.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
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

  @override
  void initState() {
    super.initState();

    _loadProfileData();
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
            padding: EdgeInsets.symmetric(horizontal: elementsPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: sizedBoxDim),
                _buildProfileHeader(),
                SizedBox(height: sizedBoxDim),
                BioTextBox(bio: _bio),
                SizedBox(height: sizedBoxDim),
                _buildActionButtons(),
                SizedBox(height: sizedBoxDim),
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
            final didUpdate = await Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const EditProfilePage()),
            );
            
            if (didUpdate == true) {
              setState(() {
                _isLoading = true;
              });
              await _loadProfileData();
            }
          },
        ),
        Spacer(),
        ProfileActionButton(type: ProfileActionButtonType.share),
        ProfileActionButton(type: ProfileActionButtonType.add)
      ],
    );
  }

  Future<void> _loadProfileData() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Query the 'profiles' collection
      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(user.uid)
          .get();

      if (!doc.exists) return;

      final data = doc.data();
      if (data != null) {
        // Ensure the widget is still in the tree before updating state
        if (!mounted) return;
        
        setState(() {
          // Use a fallback chain for the name just like in HomeScreen
          _name = data['name'] ?? 'No Name';
          _surname = data['surname'];
          _email = data['email'] ?? 'No Email';
          _bio = data['bio'] ?? 'No bio provided.';
          _followers = (data['followers'] as num?)?.toInt() ?? 0;
          _following = (data['following'] as num?)?.toInt() ?? 0;
          _profileImageUrl = data['profileImageUrl'] as String? ?? '';
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading profile: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
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