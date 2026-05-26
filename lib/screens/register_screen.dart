import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'email_confirmation_screen.dart';
import '../screens/home_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _authService = AuthService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  int _step = 0; // 0 = email, 1 = password
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  static const Color _bgColor     = Color(0xFFF0F5EC);
  //static const Color _accentGreen = Color(0xFFB8F5C8);
  //static const Color _textDark    = Color(0xFF2A2A2A);
  static const Color _textMuted   = Color(0xFF888888);

  // ── Validazione password in tempo reale ─────────────────────────────────
  bool get _hasMinLength => _passwordController.text.length >= 8;
  bool get _hasUpperCase => _passwordController.text.contains(RegExp(r'[A-Z]'));
  bool get _hasNumber    => _passwordController.text.contains(RegExp(r'[0-9]'));
  bool get _hasSpecial   => _passwordController.text.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-]'));
  bool get _passwordValid => _hasMinLength && _hasUpperCase && _hasNumber && _hasSpecial;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onNext() {
    if (_step == 0) {
      if (_emailController.text.trim().isEmpty ||
          !_emailController.text.contains('@')) {
        setState(() => _errorMessage = 'Enter a valid email address');
        return;
      }
      setState(() { _step = 1; _errorMessage = null; });
    } else {
      _onRegister();
    }
  }

  void _onBack() {
    if (_step == 1) {
      setState(() { _step = 0; _errorMessage = null; });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _onRegister() async {
    if (!_passwordValid) {
      setState(() => _errorMessage = 'Password does not meet requirements');
      return;
    }
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      await _authService.registerWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => EmailConfirmationScreen(
              email: _emailController.text.trim(),
            ),
          ),
        );
      }
    } on Exception catch (e) {
      setState(() => _errorMessage = _parseError(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _onGooglePressed() async {
    debugPrint('>>> Google button pressed');
    try {
      final result = await _authService.signInWithGoogle();
      debugPrint('>>> Google result: $result');
    } catch (e, st) {
      debugPrint('>>> Google error: $e');
      debugPrint('>>> Stack: $st');
    }

    setState(() => _isLoading = true);
    try {
      final result = await _authService.signInWithGoogle();
      if (result != null && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } on Exception catch (e) {
      setState(() => _errorMessage = _parseError(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /*Future<void> _onMetaPressed() async {
    setState(() => _isLoading = true);
    try {
      final result = await _authService.signInWithMeta();
      if (result != null && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } on Exception catch (e) {
      setState(() => _errorMessage = _parseError(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }*/

  String _parseError(String error) {
  if (error.contains('email-already-in-use')) {
    return 'This email is already registered';
  }
  if (error.contains('weak-password')) {
    return 'Password is too weak';
  }
  if (error.contains('invalid-email')) {
    return 'Invalid email address';
  }
  return 'Something went wrong. Try again.';
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Nav row: back + close ──────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: Color(0xFF2A2A2A), size: 20),
                    onPressed: _onBack,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Color(0xFF2A2A2A), size: 22),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── Titolo dinamico ────────────────────────────
              Text(
                _step == 0 ? 'Enter your email' : 'Set your password',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2A2A2A),
                ),
              ),

              const SizedBox(height: 24),

              // ── Step 0: email ──────────────────────────────
              if (_step == 0) ...[
                _buildEmailStep(),
              ],

              // ── Step 1: password ───────────────────────────
              if (_step == 1) ...[
                _buildPasswordStep(),
              ],

              // ── Errore ─────────────────────────────────────
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: Color(0xFFCC2200),
                    fontSize: 13,
                  ),
                ),
              ],

              const Spacer(),

              // ── Bottone → (solo step 0 mostra anche social) ─
              if (_step == 0) ...[
                const _OrDivider(),
                const SizedBox(height: 16),
                _SocialButton(
                  onPressed: _onGooglePressed,
                  icon: _GoogleIcon(),
                  label: 'Continue with Google',
                ),
                const SizedBox(height: 12),
                  /*_SocialButton(
                  onPressed: _onMetaPressed,
                  icon: _MetaIcon(),
                  label: 'Continue with Meta',
                ),*/
                const SizedBox(height: 24),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmailStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _onNext(),
          autofocus: true,
          style: const TextStyle(fontSize: 15, color: Color(0xFF2A2A2A)),
          decoration: _inputDecoration('email', 'youremail@domain.com'),
        ),
        const SizedBox(height: 16),
        _NextButton(onPressed: _onNext, isLoading: _isLoading),
      ],
    );
  }

  Widget _buildPasswordStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _onNext(),
          onChanged: (_) => setState(() {}),
          autofocus: true,
          style: const TextStyle(fontSize: 15, color: Color(0xFF2A2A2A)),
          decoration: _inputDecoration('password', 'password').copyWith(
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: _textMuted,
                size: 20,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // ── Requisiti password ─────────────────────────────
        _PasswordRule(
          met: _hasMinLength,
          active: _passwordController.text.isNotEmpty,
          text: 'Password must be at least 8 characters long',
        ),
        const SizedBox(height: 8),
        _PasswordRule(
          met: _hasUpperCase,
          active: _passwordController.text.isNotEmpty,
          text: 'Password must have at least 1 upper case letter',
        ),
        const SizedBox(height: 8),
        _PasswordRule(
          met: _hasNumber,
          active: _passwordController.text.isNotEmpty,
          text: 'Password must have at least 1 number',
        ),
        const SizedBox(height: 8),
        _PasswordRule(
          met: _hasSpecial,
          active: _passwordController.text.isNotEmpty,
          text: 'Password must have at least 1 special character',
        ),
        const SizedBox(height: 20),
        _NextButton(
          onPressed: _passwordValid ? _onNext : null,
          isLoading: _isLoading,
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String label, String hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
      labelStyle: const TextStyle(color: Color(0xFF888888), fontSize: 13),
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
    );
  }
}

