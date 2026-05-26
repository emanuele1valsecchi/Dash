import 'package:flutter/material.dart';

enum LegalType { terms, privacy }

class LegalScreen extends StatelessWidget {
  final LegalType type;

  const LegalScreen({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final isTerms = type == LegalType.terms;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F5EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF0F5EC),
        elevation: 0,
        title: Text(
          isTerms ? 'Terms of Service' : 'Privacy Policy',
          style: const TextStyle(
            color: Color(0xFF2A2A2A),
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Color(0xFF2A2A2A), size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
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

// ─── Testi ────────────────────────────────────────────────────────────────────
// TODO: sostituisci con il testo legale definitivo

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

Contact: support@dashapp.io
''';

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
privacy@dashapp.io
''';