import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../services/auth_service.dart';
import 'legal_screen.dart';
import 'register_screen.dart';
import '../services/profile_service.dart';
import 'welcome_register_screen.dart';
import '../screens/home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _authService = AuthService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  static const Color _bgColor     = Color(0xFFF0F5EC);
  static const Color _accentGreen = Color(0xFFB8F5C8);
  static const Color _textDark    = Color(0xFF2A2A2A);
  static const Color _textMuted   = Color(0xFF888888);
  static const Color _inputBorder = Color(0xFFCCCCCC);

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onLoginPressed() async {
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _errorMessage = 'Enter email and password');
      return;
    }
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      await _authService.loginWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        await _navigateAfterLogin(context);
      }
    } on Exception catch (e) {
      setState(() => _errorMessage = _parseError(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _onGooglePressed() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final result = await _authService.signInWithGoogle();
      if (result != null && mounted) {
        await _navigateAfterLogin(context);
      }
    } on Exception catch (e) {
      setState(() => _errorMessage = _parseError(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onRegisterTap() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
  }

  void _onTermsTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LegalScreen(type: LegalType.terms),
      ),
    );
  }

  void _onPrivacyTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LegalScreen(type: LegalType.privacy),
      ),
    );
  }

  Future<void> _navigateAfterLogin(BuildContext context) async {
  final profileService = ProfileService();
  final exists = await profileService.profileExists();
  if (!context.mounted) return;
  if (exists) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  } else {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const WelcomeRegisterScreen()),
    );
  }
}

  String _parseError(String error) {
    if (error.contains('user-not-found'))    return 'No account found with this email';
    if (error.contains('wrong-password'))    return 'Incorrect password';
    if (error.contains('invalid-email'))     return 'Invalid email address';
    if (error.contains('too-many-requests')) return 'Too many attempts. Try again later';
    return 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [

              // ── Logo ───────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/IconPlain.png',
                    width: 52, height: 52, fit: BoxFit.contain,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'DASH',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: _textDark,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // ── Tagline ────────────────────────────────────
              const Text(
                'The world is a blank map. Lace up and start drawing your borders. Create an account to claim your first territory today',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: _textDark, height: 1.5),
              ),

              const SizedBox(height: 32),

              // ── Email ──────────────────────────────────────
              _InputField(
                controller: _emailController,
                label: 'email',
                hint: 'youremail@domain.com',
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
              ),

              const SizedBox(height: 14),

              // ── Password ───────────────────────────────────
              _InputField(
                controller: _passwordController,
                label: 'password',
                hint: 'Type your password',
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: _textMuted, size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
                onSubmitted: (_) => _onLoginPressed(),
              ),

              // ── Errore ─────────────────────────────────────
              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: Color(0xFFCC2200), fontSize: 13,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 22),

              // ── Let's go ───────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _onLoginPressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accentGreen,
                    foregroundColor: _textDark,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    disabledBackgroundColor: _accentGreen.withValues(alpha: 0.6),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black54),
                        )
                      : const Text(
                          "Let's go",
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Register link ──────────────────────────────
              RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 14, color: _textDark),
                  children: [
                    const TextSpan(text: 'Are you not registered yet? '),
                    TextSpan(
                      text: 'Register Here',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2E7D32),
                      ),
                      recognizer: TapGestureRecognizer()..onTap = _onRegisterTap,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Divider OR ─────────────────────────────────
              Row(
                children: [
                  const Expanded(child: Divider(color: _inputBorder)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or',
                        style: TextStyle(color: _textMuted, fontSize: 13)),
                  ),
                  const Expanded(child: Divider(color: _inputBorder)),
                ],
              ),

              const SizedBox(height: 20),

              // ── Google ─────────────────────────────────────
              _SocialButton(
                onPressed: _isLoading ? () {} : _onGooglePressed,
                icon: _GoogleIcon(),
                label: 'Continue with Google',
              ),

              const SizedBox(height: 32),

              // ── Terms & Privacy ────────────────────────────
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                      fontSize: 12, color: _textMuted, height: 1.6),
                  children: [
                    const TextSpan(
                        text: 'By continuing, you are agreeing to our '),
                    TextSpan(
                      text: 'Terms of Service',
                      style: const TextStyle(
                        color: _textDark,
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w500,
                      ),
                      recognizer: TapGestureRecognizer()..onTap = _onTermsTap,
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: const TextStyle(
                        color: _textDark,
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w500,
                      ),
                      recognizer: TapGestureRecognizer()..onTap = _onPrivacyTap,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Input Field ──────────────────────────────────────────────────────────────

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final Widget? suffixIcon;
  final ValueChanged<String>? onSubmitted;

  const _InputField({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.next,
    this.suffixIcon,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 15, color: Color(0xFF2A2A2A)),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
        labelStyle: const TextStyle(color: Color(0xFF888888), fontSize: 13),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.6),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFCCCCCC), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF4CAF50), width: 1.5),
        ),
      ),
    );
  }
}

// ─── Social Button ────────────────────────────────────────────────────────────

class _SocialButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Widget icon;
  final String label;

  const _SocialButton({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFD6EDCA),
          foregroundColor: const Color(0xFF2A2A2A),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ─── Google Icon ──────────────────────────────────────────────────────────────

class _GoogleIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24, height: 24,
      child: CustomPaint(painter: _GooglePainter()),
    );
  }
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = Colors.white);

    final colors = [
      const Color(0xFF4285F4),
      const Color(0xFF34A853),
      const Color(0xFFFBBC05),
      const Color(0xFFEA4335),
    ];
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.72);
    double startAngle = -90.0;
    for (int i = 0; i < 4; i++) {
      canvas.drawArc(
        rect,
        startAngle * (3.14159 / 180),
        90 * (3.14159 / 180),
        false,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.28,
      );
      startAngle += 90;
    }
    canvas.drawRect(
      Rect.fromLTWH(cx, cy - r * 0.14, r * 0.72, r * 0.28),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─── Meta Icon ────────────────────────────────────────────────────────────────
/*
class _MetaIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      const Icon(Icons.facebook, color: Color(0xFF1877F2), size: 24);
}*/

