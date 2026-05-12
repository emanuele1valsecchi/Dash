import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'welcome_screen.dart';
import 'home_screen.dart';

/// AuthGate determines whether to show the login screen or the home screen
/// based on the current user's authentication status.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // Handle loading state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // Handle error state
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text('Error: ${snapshot.error}'),
            ),
          );
        }

        // Check if user is authenticated
        final session = snapshot.data?.session;

        // Show LoginScreen if no session, otherwise show HomeScreen
        if (session == null) {
          return const WelcomeScreen();
        }

        // Show HomeScreen when user is authenticated
        return const HomeScreen();
      },
    );
  }
}
