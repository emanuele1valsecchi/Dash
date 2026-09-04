import 'dart:async';

import 'package:dash/utils/profile_navigator.dart';

import 'config/app_theme.dart';

import 'package:dash/root_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'screens/onboarding_page.dart';
import 'services/unit_preferences.dart';
import 'widgets/units_scope.dart';
import 'services/profile_service.dart';
import 'screens/welcome_register_page.dart';
import 'screens/email_confirmation_page.dart';

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

class _DashAppState extends State<DashApp> with WidgetsBindingObserver {
  Uri? _pendingDeepLinkUri;
  Uri? _lastProcessedUri;
  DateTime? _lastProcessedTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    final String initialRoute = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (initialRoute != '/' && initialRoute.isNotEmpty) {
      _pendingDeepLinkUri = Uri.tryParse(initialRoute);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    if (_pendingDeepLinkUri != null) {
      final uri = _pendingDeepLinkUri!;
      _pendingDeepLinkUri = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _processDeepLink(uri);
      });
    }
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final uri = routeInformation.uri;
    if (uri.path != '/' && uri.path.isNotEmpty) {
      
      if (_lastProcessedUri == uri && _lastProcessedTime != null) {
        final difference = DateTime.now().difference(_lastProcessedTime!);
        if (difference.inMilliseconds < 1000) {
          return true;
        }
      }

      _lastProcessedUri = uri;
      _lastProcessedTime = DateTime.now();

      _processDeepLink(uri);
      return true;
    }
    return false;
  }

  void _processDeepLink(Uri uri) {
    if (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'profile') {
      final sharedUserId = uri.pathSegments[1];

      if (FirebaseAuth.instance.currentUser != null) {
        final context = navigatorKey.currentContext;
        
        if (context != null) {
          ProfileNavigation.openProfile(context, sharedUserId);
        }
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
        theme: buildAppTheme(),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _SplashScreen();
            }

            final user = snapshot.data;

            if (user == null) {
              return const OnboardingScreen();
            }

            if (!user.emailVerified) {
              return EmailConfirmationScreen(email: user.email ?? '');
            }

            return const _ProfileGate();
          },
        ),
      ),
    );
  }

}

class _ProfileGate extends StatelessWidget {
  const _ProfileGate();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: ProfileService().isProfileComplete(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SplashScreen();
        }

        final profileExists = snapshot.data ?? false;

        if (!profileExists) {
          return const WelcomeRegisterScreen();
        }

        return const RootScreen();
      },
    );
  }
}