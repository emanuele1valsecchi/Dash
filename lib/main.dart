import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/unit_preferences.dart';
import 'widgets/units_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  await GoogleSignIn.instance.initialize();

  // Read the stored unit preferences before the first frame, so the app never
  // paints metric and then corrects itself for a miles user. This is a single
  // local `SharedPreferences` read, not a network call — the Firestore copy is
  // reconciled later, from `HomeScreen.initState`.
  await UnitPreferences.instance.warmUp();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const DashApp());
}

/// Shown for the brief moment while Firebase resolves the cached auth token.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF3F5EE),
      body: Center(child: CircularProgressIndicator(color: Color(0xFF4A8C52))),
    );
  }
}

class DashApp extends StatelessWidget {
  const DashApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Above `MaterialApp` so that changing a unit rebuilds every screen in the
    // navigation stack, not just the one on top — see `UnitsScope`.
    return UnitsScope(
      preferences: UnitPreferences.instance,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Dash',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF37693D)),
        ),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _SplashScreen();
            }
            if (snapshot.hasData) {
              return const HomeScreen();
            }
            return const OnboardingScreen();
          },
        ),
      ),
    );
  }
}
