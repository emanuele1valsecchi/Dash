import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  await GoogleSignIn.instance.initialize();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

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
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class DashApp extends StatelessWidget {
  const DashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dash',
      theme: _buildAppTheme(context),
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
    );
  }

  ThemeData _buildAppTheme(BuildContext context){
    const ResponsiveSpacing responsiveSpacing = ResponsiveSpacing();
    const ResponsiveBorderRadius responsiveBorderRadius = ResponsiveBorderRadius();
    
    return ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(0xFF37693D),
        ),
        extensions: const [
          responsiveSpacing,
          responsiveBorderRadius,
        ],
        
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(responsiveBorderRadius.md), 
          ),
        ),
        
        dialogTheme: DialogThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(responsiveBorderRadius.lg),
          ),
        ),
        
        bottomSheetTheme: BottomSheetThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(responsiveBorderRadius.xl),
            ),
          ),
        ),

        progressIndicatorTheme: ProgressIndicatorThemeData(
          color: Theme.of(context).colorScheme.tertiary,           
          circularTrackColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      );
  }
}
