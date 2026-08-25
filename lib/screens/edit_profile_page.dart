import 'dart:io';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_text_form_field.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/utils/strings_utils.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _bioController = TextEditingController();

  File? _profileImage;
  String? _existingImageUrl;
  bool _isLoading = true;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadCurrentProfile(); // Fetch data when page opens
  }

  @override
  void dispose() {
    _nameController.dispose();
    _surnameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: 'Edit profile',
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _saveProfileChanges, 
            tooltip: 'Confirm changes',
            icon: Icon(Symbols.check_rounded)
        )],
      ),
      body: _isLoading 
        ? Center(
            child: CircularProgressIndicator(
              color: Theme.of(context).colorScheme.primary,
            ),
          )
        : Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ProfilePictureAvatar(
                    aspectRatio: 0.2, 
                    imageFile : _profileImage,
                    imageUrl: _existingImageUrl,
                    initialNameSurname: getFirstLetters(_nameController.text, _surnameController.text),
                  ),
                  _changeProfilePictureButton(context),
                  SizedBox( height: MediaQuery.heightOf(context) * 0.04, ),
                  UserDataForm(
                    formKey: _formKey, 
                    nameController : _nameController, 
                    surnameController : _surnameController,
                    bioController : _bioController,
                  )
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _saveProfileChanges() async {
    if (_formKey.currentState!.validate()) {
      final String name = _nameController.text.trim();
      
      try{
        final user = FirebaseAuth.instance.currentUser!;
        final firestore = FirebaseFirestore.instance;

        final batch = firestore.batch();

        batch.update(firestore.collection('profiles').doc(user.uid), {
          'name': _nameController.text.trim(),
          'surname': _surnameController.text.trim(),
          'bio': _bioController.text.trim(),
        });

        await batch.commit();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Profile saved successfully!"),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              behavior: SnackBarBehavior.floating,
            ),
          );
          Navigator.pop(context, true);
        }
      } catch( e ){
        if (mounted){
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Error occurred while saving profile: $e"),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  Widget _changeProfilePictureButton(BuildContext context){
    return TextButton(
      onPressed: () => _showImageSourceActionSheet(context), 
      child: Text(
        'Change Profile Picture',
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
          color: Theme.of(context).colorScheme.tertiary
        ),
      ) 
    );
  }

  void _showImageSourceActionSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Symbols.photo_library_rounded),
                title: const Text('Choose from Gallery'),
                onTap: () => _pickImage(ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Symbols.camera_alt_rounded),
                title: const Text('Take a Picture'),
                onTap: () => _pickImage(ImageSource.camera),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(source: source);
      
      if (pickedFile != null) {
        setState(() {
          _profileImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error picking image: $e"),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    
    if (context.mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _loadCurrentProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final doc = await FirebaseFirestore.instance
            .collection('profiles')
            .doc(user.uid)
            .get();

        if (doc.exists) {
          final data = doc.data()!;
          if (mounted) {
            setState(() {
              _nameController.text = data['name'] ?? '';
              _surnameController.text = data['surname'] ?? '';
              _bioController.text = data['bio'] ?? '';
              _existingImageUrl = data['profileImageUrl'] as String?;
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Error loading profile data: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}


class UserDataForm extends StatelessWidget {
  final GlobalKey<FormState>  formKey;
  final TextEditingController nameController;
  final TextEditingController surnameController;
  final TextEditingController bioController;
  
  const UserDataForm({
    super.key, 
    required this.formKey, 
    required this.nameController, 
    required this.surnameController, 
    required this.bioController
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        children: <Widget>[
          DashTextFormField(
            label: 'Name', 
            clearOption: true,
            controller: nameController,
            validator: _textFormFieldValidator,
          ),
          SizedBox(height: MediaQuery.heightOf(context) * 0.04,),
          DashTextFormField(
            label: 'Surname', 
            clearOption: true,
            controller: surnameController,
            validator: _textFormFieldValidator,
          ),
          SizedBox(height: MediaQuery.heightOf(context) * 0.04,),
          DashTextFormField(
            label: 'Bio',
            largeText: true,
            clearOption: true,
            controller: bioController,),
        ],
      ),
    );
  }

  String? _textFormFieldValidator(String? content){
    if (content == null || content.trim().isEmpty) {
      return 'This field cannot be empty';
    }

    final RegExp nameRegExp = RegExp(r'^[\p{L}\s]+$', unicode: true);
    
    if(!nameRegExp.hasMatch(content)){
      return 'Only letters and spaces are allowed';
    }

    return null;
  }
}