// ─── Regola password ──────────────────────────────────────────────────────────

class _PasswordRule extends StatelessWidget {
  final bool met;
  final bool active;
  final String text;

  const _PasswordRule({
    required this.met,
    required this.active,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    Color iconColor;
    IconData icon;

    if (!active) {
      icon = Icons.circle_outlined;
      iconColor = Colors.grey.shade400;
    } else if (met) {
      icon = Icons.check_circle;
      iconColor = const Color(0xFF4CAF50);
    } else {
      icon = Icons.cancel;
      iconColor = const Color(0xFFCC2200);
    }

    return Row(
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: !active
                  ? Colors.grey.shade500
                  : met
                      ? const Color(0xFF2A2A2A)
                      : const Color(0xFFCC2200),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Next button circolare ────────────────────────────────────────────────────

class _NextButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool isLoading;

  const _NextButton({required this.onPressed, this.isLoading = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFB8F5C8),
          foregroundColor: const Color(0xFF2A2A2A),
          elevation: 0,
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
          disabledBackgroundColor: const Color(0xFFDDDDDD),
        ),
        child: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.black45),
              )
            : const Icon(Icons.arrow_forward_ios, size: 18),
      ),
    );
  }
}

// ─── Divider OR ───────────────────────────────────────────────────────────────

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider(color: Color(0xFFCCCCCC))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or',
              style: TextStyle(
                  color: Colors.grey.shade500, fontSize: 13)),
        ),
        const Expanded(child: Divider(color: Color(0xFFCCCCCC))),
      ],
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
              borderRadius: BorderRadius.circular(30)),
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

// ─── Icone social ─────────────────────────────────────────────────────────────

class _GoogleIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(width: 24, height: 24,
        child: CustomPaint(painter: _GooglePainter()));
  }
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2;
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = Colors.white);
    final colors = [
      const Color(0xFF4285F4), const Color(0xFF34A853),
      const Color(0xFFFBBC05), const Color(0xFFEA4335),
    ];
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.72);
    double a = -90.0;
    for (int i = 0; i < 4; i++) {
      canvas.drawArc(rect, a * (3.14159 / 180), 90 * (3.14159 / 180), false,
          Paint()..color = colors[i]..style = PaintingStyle.stroke..strokeWidth = r * 0.28);
      a += 90;
    }
    canvas.drawRect(Rect.fromLTWH(cx, cy - r * 0.14, r * 0.72, r * 0.28),
        Paint()..color = Colors.white);
  }
  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}
/*
class _MetaIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      const Icon(Icons.facebook, color: Color(0xFF1877F2), size: 24);
}*/