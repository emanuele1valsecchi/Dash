import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/dash_text_form_field.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dash/utils/strings_utils.dart';
import '../services/image_upload_service.dart';

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

  // No longer need a local File — ImageUploadService.pickAndUpload()
  // does its own picking AND uploads straight to Storage, returning
  // the final download URL. Keeping only the URL avoids the earlier bug
  // where the picked File was shown locally but never actually uploaded.
  String? _existingImageUrl;
  bool _isLoading = true;
  bool _isUploadingImage = false;

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
            icon: Icon(Symbols.check_rounded),
          ),
        ],
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
                      // imageFile removed: the avatar now always shows
                      // the current remote URL, updated only after a
                      // successful upload. See _pickAndUploadImage().
                      imageFile: null,
                      imageUrl: _existingImageUrl,
                      initialNameSurname: getFirstLetters(
                        _nameController.text,
                        _surnameController.text,
                      ),
                    ),
                    if (_isUploadingImage)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    _changeProfilePictureButton(context),
                    SizedBox(height: MediaQuery.heightOf(context) * 0.04),
                    UserDataForm(
                      formKey: _formKey,
                      nameController: _nameController,
                      surnameController: _surnameController,
                      bioController: _bioController,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _saveProfileChanges() async {
    if (_formKey.currentState!.validate()) {
      try {
        final user = FirebaseAuth.instance.currentUser!;
        final firestore = FirebaseFirestore.instance;

        final batch = firestore.batch();

        // profileImageUrl is intentionally NOT written here: it's already
        // saved directly by ImageUploadService as soon as the upload
        // succeeds (see _pickAndUploadImage), so this save only needs
        // to persist the text fields.
        batch.update(firestore.collection('profiles').doc(user.uid), {
          'name': _nameController.text.trim(),
          'surname': _surnameController.text.trim(),
          'bio': _bioController.text.trim(),
        });

        await batch.commit();

        if (mounted) {
          context.showSuccessSnackBar("Profile saved successfully!");
          Navigator.pop(context, true);
        }
      } catch (e) {
        if (mounted) {
          context.showErrorSnackBar("Error occurred while saving profile");
        }
      }
    }
  }

  Widget _changeProfilePictureButton(BuildContext context) {
    return TextButton(
      onPressed: _isUploadingImage
          ? null
          : () => _showImageSourceActionSheet(context),
      child: Text(
        'Change Profile Picture',
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              color: Theme.of(context).colorScheme.tertiary,
            ),
      ),
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
                onTap: () => _pickAndUploadImage(ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Symbols.camera_alt_rounded),
                title: const Text('Take a Picture'),
                onTap: () => _pickAndUploadImage(ImageSource.camera),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Picks AND uploads in one step, using the same ImageUploadService
  /// already used successfully during registration. This is the fix:
  /// the previous version only picked a local File and never uploaded
  /// it, so profileImageUrl in Firestore was never updated.
  Future<void> _pickAndUploadImage(ImageSource source) async {
    if (context.mounted) {
      Navigator.pop(context); // close the bottom sheet immediately
    }

    setState(() => _isUploadingImage = true);

    final String? uploadedUrl = await ImageUploadService.pickAndUpload(
      source: source,
      onError: (err) {
        if (!mounted) return;
        context.showErrorSnackBar("An error occurred while loading the image, please try again");
      },
    );

    if (!mounted) return;
    setState(() => _isUploadingImage = false);

    if (uploadedUrl != null) {
      // ImageUploadService already wrote profileImageUrl/profileImagePath
      // to Firestore internally, so this setState only refreshes the
      // preview shown on this screen.
      setState(() => _existingImageUrl = uploadedUrl);
      context.showSuccessSnackBar("Profile picture updated!");
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
  final GlobalKey<FormState> formKey;
  final TextEditingController nameController;
  final TextEditingController surnameController;
  final TextEditingController bioController;

  const UserDataForm({
    super.key,
    required this.formKey,
    required this.nameController,
    required this.surnameController,
    required this.bioController,
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
          SizedBox(height: MediaQuery.heightOf(context) * 0.04),
          DashTextFormField(
            label: 'Surname',
            clearOption: true,
            controller: surnameController,
            validator: _textFormFieldValidator,
          ),
          SizedBox(height: MediaQuery.heightOf(context) * 0.04),
          DashTextFormField(
            label: 'Bio',
            largeText: true,
            clearOption: true,
            controller: bioController,
          ),
        ],
      ),
    );
  }

  String? _textFormFieldValidator(String? content) {
    if (content == null || content.trim().isEmpty) {
      return 'This field cannot be empty';
    }

    final RegExp nameRegExp = RegExp(r'^[\p{L}\s]+$', unicode: true);

    if (!nameRegExp.hasMatch(content)) {
      return 'Only letters and spaces are allowed';
    }

    return null;
  }
}