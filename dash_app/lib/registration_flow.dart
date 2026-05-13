import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RegistrationFlow extends StatefulWidget {
  const RegistrationFlow({super.key});

  @override
  State<RegistrationFlow> createState() => _RegistrationFlowState();
}

class _RegistrationFlowState extends State<RegistrationFlow> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  // Form data shared across steps
  String _email = '';
  String _password = '';
  String _username = '';
  String _name = '';
  String _surname = '';
  String _bio = '';

  // State management
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Navigate to next step
  void _nextStep() {
    if (_currentStep < 4) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// Navigate to previous step
  void _previousStep() {
    if (_currentStep > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

@override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      // 1. ADDED THE APP BAR FROM FIGMA
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _currentStep > 0
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _previousStep,
              )
            : const BackButton(), // Exits the flow on step 1
        actions: [
          CloseButton(
            onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(), 
        onPageChanged: (index) {
          setState(() {
            _currentStep = index;
            _errorMessage = null; 
          });
        },
        children: [
          // Step 1: Email
          _EmailStep(
            email: _email,
            onEmailChanged: (value) => setState(() => _email = value),
            onNext: _nextStep,
            colorScheme: colorScheme,
            isLoading: _isLoading,
            errorMessage: _errorMessage,
            onErrorCleared: () => setState(() => _errorMessage = null),
            onOAuthSignUp: (provider) => _handleOAuthSignUp(provider),
          ),
          // Step 2: Password (must come before OTP so signUp is called first)
          _PasswordStep(
            password: _password,
            onPasswordChanged: (value) => setState(() => _password = value),
            onNext: () => _handleSignUp(), // Call _handleSignUp which sends confirmation email
            onPrevious: _previousStep,
            onSignUp: () => _handleSignUp(),
            colorScheme: colorScheme,
            isLoading: _isLoading,
            setLoading: (value) => setState(() => _isLoading = value),
            errorMessage: _errorMessage,
            onErrorCleared: () => setState(() => _errorMessage = null),
            onErrorSet: (error) => setState(() => _errorMessage = error),
            email: _email,
          ),
          // Step 3: OTP (after signUp is called)
          _OTPStep(
            email: _email,
            onNext: _nextStep,
            onPrevious: _previousStep,
            colorScheme: colorScheme,
            isLoading: _isLoading,
            setLoading: (value) => setState(() => _isLoading = value),
            errorMessage: _errorMessage,
            onErrorCleared: () => setState(() => _errorMessage = null),
            onErrorSet: (error) => setState(() => _errorMessage = error),
          ),
          // Step 4: Welcome
          _WelcomeStep(
            onNext: _nextStep,
            colorScheme: colorScheme,
          ),
          // Step 5: Profile Setup
          _ProfileSetupStep(
            username: _username,
            onUsernameChanged: (value) => setState(() => _username = value),
            name: _name,
            onNameChanged: (value) => setState(() => _name = value),
            surname: _surname,
            onSurnameChanged: (value) => setState(() => _surname = value),
            bio: _bio,
            onBioChanged: (value) => setState(() => _bio = value),
            onPrevious: _previousStep,
            onComplete: () => _handleProfileSetup(),
            colorScheme: colorScheme,
            isLoading: _isLoading,
            setLoading: (value) => setState(() => _isLoading = value),
            errorMessage: _errorMessage,
            onErrorCleared: () => setState(() => _errorMessage = null),
            onErrorSet: (error) => setState(() => _errorMessage = error),
          ),
        ],
      ),
    );
  }

  /// Handle OAuth sign-up (Google/Facebook)
  Future<void> _handleOAuthSignUp(OAuthProvider provider) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Supabase.instance.client.auth.signInWithOAuth(provider);
      // Navigation handled by AuthGate's stream listener
      if (!mounted) return;
    } on AuthException catch (error) {
      setState(() {
        _errorMessage = error.message;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (error) {
      setState(() {
        _errorMessage = 'OAuth sign-up failed';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('OAuth sign-up failed')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Handle email/password sign-up
  Future<void> _handleSignUp() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await Supabase.instance.client.auth.signUp(
        email: _email.trim(),
        password: _password,
      );

      // Move to welcome screen
      if (mounted) {
        _nextStep();
      }
    } on AuthException catch (error) {
      setState(() {
        _errorMessage = error.message;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (error) {
      setState(() {
        _errorMessage = 'Sign-up failed. Please try again.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign-up failed')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Handle profile setup - update user metadata
  Future<void> _handleProfileSetup() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Create/update the profiles table entry with correct schema
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await Supabase.instance.client.from('profiles').upsert({
          'id': user.id,
          'first_name': _name,
          'last_name': _surname,
          'nickname': _username,
          'avatar_url': '',
        });

        // Initialize user_stats table (required for the user)
        await Supabase.instance.client.from('user_stats').upsert({
          'user_id': user.id,
          'total_distance_meters': 0,
          'total_duration_seconds': 0,
          'max_speed_kmh': 0,
          'longest_run_meters': 0,
          'current_streak_days': 0,
        });
      } else {
        throw Exception('User not authenticated');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile setup complete!')),
        );
        // Navigate back to home via AuthGate
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on AuthException catch (error) {
      setState(() {
        _errorMessage = error.message;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (error) {
      final errorMsg = error.toString();
      print('Profile setup error: $errorMsg');
      setState(() {
        _errorMessage = 'Profile setup failed: $errorMsg';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Profile setup failed: $errorMsg')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}

// ============================================================================
// STEP 1: EMAIL
// ============================================================================
class _EmailStep extends StatefulWidget {
  final String email;
  final Function(String) onEmailChanged;
  final VoidCallback onNext;
  final ColorScheme colorScheme;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onErrorCleared;
  final Function(OAuthProvider) onOAuthSignUp;

  const _EmailStep({
    required this.email,
    required this.onEmailChanged,
    required this.onNext,
    required this.colorScheme,
    required this.isLoading,
    required this.errorMessage,
    required this.onErrorCleared,
    required this.onOAuthSignUp,
  });

  @override
  State<_EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends State<_EmailStep> {
  final TextEditingController _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _emailController.text = widget.email;
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email is required';
    }
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (!emailRegex.hasMatch(value)) {
      return 'Please enter a valid email';
    }
    return null;
  }

  void _proceedToNext() {
    if (_formKey.currentState!.validate()) {
      widget.onEmailChanged(_emailController.text.trim());
      widget.onNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Removed the SafeArea and Stack to match Figma layout exactly
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            // 1. LEFT-ALIGNED MASSIVE TITLE
            Text(
              'Enter your email',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: widget.colorScheme.onSurface,
              ),
              textAlign: TextAlign.left, // Forces left alignment!
            ),
            const SizedBox(height: 40),
            
            if (widget.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: widget.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.errorMessage!,
                    style: TextStyle(color: widget.colorScheme.onErrorContainer),
                  ),
                ),
              ),
              
            TextFormField(
              controller: _emailController,
              enabled: !widget.isLoading,
              validator: _validateEmail,
              decoration: InputDecoration(
                labelText: 'email',
                hintText: 'youremail@domain.com',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.colorScheme.outline, width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.colorScheme.outline, width: 1),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.colorScheme.primary, width: 2),
                ),
                errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.colorScheme.error),
                ),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            
            // 2. INLINE LIGHT-GREEN FAB ALIGNED TO RIGHT
            Align(
              alignment: Alignment.centerRight,
              child: Material(
                color: widget.colorScheme.primaryContainer,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.isLoading ? null : _proceedToNext,
                  child: Padding(
                    padding: const EdgeInsets.all(14.0),
                    child: widget.isLoading 
                      ? SizedBox(
                          width: 20, 
                          height: 20, 
                          child: CircularProgressIndicator(
                            strokeWidth: 2, 
                            color: widget.colorScheme.onPrimaryContainer
                          )
                        )
                      : Icon(
                          Icons.arrow_forward_ios, // The chevron from your Figma
                          size: 18,
                          color: widget.colorScheme.onPrimaryContainer,
                        ),
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 40),
            Row(
              children: [
                Expanded(
                  child: Divider(
                    color: widget.colorScheme.outline,
                    thickness: 1,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(
                    "or",
                    style: TextStyle(color: widget.colorScheme.onSurfaceVariant),
                  ),
                ),
                Expanded(
                  child: Divider(
                    color: widget.colorScheme.outline,
                    thickness: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),
            
            _buildSocialButton(
              "Continue with Google",
              Icons.email,
              () => widget.onOAuthSignUp(OAuthProvider.google),
              widget.colorScheme,
            ),
            const SizedBox(height: 12),
            _buildSocialButton(
              "Continue with Facebook",
              Icons.facebook,
              () => widget.onOAuthSignUp(OAuthProvider.facebook),
              widget.colorScheme,
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Widget _buildSocialButton(
    String text,
    IconData icon,
    VoidCallback onPressed,
    ColorScheme colorScheme,
  ) {
    return OutlinedButton.icon(
      onPressed: widget.isLoading ? null : onPressed,
      icon: Icon(icon, color: colorScheme.onPrimaryContainer),
      label: Text(
        text,
        style: TextStyle(
          color: colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: OutlinedButton.styleFrom(
        backgroundColor: colorScheme.primaryContainer,
        side: BorderSide.none,
        minimumSize: const Size(double.infinity, 45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(25),
        ),
        disabledBackgroundColor: colorScheme.primaryContainer.withOpacity(0.5),
      ),
    );
  }
}

// ============================================================================
// STEP 2: OTP VERIFICATION
// ============================================================================
class _OTPStep extends StatefulWidget {
  final String email;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final ColorScheme colorScheme;
  final bool isLoading;
  final Function(bool) setLoading;
  final String? errorMessage;
  final VoidCallback onErrorCleared;
  final Function(String) onErrorSet;

  const _OTPStep({
    required this.email,
    required this.onNext,
    required this.onPrevious,
    required this.colorScheme,
    required this.isLoading,
    required this.setLoading,
    required this.errorMessage,
    required this.onErrorCleared,
    required this.onErrorSet,
  });

  @override
  State<_OTPStep> createState() => _OTPStepState();
}

class _OTPStepState extends State<_OTPStep> {
  late List<TextEditingController> _otpControllers;
  late List<FocusNode> _focusNodes;

  @override
  void initState() {
    super.initState();
    _otpControllers = List.generate(6, (_) => TextEditingController());
    _focusNodes = List.generate(6, (_) => FocusNode());
  }

  @override
  void dispose() {
    for (var controller in _otpControllers) {
      controller.dispose();
    }
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _handleOTPInput(int index, String value) {
    if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    } else if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
  }

  String _getOTP() {
    return _otpControllers.map((c) => c.text).join();
  }

  Future<void> _verifyOTP() async {
    final otp = _getOTP();
    if (otp.length != 6) {
      widget.onErrorSet('Please enter a valid 6-digit code');
      return;
    }

    widget.setLoading(true);
    try {
      await Supabase.instance.client.auth.verifyOTP(
        token: otp,
        type: OtpType.email,
        email: widget.email,
      );

      if (mounted) {
        widget.onNext();
      }
    } on AuthException catch (error) {
      widget.onErrorSet(error.message);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (error) {
      widget.onErrorSet('OTP verification failed');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verification failed')),
        );
      }
    } finally {
      if (mounted) {
        widget.setLoading(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Text(
            'Verify your email',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: widget.colorScheme.onSurface,
            ),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: 16),
          Text(
            "We've sent you an OTP code at ${widget.email}",
            style: TextStyle(
              fontSize: 14,
              color: widget.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 40),
          if (widget.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.errorMessage!,
                  style: TextStyle(color: widget.colorScheme.onErrorContainer),
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              6,
              (index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SizedBox(
                  width: 45,
                  height: 55,
                  child: TextFormField(
                    controller: _otpControllers[index],
                    focusNode: _focusNodes[index],
                    enabled: !widget.isLoading,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: 1,
                    onChanged: (value) => _handleOTPInput(index, value),
                    decoration: InputDecoration(
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: widget.colorScheme.outline,
                          width: 1,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: widget.colorScheme.outline,
                          width: 1,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: widget.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: widget.colorScheme.primaryContainer,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.isLoading ? null : _verifyOTP,
                child: Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: widget.isLoading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: widget.colorScheme.onPrimaryContainer,
                          ),
                        )
                      : Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                          color: widget.colorScheme.onPrimaryContainer,
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }
}

// ============================================================================
// STEP 3: PASSWORD
// ============================================================================
class _PasswordStep extends StatefulWidget {
  final String password;
  final Function(String) onPasswordChanged;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onSignUp;
  final ColorScheme colorScheme;
  final bool isLoading;
  final Function(bool) setLoading;
  final String? errorMessage;
  final VoidCallback onErrorCleared;
  final Function(String) onErrorSet;
  final String email;

  const _PasswordStep({
    required this.password,
    required this.onPasswordChanged,
    required this.onNext,
    required this.onPrevious,
    required this.onSignUp,
    required this.colorScheme,
    required this.isLoading,
    required this.setLoading,
    required this.errorMessage,
    required this.onErrorCleared,
    required this.onErrorSet,
    required this.email,
  });

  @override
  State<_PasswordStep> createState() => _PasswordStepState();
}

class _PasswordStepState extends State<_PasswordStep> {
  final TextEditingController _passwordController = TextEditingController();
  late bool _isMinLength;
  late bool _hasUppercase;
  late bool _hasNumber;
  late bool _hasSpecialChar;

  @override
  void initState() {
    super.initState();
    _passwordController.text = widget.password;
    // Initialize validation flags directly without setState or callbacks
    final password = widget.password;
    _isMinLength = password.length >= 8;
    _hasUppercase = password.contains(RegExp(r'[A-Z]'));
    _hasNumber = password.contains(RegExp(r'[0-9]'));
    _hasSpecialChar = password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _updateValidation() {
    final password = _passwordController.text;
    setState(() {
      _isMinLength = password.length >= 8;
      _hasUppercase = password.contains(RegExp(r'[A-Z]'));
      _hasNumber = password.contains(RegExp(r'[0-9]'));
      _hasSpecialChar = password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));
    });
    widget.onPasswordChanged(password);
  }

  bool get _isPasswordValid =>
      _isMinLength && _hasUppercase && _hasNumber && _hasSpecialChar;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Text(
            'Set your password',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: widget.colorScheme.onSurface,
            ),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: 40),
          if (widget.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.errorMessage!,
                  style: TextStyle(color: widget.colorScheme.onErrorContainer),
                ),
              ),
            ),
          TextFormField(
            controller: _passwordController,
            enabled: !widget.isLoading,
            obscureText: true,
            onChanged: (_) => _updateValidation(),
            decoration: InputDecoration(
              labelText: 'Password',
              hintText: 'Create a strong password',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: widget.colorScheme.outline, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: widget.colorScheme.outline, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: widget.colorScheme.primary, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: widget.colorScheme.primaryContainer,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: !_isPasswordValid || widget.isLoading ? null : widget.onNext,
                child: Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: widget.isLoading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: widget.colorScheme.onPrimaryContainer,
                          ),
                        )
                      : Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                          color: widget.colorScheme.onPrimaryContainer,
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 30),
          _buildValidationItem(
            'At least 8 characters',
            _isMinLength,
            widget.colorScheme,
          ),
          const SizedBox(height: 12),
          _buildValidationItem(
            'At least 1 uppercase letter',
            _hasUppercase,
            widget.colorScheme,
          ),
          const SizedBox(height: 12),
          _buildValidationItem(
            'At least 1 number',
            _hasNumber,
            widget.colorScheme,
          ),
          const SizedBox(height: 12),
          _buildValidationItem(
            'At least 1 special character',
            _hasSpecialChar,
            widget.colorScheme,
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  Widget _buildValidationItem(
    String text,
    bool isValid,
    ColorScheme colorScheme,
  ) {
    return Row(
      children: [
        Icon(
          isValid ? Icons.check_circle : Icons.cancel,
          color: isValid ? colorScheme.primary : colorScheme.error,
          size: 20,
        ),
        const SizedBox(width: 12),
        Text(
          text,
          style: TextStyle(
            color: isValid ? colorScheme.primary : colorScheme.error,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// STEP 4: WELCOME
// ============================================================================
class _WelcomeStep extends StatelessWidget {
  final VoidCallback onNext;
  final ColorScheme colorScheme;

  const _WelcomeStep({
    required this.onNext,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 80),
          Text(
            'Welcome to the family!',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: colorScheme.onSurface,
            ),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: 16),
          Text(
            "You're almost ready, let's get to know each other!",
            style: TextStyle(
              fontSize: 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 40),
          Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: colorScheme.primaryContainer,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onNext,
                child: Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Icon(
                    Icons.arrow_forward_ios,
                    size: 18,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }
}

// ============================================================================
// STEP 5: PROFILE SETUP
// ============================================================================
class _ProfileSetupStep extends StatefulWidget {
  final String username;
  final Function(String) onUsernameChanged;
  final String name;
  final Function(String) onNameChanged;
  final String surname;
  final Function(String) onSurnameChanged;
  final String bio;
  final Function(String) onBioChanged;
  final VoidCallback onPrevious;
  final VoidCallback onComplete;
  final ColorScheme colorScheme;
  final bool isLoading;
  final Function(bool) setLoading;
  final String? errorMessage;
  final VoidCallback onErrorCleared;
  final Function(String) onErrorSet;

  const _ProfileSetupStep({
    required this.username,
    required this.onUsernameChanged,
    required this.name,
    required this.onNameChanged,
    required this.surname,
    required this.onSurnameChanged,
    required this.bio,
    required this.onBioChanged,
    required this.onPrevious,
    required this.onComplete,
    required this.colorScheme,
    required this.isLoading,
    required this.setLoading,
    required this.errorMessage,
    required this.onErrorCleared,
    required this.onErrorSet,
  });

  @override
  State<_ProfileSetupStep> createState() => _ProfileSetupStepState();
}

class _ProfileSetupStepState extends State<_ProfileSetupStep> {
  late TextEditingController _usernameController;
  late TextEditingController _nameController;
  late TextEditingController _surnameController;
  late TextEditingController _bioController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.username);
    _nameController = TextEditingController(text: widget.name);
    _surnameController = TextEditingController(text: widget.surname);
    _bioController = TextEditingController(text: widget.bio);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    _surnameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _handleComplete() {
    if (_formKey.currentState!.validate()) {
      widget.onUsernameChanged(_usernameController.text.trim());
      widget.onNameChanged(_nameController.text.trim());
      widget.onSurnameChanged(_surnameController.text.trim());
      widget.onBioChanged(_bioController.text.trim());
      widget.onComplete();
    }
  }

  String? _validateUsername(String? value) {
    if (value == null || value.isEmpty) {
      return 'Username is required';
    }
    if (value.length < 3) {
      return 'Username must be at least 3 characters';
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)) {
      return 'Username can only contain letters, numbers, - and _';
    }
    return null;
  }

  String? _validateName(String? value) {
    if (value == null || value.isEmpty) {
      return 'Name is required';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              // Profile picture placeholder
              Center(
                child: CircleAvatar(
                  radius: 50,
                  backgroundColor: widget.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    size: 50,
                    color: widget.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              if (widget.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: widget.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.errorMessage!,
                      style: TextStyle(
                        color: widget.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              TextFormField(
                controller: _usernameController,
                enabled: !widget.isLoading,
                validator: _validateUsername,
                decoration: InputDecoration(
                  labelText: '@username',
                  hintText: 'dashrunner',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.colorScheme.primary, width: 2),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.colorScheme.error),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                enabled: !widget.isLoading,
                validator: _validateName,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'John',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.colorScheme.primary, width: 2),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.colorScheme.error),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _surnameController,
                enabled: !widget.isLoading,
                decoration: InputDecoration(
                  labelText: 'Surname',
                  hintText: 'Doe',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.colorScheme.primary, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _bioController,
                enabled: !widget.isLoading,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Bio',
                  hintText: 'Tell us about yourself...',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.colorScheme.outline,
                      width: 1,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.colorScheme.primary, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: Material(
                  color: widget.colorScheme.primaryContainer,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.isLoading ? null : _handleComplete,
                    child: Padding(
                      padding: const EdgeInsets.all(14.0),
                      child: widget.isLoading
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: widget.colorScheme.onPrimaryContainer,
                              ),
                            )
                          : Icon(
                              Icons.arrow_forward_ios,
                              size: 18,
                              color: widget.colorScheme.onPrimaryContainer,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
