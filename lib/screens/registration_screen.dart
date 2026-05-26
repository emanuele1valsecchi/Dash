import 'package:dash/screens/welcome_page.dart';
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

  // Variabili per la checklist della password
  bool _isLengthValid = false;
  bool _hasUppercase = false;
  bool _hasNumber = false;
  bool _hasSpecialChar = false;

  @override
  void initState() {
    super.initState();
    // Ascolta ogni volta che l'utente digita la password per aggiornare la checklist
    _passwordController.addListener(() {
      final text = _passwordController.text;
      setState(() {
        _isLengthValid = text.length >= 8;
        _hasUppercase = text.contains(RegExp(r'[A-Z]'));
        _hasNumber = text.contains(RegExp(r'[0-9]'));
        _hasSpecialChar = text.contains(RegExp(r'[!@#\$&*~]')); // Puoi aggiungere altri simboli se vuoi
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

  // --- LOGICA FIREBASE ---
  Future<void> _createAccount() async {
    // Ultimo check di sicurezza
    if (!_isLengthValid || !_hasUppercase || !_hasNumber || !_hasSpecialChar) {
      _showError("Completa tutti i requisiti della password.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Crea l'utente su Firebase
      UserCredential userCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      // 2. Invia l'email di verifica standard di Firebase
      await userCredential.user?.sendEmailVerification();

      // 3. Vai all'ultima schermata (Successo)
      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.ease);
      
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        _showError("Questa email è già registrata.");
      } else {
        _showError("Errore: ${e.message}");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
  }

  // --- UI COSTRUZIONE SCHERMATE ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FBF1), // Il tuo sfondo
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF4A5D3F)),
          onPressed: () {
            // Se siamo alla schermata della password, torna all'email. Altrimenti chiudi.
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
        // PageView ci permette di fare le tre schermate nello stesso widget
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(), // Disabilita lo swipe manuale
          children: [
            _buildEmailStep(),
            _buildPasswordStep(),
            _buildVerificationStep(),
          ],
        ),
      ),
    );
  }

  // STEP 1: INSERISCI EMAIL
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
                  _showError("Inserisci un'email valida.");
                }
              },
              child: const Icon(Icons.chevron_right, color: Color(0xFF4A5D3F)),
            ),
          )
        ],
      ),
    );
  }

  // STEP 2: INSERISCI PASSWORD (con Checklist)
  Widget _buildPasswordStep() {
    // Se la password è valida al 100%, sblocchiamo il pulsante
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

  // STEP 3: SCHERMATA FINALE (Controlla la posta)
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
                  // Forza Firebase a scaricare l'ultimo stato dell'utente
                  await FirebaseAuth.instance.currentUser?.reload();
                  final user = FirebaseAuth.instance.currentUser;
                  
                  if (user != null && user.emailVerified) {
                    // L'utente (o il bot antispam per lui) ha verificato la mail!
                    if (mounted) {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (context) => const WelcomePage()),
                        (route) => false, // Pialla la cronologia
                      );
                    }
                  } else {
                    _showError("Email not verified yet. Check your inbox or spam folder!");
                  }
                } catch (e) {
                  _showError("Errore durante la verifica: $e");
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

  // Widget per la singola riga della checklist
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