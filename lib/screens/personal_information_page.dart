import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'login_page.dart';
import 'package:cloud_functions/cloud_functions.dart';

class PersonalInformationPage extends StatefulWidget {
  /// Test seams. Production leaves all three null and the state resolves
  /// `.instance` lazily — an eager field initializer would throw
  /// `[core/no-app]` when the widget is *constructed*, before `runApp`.
  @visibleForTesting
  final FirebaseAuth? auth;
  @visibleForTesting
  final FirebaseFirestore? firestore;
  @visibleForTesting
  final FirebaseFunctions? functions;

  const PersonalInformationPage({
    super.key,
    this.auth,
    this.firestore,
    this.functions,
  });

  @override
  State<PersonalInformationPage> createState() =>
      _PersonalInformationPageState();
}

class _PersonalInformationPageState extends State<PersonalInformationPage> {
  bool _isLoading = false;

  late final FirebaseAuth _auth = widget.auth ?? FirebaseAuth.instance;
  late final FirebaseFirestore _db =
      widget.firestore ?? FirebaseFirestore.instance;
  late final FirebaseFunctions _functions =
      widget.functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  User? get user => _auth.currentUser;

  Future<void> _sendPasswordReset() async {
    final email = user?.email;
    if (email == null || email.isEmpty) return;

    try {
      await _auth.sendPasswordResetEmail(email: email);
      if (mounted) {
        _showSnackBar('Password reset email sent!');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  Future<void> _updateEmailDialog() async {
    final newEmail = await showDialog<String>(
      context: context,
      builder: (_) => const _UpdateEmailDialog(),
    );

    if (newEmail == null || newEmail.isEmpty) return;

    try {
      await user?.verifyBeforeUpdateEmail(newEmail);

      if (mounted) {
        _showSnackBar('Verification link sent to new email!');
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        // Changing the address an account signs in with is one of Firebase's
        // *sensitive* operations: it refuses unless the ID token is fresh,
        // which it stops being a few minutes after sign-in. Firebase's own
        // message for this ("This operation is sensitive and requires recent
        // authentication...") is accurate but says nothing the user can act
        // on, so it is replaced with the instruction — matching what
        // `_deleteAccount` already says for the same situation. There is no
        // re-authentication prompt anywhere in the app yet; logging out and
        // back in is genuinely the only way through.
        _showSnackBar(
          e.code == 'requires-recent-login'
              ? 'Please log out and log back in before changing your email.'
              : 'Error: ${e.message ?? e.code}',
          isError: true,
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  Future<void> _exportData() async {
    final currentUser = user;
    final email = currentUser?.email;

    if (currentUser == null || email == null || email.isEmpty) {
      if (mounted) {
        _showSnackBar(
          'No email address is associated with this account.',
          isError: true,
        );
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _db.collection('mail').add({
        'to': [
          email,
          'noreply.dashapp@gmail.com',
        ],
        'message': {
          'subject': 'Your Data Export Request - Dash',
          'html': '''
            <h3>Hello ${currentUser.displayName ?? 'Runner'}!</h3>
            <p>Thanks for reaching out!</p>
            <p>
              We have received your request. Your data will be packed and sent
              to you in a secure ZIP file within maximum 48h.
            </p>
            <p>Keep on running!<br><b>The Dash Team</b></p>
          ''',
        },
        'createdAt': FieldValue.serverTimestamp(),
        'requestType': 'dataExport',
        'userId': currentUser.uid,
      });

      if (mounted) {
        _showSnackBar(
          'Request received. A confirmation was sent to your email.',
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          'Error requesting data export: $e',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _clearProgress() async {
    final confirm = await _showConfirmationDialog(
      'Clear Progress',
      'This will permanently delete all your running sessions, unlocked areas, and reset your stats to zero. Published routes will be preserved. Are you absolutely sure?',
      isDestructive: true,
    );

    if (confirm != true) return;

    if (user == null) {
      if (mounted) {
        _showSnackBar('You must be logged in.', isError: true);
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      final callable = _functions.httpsCallable('clearUserProgress');
      final result = await callable.call(<String, dynamic>{});

      if (mounted) {
        final message = result.data is Map
            ? (result.data['message'] ?? 'Progress cleared successfully!')
            : 'Progress cleared successfully!';

        _showSnackBar(message.toString());
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'clearUserProgress failed: code=${e.code}, '
        'message=${e.message}, details=${e.details}',
      );

      if (mounted) {
        _showSnackBar(
          'Server error: ${e.code} - ${e.message ?? 'Unknown error'}',
          isError: true,
        );
      }
    } catch (e) {
      debugPrint('clearUserProgress unexpected error: $e');

      if (mounted) {
        _showSnackBar('Error: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirm = await _showConfirmationDialog(
      'Delete Account',
      'This action is irreversible. All account data, runs, badges, areas, followers, and favorites will be deleted. Published routes will be preserved as anonymous routes. Are you absolutely sure?',
      isDestructive: true,
    );

    if (confirm != true) return;

    if (user == null) {
      if (mounted) {
        _showSnackBar('You must be logged in.', isError: true);
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      final callable = _functions.httpsCallable('deleteMyAccount');
      await callable.call(<String, dynamic>{});

      // The callable deletes the Firebase Auth account on the server.
      // Do not call user.delete() here.
      await _auth.signOut();

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => const LoginScreen(),
        ),
        (route) => false,
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'deleteMyAccount failed: code=${e.code}, '
        'message=${e.message}, details=${e.details}',
      );

      if (mounted) {
        String message;

        if (e.code == 'unauthenticated') {
          message = 'Your session has expired. Please log in again.';
        } else if (e.code == 'failed-precondition') {
          message =
              'Please log out and log back in before deleting your account.';
        } else {
          message =
              'Account deletion failed: ${e.message ?? 'Unknown error'}';
        }

        _showSnackBar(message, isError: true);
      }
    } catch (e) {
      debugPrint('deleteMyAccount unexpected error: $e');

      if (mounted) {
        _showSnackBar('Error: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<bool?> _showConfirmationDialog(
    String title,
    String content, {
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              isDestructive ? 'Delete' : 'Confirm',
              style: TextStyle(
                color: isDestructive
                    ? Colors.red
                    : const Color(0xFF4A8C52),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Personal Information"
      ), 
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 10),
                _buildListTile(
                  Symbols.password_rounded,
                  'Change Password',
                  _sendPasswordReset,
                ),
                _buildListTile(
                  Symbols.mail_rounded,
                  'Update Email',
                  _updateEmailDialog,
                ),
                const Divider(height: 30),
                _buildListTile(
                  Symbols.download_rounded,
                  'Export Data (GDPR)',
                  _exportData,
                ),
                _buildListTile(
                  Symbols.restart_alt_rounded,
                  'Clear Progress',
                  _clearProgress,
                ),
                const Divider(height: 40),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _deleteAccount,
                    icon: const Icon(
                      Symbols.delete_forever_rounded,
                      color: Colors.white,
                    ),
                    label: const Text(
                      'Delete Account',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 30),
                  child: Text(
                    'Deleting your account is permanent. Published routes are preserved anonymously.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildListTile(
    IconData icon,
    String title,
    VoidCallback onTap,
  ) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(
        icon,
        color: Theme.of(context).colorScheme.secondary,
      ),
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Colors.grey,
      ),
      onTap: onTap,
    );
  }
}

/// The "update email" prompt.
///
/// **It owns its own `TextEditingController`, and that is the whole reason it
/// is a widget rather than an inline `AlertDialog` in a builder** — the same
/// fix, for the same bug, as [showRenameRouteDialog]'s own dialog. Creating
/// the controller, `await showDialog(...)`, then disposing it disposes it the
/// instant the future completes, which is when the dialog *starts* its exit
/// transition. The `TextField` stays mounted and bound to it for the rest of
/// the animation, so the next frame throws `A TextEditingController was used
/// after being disposed` — confirmed reproducible, see
/// `test/widget_test/personal_information_page_test.dart`.
///
/// Owning the controller in a [State] ties its disposal to the dialog
/// subtree's actual unmount, which is the only correct moment.
///
/// Pops the trimmed address, or null if cancelled.
class _UpdateEmailDialog extends StatefulWidget {
  const _UpdateEmailDialog();

  @override
  State<_UpdateEmailDialog> createState() => _UpdateEmailDialogState();
}

class _UpdateEmailDialogState extends State<_UpdateEmailDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update Email'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          hintText: 'Enter new email address',
        ),
        keyboardType: TextInputType.emailAddress,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.grey),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text(
            'Send Link',
            style: TextStyle(color: Color(0xFF4A8C52)),
          ),
        ),
      ],
    );
  }
}
