import 'package:dash/extensions/dash_snackbar.dart';

import 'welcome_page.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final PageController _pageController = PageController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;

  bool _isLengthValid = false;
  bool _hasUppercase = false;
  bool _hasNumber = false;
  bool _hasSpecialChar = false;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(() {
      final text = _passwordController.text;
      setState(() {
        _isLengthValid = text.length >= 8;
        _hasUppercase = text.contains(RegExp(r'[A-Z]'));
        _hasNumber = text.contains(RegExp(r'[0-9]'));
        _hasSpecialChar = text.contains(RegExp(r'[!@#\$&*~]')); 
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // --- FIREBASE LOGIC ---
  Future<void> _createAccount() async {
    if (!_isLengthValid || !_hasUppercase || !_hasNumber || !_hasSpecialChar) {
      context.showErrorSnackBar("The password inserted is not valid, check all mail reqruirement");
      return;
    }

    setState(() => _isLoading = true);

    try {
      UserCredential userCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      await userCredential.user?.sendEmailVerification();

      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.ease);
      
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        context.showErrorSnackBar("This email is already registered");
      } else {
        context.showErrorSnackBar("Error: ${e.message}");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- UI COSTRUZIONE SCHERMATE ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FBF1), 
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF4A5D3F)),
          onPressed: () {
            if (_pageController.page == 1) {
              _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.ease);
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: const Text("Register", style: TextStyle(color: Color(0xFF4A5D3F), fontSize: 16)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(), 
          children: [
            _buildEmailStep(),
            _buildPasswordStep(),
            _buildVerificationStep(),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailStep() {
    return Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Enter your email", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF4A5D3F))),
          const SizedBox(height: 30),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'email',
              hintText: 'youremail@domain.com',
              fillColor: Colors.white,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: FloatingActionButton(
              backgroundColor: const Color(0xFFCDF0B6),
              elevation: 0,
              onPressed: () {
                if (_emailController.text.contains('@') && _emailController.text.isNotEmpty) {
                  _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.ease);
                } else {
                  context.showErrorSnackBar("INsert a valid email");
                }
              },
              child: const Icon(Icons.chevron_right, color: Color(0xFF4A5D3F)),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPasswordStep() {
    bool isAllValid = _isLengthValid && _hasUppercase && _hasNumber && _hasSpecialChar;

    return Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Set your password", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF4A5D3F))),
          const SizedBox(height: 30),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword], // SUGGERIMENTO PER IL SALVATAGGIO AUTOMATICO OS
            decoration: InputDecoration(
              labelText: 'password',
              fillColor: Colors.white,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 20),
          
          // Checklist
          _buildChecklistItem("Password must be at least 8 characters long", _isLengthValid),
          _buildChecklistItem("Password must have at least 1 upper case letter", _hasUppercase),
          _buildChecklistItem("Password must have at least 1 number", _hasNumber),
          _buildChecklistItem("Password must have at least 1 special character", _hasSpecialChar),
          
          const Spacer(),
          
          Align(
            alignment: Alignment.centerRight,
            child: _isLoading 
                ? const CircularProgressIndicator(color: Color(0xFF4A5D3F))
                : FloatingActionButton(
                    backgroundColor: isAllValid ? const Color(0xFFCDF0B6) : Colors.grey.shade300,
                    elevation: 0,
                    onPressed: isAllValid ? _createAccount : null,
                    child: const Icon(Icons.check, color: Color(0xFF4A5D3F)),
                  ),
          )
        ],
      ),
    );
  }

  Widget _buildVerificationStep() {
    return Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.mark_email_read_outlined, size: 100, color: Color(0xFFCDF0B6)),
          const SizedBox(height: 30),
          const Text("Verify your email", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF4A5D3F))),
          const SizedBox(height: 15),
          Text(
            "We've sent a verification link to:\n${_emailController.text}\n\nClick the link to activate your DASH account.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 16),
          ),
          const SizedBox(height: 50),
          SizedBox(
            width: double.infinity,
            height: 55,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFCDF0B6),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
              onPressed: () async {
                setState(() => _isLoading = true);
                try {
                  await FirebaseAuth.instance.currentUser?.reload();
                  final user = FirebaseAuth.instance.currentUser;
                  
                  if (user != null && user.emailVerified) {
                    if (mounted) {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (context) => const WelcomePage()),
                        (route) => false, 
                      );
                    }
                  } else {
                    context.showErrorSnackBar("Email not verified yet. Check your inbox or spam folder!");
                  }
                } catch (e) {
                  context.showErrorSnackBar("Error while verifying the email");
                } finally {
                  if (mounted) setState(() => _isLoading = false);
                }
              },
              child: _isLoading 
                  ? const CircularProgressIndicator(color: Color(0xFF4A5D3F))
                  : const Text("I've verified my email", style: TextStyle(color: Color(0xFF4A5D3F), fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildChecklistItem(String text, bool isValid) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(
            isValid ? Icons.check_circle : Icons.circle,
            color: isValid ? const Color(0xFFCDF0B6) : Colors.grey.shade400,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isValid ? const Color(0xFF4A5D3F) : Colors.grey,
                fontWeight: isValid ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}