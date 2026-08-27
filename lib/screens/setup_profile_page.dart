import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/profile_avatar_widget.dart';
import 'home_page.dart';

class SetupProfileScreen extends StatefulWidget {
  const SetupProfileScreen({super.key});

  @override
  State<SetupProfileScreen> createState() => _SetupProfileScreenState();
}

class _SetupProfileScreenState extends State<SetupProfileScreen> {
  final _usernameController = TextEditingController();
  final _nameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _bioController = TextEditingController();

  bool _isLoading = false;

  String? _profileImageUrl;

  @override
  void initState() {
    super.initState();
    _profileImageUrl = FirebaseAuth.instance.currentUser?.photoURL;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    _surnameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final username = _usernameController.text.trim();

    if (username.isEmpty) {
      context.showWarningSnackBar("Please enter a username to continue");

      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser!;
      final firestore = FirebaseFirestore.instance;

      // Check username availability before writing
      final nicknameDoc = await firestore.collection('nicknames').doc(username).get();
      if (nicknameDoc.exists) {
        if (mounted) {
          setState(() => _isLoading = false);
          context.showErrorSnackBar("Username already taken! Please choose another one");
        }
        return;
      }

      // Atomic write: profile document + nickname claim
      final batch = firestore.batch();

      // Build the profile data map to update
      final profileData = <String, dynamic>{
        'username': username,
        'name': _nameController.text.trim(),
        'surname': _surnameController.text.trim(),
        'bio': _bioController.text.trim(),
        // Do not overwrite totalPoints or createdAt if the profile already exists!
      };

      // ImageUploadService writes to Storage AND updates the 'profiles'
      // document itself (profileImageUrl + profileImagePath) as soon as
      // the upload succeeds, via ProfileAvatarWidget.onImageUploaded.
      // We still mirror the URL here so it's included in this same atomic
      // batch write, in case the user picked an image right before saving.
      if (_profileImageUrl != null && _profileImageUrl!.isNotEmpty) {
        profileData['profileImageUrl'] = _profileImageUrl!;
      }

      // Use merge: true to avoid destroying existing fields (e.g., fcmTokens, pre-existing profileImageUrl, etc.)
      batch.set(
        firestore.collection('profiles').doc(user.uid),
        profileData,
        SetOptions(merge: true),
      );

      // nicknames rule requires field named 'uid' (not 'userId')
      batch.set(firestore.collection('nicknames').doc(username), {
        'uid': user.uid,
      });

      await batch.commit();

      if (mounted) {
        setState(() => _isLoading = false);
        context.showSuccessSnackBar("Profile saved successfully");
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        context.showErrorSnackBar("Error occurred while saving profile. Try again later");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FBF1),
      appBar: DashNavigationTopBar(
        title: "Setup Profile",
        actions: [
          IconButton(
            icon: Icon(
              Symbols.check, 
              color: Theme.of(context).colorScheme.secondary
            ),
            onPressed: _isLoading ? null : _saveProfile,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),

              ProfileAvatarWidget(
                initialImageUrl: _profileImageUrl,
                size: 120,
                onImageUploaded: (newUrl) {
                  setState(() => _profileImageUrl = newUrl);
                  context.showSuccessSnackBar("Profile picture updated");
                },
              ),
              const SizedBox(height: 8),
              const Text(
                "Select Profile Picture",
                style: TextStyle(
                  color: Color(0xFF4A5D3F),
                  fontWeight: FontWeight.bold,
                  fontStyle: FontStyle.italic,
                  fontSize: 12,
                ),
              ),

              const SizedBox(height: 40),

              // --- TEXT FIELDS ---
              _buildTextField(
                label: "Username",
                hint: "@username",
                controller: _usernameController,
              ),
              const SizedBox(height: 20),

              _buildTextField(
                label: "Name",
                hint: "MyName",
                controller: _nameController,
              ),
              const SizedBox(height: 20),

              _buildTextField(
                label: "Surname",
                hint: "Surname",
                controller: _surnameController,
              ),
              const SizedBox(height: 20),

              _buildTextField(
                label: "Bio",
                hint: "Lorem ipsum dolor sit amet...",
                controller: _bioController,
                maxLines: 4,
              ),

              const SizedBox(height: 40),

              // --- SAVE BUTTON ---
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _saveProfile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFCDF0B6),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(
                          color: Color(0xFF4A5D3F),
                        )
                      : const Text(
                          "Setup your profile",
                          style: TextStyle(
                            color: Color(0xFF4A5D3F),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required String hint,
    required TextEditingController controller,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Color(0xFF4A5D3F)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          color: Colors.grey,
          fontWeight: FontWeight.bold,
        ),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade400),
        alignLabelWithHint: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 20,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Colors.grey, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Color(0xFF4A5D3F), width: 2),
        ),
      ),
    );
  }
}