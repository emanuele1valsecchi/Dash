import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// import '../widgets/profile_avatar_widget.dart'; // re-enable when Storage is set up
import 'home_screen.dart';

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

  // re-enable when Storage is set up
  // String? _profileImageUrl;
  // @override
  // void initState() {
  //   super.initState();
  //   _profileImageUrl = FirebaseAuth.instance.currentUser?.photoURL;
  // }

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please enter a username to continue!"),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Username already taken! Please choose another one."),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      // Atomic write: profile document + nickname claim
      final batch = firestore.batch();

      batch.set(firestore.collection('profiles').doc(user.uid), {
        'username': username,
        'name': _nameController.text.trim(),
        'surname': _surnameController.text.trim(),
        'bio': _bioController.text.trim(),
        'profileImageUrl': '', // re-enable: _profileImageUrl ?? '' when Storage is set up
        'totalPoints': 0,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // nicknames rule requires field named 'uid' (not 'userId')
      batch.set(firestore.collection('nicknames').doc(username), {
        'uid': user.uid,
      });

      await batch.commit();

      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Profile saved successfully!"),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error occurred while saving profile: $e"),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FBF1),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF4A5D3F)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check, color: Color(0xFF4A5D3F)),
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

              // re-enable when Storage is set up:
              // ProfileAvatarWidget(
              //   initialImageUrl: _profileImageUrl,
              //   size: 120,
              //   onImageUploaded: (newUrl) {
              //     setState(() => _profileImageUrl = newUrl);
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       const SnackBar(
              //         content: Text("Profile picture updated!"),
              //         backgroundColor: Color(0xFF4A5D3F),
              //         behavior: SnackBarBehavior.floating,
              //       ),
              //     );
              //   },
              // ),
              // const SizedBox(height: 8),
              // const Text(
              //   "Select Profile Picture",
              //   style: TextStyle(
              //     color: Color(0xFF4A5D3F),
              //     fontWeight: FontWeight.bold,
              //     fontStyle: FontStyle.italic,
              //     fontSize: 12,
              //   ),
              // ),

              const SizedBox(height: 40),

              // --- CAMPI DI TESTO ---
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

              // --- BOTTONE SALVATAGGIO ---
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