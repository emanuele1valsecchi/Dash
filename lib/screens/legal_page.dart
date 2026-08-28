import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';

/// Selects which legal document [LegalScreen] renders.
///
/// Keeping the two supported document types in an enum prevents callers from
/// passing arbitrary strings and makes the screen's content choice explicit.
enum LegalType {
  terms,
  privacy,
}

/// Displays either the application's Terms of Service or Privacy Policy.
///
/// The screen is stateless because the selected [type] is supplied by the
/// caller and the document content is immutable. A single reusable screen
/// avoids duplicating the navigation layout for the two legal documents.
class LegalScreen extends StatelessWidget {
  /// Determines whether the page renders [_termsText] or [_privacyText].
  final LegalType type;

  const LegalScreen({
    super.key,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final isTerms = type == LegalType.terms;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F5EC),
      appBar: DashNavigationTopBar(
        title: isTerms ? 'Terms of Service' : 'Privacy Policy',
      ),
      // Legal documents can exceed the viewport height on compact devices, so
      // scrolling belongs around the complete body rather than the text alone.
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Text(
          isTerms ? _termsText : _privacyText,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF3A3A3A),
            height: 1.7,
          ),
        ),
      ),
    );
  }
}

// ─── Legal document content ─────────────────────────────────────────────────

/// Static Terms of Service content rendered when [LegalType.terms] is chosen.
///
/// This is intentionally compile-time constant content: legal text does not
/// need an asynchronous request or mutable state for this implementation.
const _termsText = '''
Terms of Service


Last updated: May 2026


1. Acceptance of Terms
By accessing or using Dash, you agree to be bound by these Terms of Service.


2. Use of the App
You agree to use Dash only for lawful purposes and in a way that does not infringe the rights of others.


3. Account
You are responsible for maintaining the confidentiality of your account credentials.


4. Intellectual Property
All content and features of Dash are the property of Dash and protected by applicable laws.


5. Disclaimer
Dash is provided "as is" without warranties of any kind.


6. Changes
We reserve the right to modify these terms at any time. Continued use of the app constitutes acceptance.


Contact: [support@dashapp.io](mailto:support@dashapp.io)
''';

/// Static Privacy Policy content rendered when [LegalType.privacy] is chosen.
///
/// Keeping it next to the terms text makes the complete legal surface visible
/// in one file, while [LegalScreen] remains responsible only for presentation.
const _privacyText = '''
Privacy Policy


Last updated: May 2026


1. Data We Collect
We collect information you provide (email, name) and usage data (routes, XP, territories).


2. How We Use Your Data
Your data is used to provide and improve the Dash experience, including leaderboards and territory maps.


3. Third-Party Services
We use Google and Meta for authentication. Their privacy policies apply to data shared with them.


4. Data Storage
Your data is stored securely and never sold to third parties.


5. Your Rights
You can request deletion of your account and data at any time by contacting us.


6. Contact
[privacy@dashapp.io](mailto:privacy@dashapp.io)
''';
