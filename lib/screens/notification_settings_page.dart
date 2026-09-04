import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class NotificationSettingsPage extends StatefulWidget {
  /// Test seams. Production leaves both null and the state resolves
  /// `.instance` lazily — the previous eager field initializers threw
  /// `[core/no-app]` when the widget was *constructed*, before `runApp`.
  @visibleForTesting
  final FirebaseFirestore? firestore;
  @visibleForTesting
  final FirebaseAuth? auth;

  const NotificationSettingsPage({
    super.key,
    this.firestore,
    this.auth,
  });

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;
  late final FirebaseAuth _auth = widget.auth ?? FirebaseAuth.instance;
  late final String _currentUserId = _auth.currentUser?.uid ?? '';
  
  bool _isLoading = true;

  // Local map to manage switch states. 
  // By default, we set everything to true (active).
  final Map<String, bool> _preferences = {
    'newFollower': true,
    'newRoutePublished': true,
    'routeSaved': true,
    'routeRunFaster': true,
    'leaderboardOvertake': true,
    'leaderboardCityEntry': true,
    'leaderboardGlobalEntry': true,
    'areaStolen': true,
    'badgeUnlocked': true,
  };

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  // Reads preferences saved on Firestore
  Future<void> _loadPreferences() async {
    // Stop loading before returning, not just `return`: the early exit is
    // above the `try`, so its `finally` never runs and the page would sit on
    // its spinner forever. There is nothing to fetch without a user, but
    // there is also nothing to wait for.
    if (_currentUserId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final doc = await _db.collection('profiles').doc(_currentUserId).get();
      if (doc.exists && doc.data()!.containsKey('pushPreferences')) {
        final Map<String, dynamic> savedPrefs = doc.data()!['pushPreferences'];
        
        setState(() {
          savedPrefs.forEach((key, value) {
            if (_preferences.containsKey(key)) {
              _preferences[key] = value as bool;
            }
          });
        });
      }
    } catch (e) {
      debugPrint("Error loading preferences: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // Updates the local state and saves the change to Firestore in real-time
  Future<void> _updatePreference(String key, bool value) async {
    setState(() {
      _preferences[key] = value;
    });

    if (_currentUserId.isEmpty) return;

    try {
      await _db.collection('profiles').doc(_currentUserId).set(
        {
          'pushPreferences': {key: value}
        },
        SetOptions(merge: true), // Merge ensures other fields are not overwritten
      );
    } catch (e) {
      debugPrint("Error saving preference: $e");
      // If it fails, rollback the UI
      setState(() {
        _preferences[key] = !value;
      });
      if (mounted) {
        context.showErrorSnackBar("Error during save");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F6F0),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF4A8C52))),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F0),
      appBar: DashNavigationTopBar(
        title: "Push Notification"
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(
              'Choose which alerts to receive on your phone. In-app notifications will still remain visible.',
              style: TextStyle(color: Color(0xFF8A9389), fontSize: 13),
            ),
          ),
          
          _buildSectionHeader('SOCIAL & COMMUNITY'),
          _buildSwitch('newFollower', 'New Followers', 'Someone starts following you'),
          _buildSwitch('newRoutePublished', 'New Routes', 'A user you follow publishes a route'),
          _buildSwitch('routeSaved', 'Route Saved', 'Someone saves your route'),

          _buildSectionHeader('COMPETITION'),
          _buildSwitch('routeRunFaster', 'Record Beaten', 'Someone beats the time on your route'),
          _buildSwitch('leaderboardOvertake', 'Rank Changes', 'You move up or down in the rankings'),
          _buildSwitch('leaderboardCityEntry', 'City Top 10', 'You enter the Top 10 of a city'),

          _buildSectionHeader('TERRITORY & REWARDS'),
          _buildSwitch('areaStolen', 'Territory Under Attack', 'Someone steals your area on the map'),
          _buildSwitch('badgeUnlocked', 'New Badges', 'You unlock a new badge'),
          
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 24, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF8A9389),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSwitch(String prefKey, String title, String subtitle) {
    return SwitchListTile(
      activeThumbColor: const Color(0xFF4A8C52),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1E241D),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 13, color: Color(0xFF8A9389)),
      ),
      value: _preferences[prefKey] ?? true,
      onChanged: (bool value) => _updatePreference(prefKey, value),
    );
  }
}