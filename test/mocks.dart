import 'package:dash/services/auth_service.dart';
import 'package:dash/services/badge_service.dart';
import 'package:dash/services/follow_service.dart';
import 'package:dash/services/profile_service.dart';
import 'package:dash/services/push_notification_service.dart';
import 'package:dash/services/route_repository.dart';
import 'package:dash/services/run_session_repository.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mockito/annotations.dart';

/// One place to declare every mock the suite needs.
///
/// Regenerate after editing this list:
///
/// ```sh
/// dart run build_runner build --delete-conflicting-outputs
/// ```
///
/// Import the *generated* file, not this one:
/// `import '../mocks.mocks.dart';`
///
/// **When to reach for a mock rather than a fake.** Where a real in-memory
/// double exists, prefer it — `FakeFirebaseFirestore` actually stores and
/// queries documents, so a repository test asserts on real behaviour instead
/// of on a script of expected calls. Mocks earn their place a level up, for
/// *screens*: there the interesting question is usually "did this screen ask
/// the service for the right thing", which `verify()` answers directly, and
/// stubbing a failure with `thenThrow` is the only sane way to test an error
/// branch.
@GenerateMocks([
  AuthService,
  ProfileService,
  PushNotificationService,
  RouteRepository,
  RunSessionRepository,
  FollowService,
  BadgeService,
  // Returned by AuthService's sign-in methods, so a stubbed success needs one.
  UserCredential,
  User,
])
void main() {}
