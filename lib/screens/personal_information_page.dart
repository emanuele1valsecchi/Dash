import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'login_page.dart';
import 'package:cloud_functions/cloud_functions.dart';

class PersonalInformationPage extends StatefulWidget {
  const PersonalInformationPage({super.key});

  @override
  State<PersonalInformationPage> createState() =>
      _PersonalInformationPageState();
}

class _PersonalInformationPageState extends State<PersonalInformationPage> {
  bool _isLoading = false;

  User? get user => FirebaseAuth.instance.currentUser;

  FirebaseFunctions get _functions => FirebaseFunctions.instanceFor(
        region: 'europe-west1',
      );

  Future<void> _sendPasswordReset() async {
    final email = user?.email;
    if (email == null || email.isEmpty) return;

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
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
    final controller = TextEditingController();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Update Email'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Enter new email address',
          ),
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
        ),
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
            child: const Text(
              'Send Link',
              style: TextStyle(color: Color(0xFF4A8C52)),
            ),
          ),
        ],
      ),
    );

    final newEmail = controller.text.trim();
    controller.dispose();

    if (confirm != true || newEmail.isEmpty) return;

    try {
      await user?.verifyBeforeUpdateEmail(newEmail);

      if (mounted) {
        _showSnackBar('Verification link sent to new email!');
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        _showSnackBar(
          'Error: ${e.message ?? e.code}',
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
      await FirebaseFirestore.instance.collection('mail').add({
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
      await FirebaseAuth.instance.signOut();

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
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: Theme.of(context).colorScheme.secondary,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Personal Information',
          style: TextStyle(
            color: Theme.of(context).colorScheme.secondary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
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
