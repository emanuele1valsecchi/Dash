import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/profile_service.dart';
import 'welcome_register_screen.dart';
import '../screens/home_screen.dart';

class EmailConfirmationScreen extends StatefulWidget {
  final String email;

  const EmailConfirmationScreen({
    super.key,
    required this.email,
  });

  @override
  State<EmailConfirmationScreen> createState() =>
      _EmailConfirmationScreenState();
}

class _EmailConfirmationScreenState extends State<EmailConfirmationScreen> {
  bool _isChecking = false;
  bool _isResending = false;

  // ── Naviga dopo login: primo accesso → WelcomeRegister, altrimenti Home ──
  Future<void> _navigateAfterLogin(BuildContext context) async {
    final profileService = ProfileService();
    final exists = await profileService.isProfileComplete();

    if (!context.mounted) return;

    if (exists) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const WelcomeRegisterScreen(),
        ),
      );
    }
  }

  Future<void> _checkEmailVerified() async {
    setState(() => _isChecking = true);

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No user is currently logged in')),
        );
        return;
      }

      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (!mounted) return;

      if (refreshedUser != null && refreshedUser.emailVerified) {
        await _navigateAfterLogin(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Email not verified yet. Check your inbox again.'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Verification check failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  Future<void> _resendVerificationEmail() async {
    setState(() => _isResending = true);

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No user is currently logged in')),
        );
        return;
      }

      await user.sendEmailVerification();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification email sent again')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not resend email: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F5EC),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.mark_email_unread_outlined,
                  size: 72,
                  color: Color(0xFF2E7D32),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Check your inbox!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2A2A2A),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'We sent you a confirmation mail at \n${widget.email}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF666666),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isChecking ? null : _checkEmailVerified,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB8F5C8),
                      foregroundColor: const Color(0xFF2A2A2A),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: _isChecking
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black54,
                            ),
                          )
                        : const Text(
                            "I've confirmed my email",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 14),

                TextButton(
                  onPressed: _isResending ? null : _resendVerificationEmail,
                  child: _isResending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Resend email',
                          style: TextStyle(
                            color: Color(0xFF2E7D32),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}