import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // <-- Add this import

class PushNotificationService {
  /// Collaborators default to the real Firebase singletons, so an existing
  /// `PushNotificationService()` call behaves exactly as before. Same shape
  /// as `ProfileService`'s constructor, and for the same reason: the token
  /// write is the one piece of real logic here, and it cannot be reached at
  /// all without substituting these.
  PushNotificationService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestoreOverride = firestore,
        _authOverride = auth;

  final FirebaseFirestore? _firestoreOverride;
  final FirebaseAuth? _authOverride;

  // `late` so construction never touches Firebase: `LoginPage` builds this
  // service inline, and an eager read of any `.instance` here throws
  // `[core/no-app]` before the screen can render in a test.
  late final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  late final FirebaseFirestore _db = _firestoreOverride ?? FirebaseFirestore.instance;
  late final FirebaseAuth _auth = _authOverride ?? FirebaseAuth.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin = FlutterLocalNotificationsPlugin(); // <-- Add this

  Future<void> initialize() async {
    // 1. Create the Android Notification Channel FIRST
    await _createAndroidChannel();

    // 2. Request permissions from the user
    NotificationSettings settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false, 
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('Push notification permissions granted.');

      // 3. Retrieve the device token
      String? token = await _fcm.getToken();
      if (token != null) {
        debugPrint('FCM Token: $token');
        await _saveTokenToDatabase(token);
      }

      // 4. Listen for token refreshes
      _fcm.onTokenRefresh.listen((newToken) {
        _saveTokenToDatabase(newToken);
      });
      
      // 5. Handle foreground messages (when the app is open)
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
          _showForegroundNotification(message);
      });

    } else {
      debugPrint('User declined push notification permissions.');
    }
  }
  
  // --- NEW: Create the Android Channel ---
  Future<void> _createAndroidChannel() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'high_importance_channel', // id (must match what you send from backend, but Firebase uses this by default if not specified)
        'High Importance Notifications', // title
        description: 'This channel is used for important notifications.',
        importance: Importance.max,
      );

      await _localNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
          
      debugPrint('Android Notification Channel created.');
    }
  }

  // --- NEW: Show banner even when app is open ---
  void _showForegroundNotification(RemoteMessage message) {
    RemoteNotification? notification = message.notification;
    AndroidNotification? android = message.notification?.android;

    if (notification != null && android != null) {
      _localNotificationsPlugin.show(
        id: notification.hashCode,          
        title: notification.title,          
        body: notification.body,            
        notificationDetails: const NotificationDetails( 
          android: AndroidNotificationDetails(
            'high_importance_channel',
            'High Importance Notifications',
            icon: '@mipmap/ic_launcher', 
            priority: Priority.high,
            importance: Importance.max,
          ),
        ),
      );
    }
  }

  /// Test seam for [_saveTokenToDatabase]. `initialize()` cannot be driven
  /// from a test — it requests OS permission, fetches an FCM token and
  /// registers two platform-channel listeners — but the token write it ends
  /// in is ordinary Firestore logic, and is where a mistake is costly: a
  /// token stored under the wrong document sends one user's notifications to
  /// another user's phone.
  @visibleForTesting
  Future<void> saveTokenToDatabase(String token) => _saveTokenToDatabase(token);

  Future<void> _saveTokenToDatabase(String token) async {
    String? userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      await _db.collection('profiles').doc(userId).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));
      debugPrint('Token successfully saved to Firestore.');
    } catch (e) {
      debugPrint('Error saving token: $e');
    }
  }
}