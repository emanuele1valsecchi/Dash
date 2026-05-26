import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/profile_service.dart';
import '../screens/home_screen.dart';

class UserSetupScreen extends StatefulWidget {
  const UserSetupScreen({super.key});

  @override
  State<UserSetupScreen> createState() => _UserSetupScreenState();
}

class _UserSetupScreenState extends State<UserSetupScreen> {
  final _profileService = ProfileService();
  final _usernameCtrl   = TextEditingController();
  final _nameCtrl       = TextEditingController();
  final _surnameCtrl    = TextEditingController();
  final _bioCtrl        = TextEditingController();

  File? _profileImage;
  bool  _isLoading       = false;
  String? _errorMessage;

  static const Color _bg      = Color(0xFFF5F6F0);
  static const Color _accent  = Color(0xFFB8F5C8);
  static const Color _textDark = Color(0xFF2A2A2A);
  //static const Color _border  = Color(0xFFCCCCCC);

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _nameCtrl.dispose();
    _surnameCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 75,
      maxWidth: 512,
    );
    if (picked != null) {
      setState(() => _profileImage = File(picked.path));
    }
  }

  Future<void> _onSetupPressed() async {
    final username = _usernameCtrl.text.trim();
    final name     = _nameCtrl.text.trim();
    final surname  = _surnameCtrl.text.trim();

    if (username.isEmpty || name.isEmpty || surname.isEmpty) {
      setState(() => _errorMessage = 'Username, name and surname are required');
      return;
    }
    if (username.length < 3) {
      setState(() => _errorMessage = 'Username must be at least 3 characters');
      return;
    }

    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      // Controlla unicità username
      final taken = await _profileService.isUsernameTaken(username);
      if (taken) {
        setState(() => _errorMessage = 'Username already taken, choose another');
        return;
      }

      // Crea profilo su Firestore
      await _profileService.createProfile(
        username:     username,
        name:         name,
        surname:      surname,
        bio:          _bioCtrl.text.trim(),
        profileImage: _profileImage,
      );

      // Salva nickname nella collection separata
      await _profileService.saveNickname(username);

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }

    } catch (e) {
      setState(() => _errorMessage = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [

            // ── AppBar manuale ──────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: _textDark, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  // Spunta salva
                  IconButton(
                    icon: Icon(
                      Icons.check,
                      color: _isLoading
                          ? Colors.grey
                          : const Color(0xFF2E7D32),
                      size: 24,
                    ),
                    onPressed: _isLoading ? null : _onSetupPressed,
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 8),
                child: Column(
                  children: [

                    // ── Avatar ────────────────────────────────
                    GestureDetector(
                      onTap: _pickImage,
                      child: Column(
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              color: const Color(0xFFDDD8F0),
                              shape: BoxShape.circle,
                              image: _profileImage != null
                                  ? DecorationImage(
                                      image: FileImage(_profileImage!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: _profileImage == null
                                ? const Icon(
                                    Icons.person_outline_rounded,
                                    size: 52,
                                    color: Color(0xFF7B68C8),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Select Profile Picture',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF666666),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // ── Username ──────────────────────────────
                    _FormField(
                      controller: _usernameCtrl,
                      label: 'Username',
                      hint: '@username',
                      textInputAction: TextInputAction.next,
                    ),

                    const SizedBox(height: 14),

                    // ── Name ──────────────────────────────────
                    _FormField(
                      controller: _nameCtrl,
                      label: 'Name',
                      hint: 'MyName',
                      textInputAction: TextInputAction.next,
                    ),

                    const SizedBox(height: 14),

                    // ── Surname ───────────────────────────────
                    _FormField(
                      controller: _surnameCtrl,
                      label: 'Surname',
                      hint: 'Surname',
                      textInputAction: TextInputAction.next,
                    ),

                    const SizedBox(height: 14),

                    // ── Bio ───────────────────────────────────
                    _FormField(
                      controller: _bioCtrl,
                      label: 'Bio',
                      hint: 'Tell something about yourself...',
                      maxLines: 4,
                      textInputAction: TextInputAction.done,
                    ),

                    // ── Errore ────────────────────────────────
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFFCC2200),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 28),

                    // ── Bottone ───────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _onSetupPressed,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: const Color(0xFF1A3A2A),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          disabledBackgroundColor:
                              _accent.withValues(alpha: 0.5),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 22, height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black45),
                              )
                            : const Text(
                                'Setup your profile',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Form Field ───────────────────────────────────────────────────────────────

class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  final TextInputAction textInputAction;

  const _FormField({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
    this.textInputAction = TextInputAction.next,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textInputAction: textInputAction,
      style: const TextStyle(
        fontSize: 15,
        color: Color(0xFF2A2A2A),
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(
            color: Color(0xFFAAAAAA), fontSize: 14),
        labelStyle: const TextStyle(
            color: Color(0xFF888888), fontSize: 13),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.7),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
              color: Color(0xFFCCCCCC), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
              color: Color(0xFF4CAF50), width: 1.5),
        ),
      ),
    );
  }
}