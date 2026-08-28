import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/root_screen.dart';
import 'package:dash/screens/public_profile_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'screens/onboarding_page.dart';
import 'services/unit_preferences.dart';
import 'widgets/units_scope.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class DashApp extends StatefulWidget {
  const DashApp({super.key});

  @override
  State<DashApp> createState() => _DashAppState();
}

class _DashAppState extends State<DashApp> {
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });
  }

  void _handleDeepLink(Uri uri) {
    if (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'profile') {
      final sharedUserId = uri.pathSegments[1];

      if (FirebaseAuth.instance.currentUser != null) {

        if(sharedUserId == FirebaseAuth.instance.currentUser!.uid)  return;

        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => PublicProfilePage(userId: sharedUserId),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnitsScope(
      preferences: UnitPreferences.instance,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Dash',
        theme: _buildAppTheme(),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _SplashScreen();
            }
            if (snapshot.hasData) {
              return const RootScreen();
            }
            return const OnboardingScreen();
          },
        ),
      ),
    );
  }

  ThemeData _buildAppTheme() {
    const ResponsiveSpacing responsiveSpacing = ResponsiveSpacing();
    const ResponsiveBorderRadius responsiveBorderRadius = ResponsiveBorderRadius();

    final ColorScheme materialColorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF37693D),
    );
    
    return ThemeData(
      useMaterial3: true,
      colorScheme: materialColorScheme,
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
      iconTheme: const IconThemeData(
        weight: 600,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: materialColorScheme.tertiary,           
        circularTrackColor: materialColorScheme.surfaceContainer,
      ),
    );
  }
}