import 'dart:async';
import 'package:dash/screens/explore_page.dart';
import 'package:dash/screens/home_page.dart';
import 'package:dash/screens/profile_page.dart';
import 'package:dash/widgets/dash_navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Ensure the import path for your login screen is correct
import 'package:dash/screens/login_page.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> with WidgetsBindingObserver {
  int _currentIndex = 1;
  bool _isShowingErrorDialog = false; // Flag to short-circuit the UI
  
  StreamSubscription<DocumentSnapshot>? _profileSub;
  StreamSubscription<User?>? _authSub; // ADDED: Auth state listener

  final List<Widget> _pages = const [
    ExplorePage(),
    HomePage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Check on cold start
    _verifyAccountIntegrity(); 
    
    // Start foreground real-time listeners
    _startAuthWatcher();
    _startRealtimeAccountWatcher();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _profileSub?.cancel();
    _authSub?.cancel(); // Clean up auth listener
    super.dispose();
  }

  // 1. LIFECYCLE WATCHER: Catches issues when app resumes from background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _verifyAccountIntegrity();
    }
  }

  // 2. AUTH WATCHER: Catches instant drops of the Firebase Auth token
  void _startAuthWatcher() {
    _authSub = FirebaseAuth.instance.userChanges().listen((user) {
      if (!mounted) return;
      if (user == null) {
        _triggerAccountError();
      }
    });
  }

  // 3. FIRESTORE WATCHER: Catches document deletion and permission errors
  void _startRealtimeAccountWatcher() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _profileSub = FirebaseFirestore.instance
        .collection('profiles')
        .doc(user.uid)
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      
      // If the document vanishes while the app is active
      if (!doc.exists) {
        _triggerAccountError();
      }
    }, onError: (error) {
      // If the auth token gets revoked, Firestore throws a permission denied error.
      // We catch the error here to trigger the UI block instantly.
      if (!mounted) return;
      _triggerAccountError();
    });
  }

  // Validates token and doc (mostly useful for cold starts and background returns)
  Future<void> _verifyAccountIntegrity() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _triggerAccountError();
      return;
    }

    try {
      await user.reload(); 

      final doc = await FirebaseFirestore.instance.collection('profiles').doc(user.uid).get();
      if (!doc.exists) {
        _triggerAccountError();
      }
    } catch (e) {
      _triggerAccountError(); 
    }
  }

  // The unclosable error dialog
  void _triggerAccountError() {
    if (_isShowingErrorDialog || !mounted) return;
    
    setState(() => _isShowingErrorDialog = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Account Error'),
          content: const Text(
            'There was a problem with your account. Please go back to the login page.\n\n'
            'If the problem persists, contact us at support@dash.com',
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (context) => const LoginScreen(), 
                    ),
                    (route) => false,
                  );
                }
              },
              child: const Text('Go to Login', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // THE LIFESAVER
    // Safely short-circuits the entire app UI if the account is flagged as deleted
    if (_isShowingErrorDialog) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      );
    }

    // Standard app flow
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: DashNavigationbar(
        selectedIndex: _currentIndex, 
        onDestinationSelected: (index) {
          _verifyAccountIntegrity(); 
          
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}