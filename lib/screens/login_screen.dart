import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'registration_screen.dart';


class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}


class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;


  // --- VALIDAZIONE ---
  bool _isInputValid() {
    if (_emailController.text.isEmpty || !_emailController.text.contains('@')) {
      _showError("Inserisci un'email valida");
      return false;
    }
    if (_passwordController.text.length < 6) {
      _showError("La password deve avere almeno 6 caratteri");
      return false;
    }
    return true;
  }


  // --- LOGIN CON EMAIL E PASSWORD ---
  Future<void> signInWithEmail() async {
    if (!_isInputValid()) return;
    setState(() => _isLoading = true);

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'user-not-found':
          _showError("Account non trovato. Registrati prima!");
          break;
        case 'wrong-password':
        case 'invalid-credential': // Firebase Auth v2+ usa questo
          _showError("Credenziali errate. Controlla email e password.");
          break;
        case 'user-disabled':
          _showError("Account disabilitato. Contatta il supporto.");
          break;
        case 'too-many-requests':
          _showError("Troppi tentativi. Riprova tra qualche minuto.");
          break;
        default:
          _showError("Errore: ${e.message}");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // --- LOGIN CON GOOGLE ---
  Future<void> signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn();

      // disconnect() invece di signOut() — più sicuro, silent fail se non serve
      try {
        await googleSignIn.disconnect();
      } catch (_) {}

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();

      // L'utente ha chiuso il popup senza scegliere
      if (googleUser == null) return;

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Controllo esplicito: se i token sono null non proseguire
      if (googleAuth.accessToken == null || googleAuth.idToken == null) {
        _showError("Errore nel recupero del token Google. Riprova.");
        return;
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);

    } catch (e) {
      _showError("Errore Google: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // --- LOGIN CON FACEBOOK ---
  Future<void> signInWithFacebook() async {
    setState(() => _isLoading = true);
    try {
      final LoginResult result = await FacebookAuth.instance.login();

      switch (result.status) {
        case LoginStatus.success:
          final accessToken = result.accessToken;

          if (accessToken == null) {
            _showError("Token Facebook non disponibile. Riprova.");
            return;
          }
          
          final OAuthCredential credential =
              FacebookAuthProvider.credential(accessToken.tokenString);

          await FirebaseAuth.instance.signInWithCredential(credential);
          // ✅ Nessun Navigator: AuthGate gestisce la navigazione
          break;

        case LoginStatus.cancelled:
          // L'utente ha annullato — non mostrare errore
          break;

        case LoginStatus.failed:
          _showError("Errore Facebook: ${result.message}");
          break;

        default:
          _showError("Stato Facebook sconosciuto: ${result.status}");
      }

    } catch (e) {
      _showError("Errore imprevisto Facebook: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // --- HELPER ERRORI ---
  void _showError(String message) {
    debugPrint("[LoginScreen] $message");
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }


  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FBF1),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              children: [
                const SizedBox(height: 40),
                Image.asset('assets/images/IconPlain.png', height: 80),
                const Text(
                  "DASH",
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    color: Color(0xFF4A5D3F),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "The world is a blank map. Lace up and start drawing your borders. Login with your Dash account",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 40),

                // --- CAMPO EMAIL ---
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'email',
                    hintText: 'youremail@domain.com',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // --- CAMPO PASSWORD ---
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'password',
                    hintText: 'Type your password',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                // --- BOTTONE LOGIN ---
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : signInWithEmail,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFCDF0B6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.black)
                        : const Text(
                            "Let's go",
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 15),

                // --- LINK REGISTRAZIONE ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Are you not registered yet? ",
                      style: TextStyle(color: Colors.black54),
                    ),
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const RegistrationScreen(),
                          ),
                        );
                      },
                      child: const Text(
                        "Register Here",
                        style: TextStyle(
                          color: Color(0xFF4A5D3F),
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 30),
                const Text("— or —", style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 20),

                // --- SOCIAL BUTTONS ---
                _socialButton(
                  "Continue with Google",
                  Icons.g_mobiledata,
                  signInWithGoogle,
                ),
                _socialButton(
                  "Continue with Facebook",
                  Icons.facebook,
                  signInWithFacebook,
                ),

                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _socialButton(
    String text,
    IconData iconData,
    VoidCallback onPressed,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: OutlinedButton.icon(
        onPressed: _isLoading ? null : onPressed,
        icon: Icon(iconData, size: 28, color: Colors.black87),
        label: Text(
          text,
          style: const TextStyle(color: Colors.black87, fontSize: 16),
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 55),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(25),
          ),
          backgroundColor: const Color(0xFFE8F5D6),
          side: BorderSide.none,
        ),
      ),
    );
  }
}