import 'package:dash/screens/map_units_page.dart';
import 'package:dash/screens/personal_information_page.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'login_page.dart';
import 'legal_page.dart';
import 'notification_settings_page.dart';
import 'home_leaderboards_settings_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _handleLogout(BuildContext context) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Log out'),
          content: const Text('Are you sure you want to log out?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF4A8C52))),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Log out', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      // 1. Scollega l'utente da Firebase
      await FirebaseAuth.instance.signOut();
      
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const LoginScreen(), // <-- Corretto qui!
          ),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Settings"
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          
          // --- SEZIONE ACCOUNT ---
          _buildSectionHeader(context, 'ACCOUNT'),
          _buildSettingsTile(
            context,
            icon: Symbols.person_rounded,
            title: 'Personal Information',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PersonalInformationPage()),
              );
            },
          ),
          _buildSettingsTile(
            context,
            icon: Symbols.lock_rounded,
            title: 'Privacy Policy',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const LegalScreen(type: LegalType.privacy),
                ),
              );
            },
          ),

          const SizedBox(height: 16),

          // --- SEZIONE PREFERENZE ---
          _buildSectionHeader(context, 'PREFERENCES'),
          _buildSettingsTile(
            context,
            icon: Symbols.notifications_rounded,
            title: 'Notifications',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const NotificationSettingsPage(),
                ),
              );
            },
          ),
          _buildSettingsTile(
            context,
            icon: Symbols.map_rounded,
            title: 'Map & Units',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const MapUnitsPage()),
              );
            },
          ),
          _buildSettingsTile(
            context,
            icon: Symbols.dashboard_customize_rounded,
            title: 'Home Leaderboards',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const HomeLeaderboardsSettingsPage(),
                ),
              );
            },
          ),

          const SizedBox(height: 24),
          const Divider(thickness: 1, height: 1),
          const SizedBox(height: 8),

          // --- LOGOUT ---
          ListTile(
            leading: const Icon(Symbols.logout_rounded, color: Colors.redAccent),
            title: const Text(
              'Log out',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () => _handleLogout(context),
          ),
        ],
      ),
    );
  }

  // --- HELPER WIDGETS ---

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(icon, color: Theme.of(context).colorScheme.secondary),
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: Theme.of(context).colorScheme.outline,
        size: 22,
      ),
      onTap: onTap,
    );
  }
}