import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// Utility function to open external web links.
  Future<void> _launchURL(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw Exception('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTerms = type == LegalType.terms;
    final content = isTerms ? _termsText : _privacyText;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F5EC),
      appBar: DashNavigationTopBar(
        title: isTerms ? 'Terms of Service' : 'Privacy Policy',
      ),
      // Legal documents can exceed the viewport height on compact devices, so
      // scrolling belongs around the complete body rather than the text alone.
      body: SingleChildScrollView(
        // Dynamic padding handling system navigation bar height on Android
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          MediaQuery.of(context).padding.bottom + 40,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              content,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF3A3A3A),
                height: 1.7,
              ),
            ),
            if (!isTerms) ...[
              const SizedBox(height: 24),
              // Clickable link for the online TermsFeed privacy policy version
              GestureDetector(
                onTap: () => _launchURL(
                    'https://www.termsfeed.com/live/e6d2cea7-097f-473a-a6f7-06b730b1d804'),
                child: const Text(
                  'View Online Privacy Policy (TermsFeed)',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF2E7D32),
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
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

Last updated: August 29, 2026

Online version: https://www.termsfeed.com/live/e6d2cea7-097f-473a-a6f7-06b730b1d804

This Privacy Policy describes Our policies and procedures on the collection, use and disclosure of Your information when You use the Service and tells You about Your privacy rights and how the law protects You.

We use Your Personal Data to provide and improve the Service. We collect, use, and disclose Your information as described in this Privacy Policy and, where required by applicable law, only where We have a valid legal basis to do so, including Your consent (where consent is required). This Privacy Policy has been created with the help of the Privacy Policy Generator.


Interpretation and Definitions

Interpretation
The words whose initial letters are capitalized have meanings defined under the following conditions. The following definitions shall have the same meaning regardless of whether they appear in singular or in plural.

Definitions
For the purposes of this Privacy Policy:

- Account means a unique account created for You to access Our Service or parts of Our Service.
- Affiliate means an entity that controls, is controlled by, or is under common control with a party, where "control" means ownership of 50% or more of the shares, equity interest or other securities entitled to vote for election of directors or other managing authority.
- Application refers to Dash, the software program provided by the Company.
- Company (referred to as either "the Company", "We", "Us" or "Our" in this Privacy Policy) refers to Dash.
- Country/State refers to: Italy.
- Device means any device that can access the Service, such as a computer, a cell phone or a digital tablet.
- Personal Data (or "Personal Information") is any information that relates to an identified or identifiable individual. We use "Personal Data" and "Personal Information" interchangeably unless a law uses a specific term.
- Service refers to the Application.
- Service Provider means any natural or legal person who processes the data on behalf of the Company. It refers to third-party companies or individuals employed by the Company to facilitate the Service, to provide the Service on behalf of the Company, to perform services related to the Service or to assist the Company in analyzing how the Service is used.
- Usage Data refers to data collected automatically, either generated by the use of the Service or from the Service infrastructure itself (for example, the duration of a page visit).
- User means any individual who accesses or uses the Service.
- You means the individual accessing or using the Service, or the company, or other legal entity on behalf of which such individual is accessing or using the Service, as applicable.


Collecting and Using Your Personal Information

Types of Data Collected

Personal Data
While using Our Service, We may ask You to provide Us with certain personally identifiable information that can be used to contact or identify You. Personally identifiable information may include, but is not limited to:
- Email address
- First name and last name
- Phone number
- Address, State, Province, ZIP/Postal code, City

Usage Data
Usage Data is collected automatically when using the Service.
Usage Data may include information such as Your Device's Internet Protocol address (e.g. IP address), browser type, browser version, the pages of Our Service that You visit, the time and date of Your visit, the time spent on those pages, unique device identifiers and other diagnostic data.
When You access the Service by or through a mobile device, We may collect certain information automatically, including, but not limited to, the type of mobile device You use, Your mobile device's unique ID, the IP address of Your mobile device, Your mobile operating system, the type of mobile Internet browser You use, unique device identifiers and other diagnostic data.
We may also collect information that Your browser sends whenever You visit Our Service or when You access the Service by or through a mobile device.

Information Collected While Using the Application
While using Our Application, in order to provide features of Our Application, We may collect, with Your prior permission:
- Information regarding Your location
- Pictures and other information from Your Device's camera and photo library

We use this information to provide features of Our Service and to improve and customize Our Service. The information may be uploaded to the Company's servers and/or a Service Provider's server or it may be simply stored on Your device.
You can enable or disable access to this information at any time, through Your Device settings.

Tracking Technologies and Cookies
We use tracking technologies (such as cookies) to track the activity and to improve Our Service. The technologies We use may include:


Use of Your Personal Data
The Company may use Personal Data for the following purposes:
- To provide and maintain Our Service, including to monitor the usage of Our Service.
- To manage Your Account: to manage Your registration as a user of the Service. The Personal Data You provide can give You access to different functionalities of the Service that are available to You as a registered user.
- For the performance of a contract: the development, compliance and undertaking of the purchase contract for the products, items or services You have purchased or of any other contract with Us through the Service.
- To contact You: To contact You by email, telephone calls, SMS, or other equivalent forms of electronic communication, such as a mobile application's push notifications regarding updates or informative communications related to the functionalities, products or contracted services, including the security updates, when necessary or reasonable for their implementation.
- To provide You with news, special offers, and general information about other goods, services and events which We offer that are similar to those that You have already purchased or inquired about. We send such marketing communications only where permitted by applicable law: where prior consent is required (for example, under the laws applicable in the EEA and the UK), We will send them only with Your consent; otherwise, We may send them until You opt out. You may opt out or withdraw Your consent at any time by using the unsubscribe link in any marketing email We send or by contacting Us.
- To manage Your requests: To attend and manage Your requests to Us.
- For business transfers: We may use Your Personal Data to evaluate or conduct a merger, divestiture, restructuring, reorganization, dissolution, or other sale or transfer of some or all of Our assets, whether as a going concern or as part of bankruptcy, liquidation, or similar proceeding, in which Personal Data held by Us about Our Service users is among the assets transferred.
- For other purposes: We may use Your information for other purposes, such as data analysis, identifying usage trends, determining the effectiveness of Our promotional campaigns, and evaluating and improving Our Service, products, services, marketing and Your experience.

We may share Your Personal Data in the following situations:
- With Service Providers: We may share Your Personal Data with Service Providers to monitor and analyze the use of Our Service, and to contact You.
- For business transfers: We may share or transfer Your Personal Data in connection with, or during negotiations of, any merger, sale of Company assets, financing, or acquisition of all or a portion of Our business to another company.
- With Affiliates: We may share Your Personal Data with Our affiliates, in which case We will require those affiliates to honor this Privacy Policy. Affiliates include Our parent company and any other subsidiaries, joint venture partners or other companies that We control or that are under common control with Us.
- With other users: If Our Service offers public areas, when You share Personal Data or otherwise interact in the public areas with other users, such information may be viewed by all users and may be publicly distributed outside the Service.
- With Your consent: We may disclose Your Personal Data for any other purpose with Your consent.


Text Messages Privacy Notice
You have the option to receive text (SMS) messages from Us. If You opt in to text messages, We will send You updates, notifications, and other communications as described below. When You opt in, We will collect and store the information You provide in connection with text messaging, such as Your phone number, the date and method of Your consent, and message delivery and read information.

No mobile information will be shared with or sold to third parties or affiliates for marketing or promotional purposes. The phone numbers and consent records We collect for texting are never shared with anyone for any purpose, except the Service Providers that technically have to handle them to deliver the texts.

Consent to receive text messages is not a condition of any purchase or use of Our Service. If You consent to receive SMS from Us, You agree to receive text messages from Us related to:
- Customer care and support
- Account notifications, such as activity, status, or renewal reminders
- Delivery notifications and updates on the status of a delivery
- Authentication messages, such as one-time passwords (OTP) and passcodes
- Security alerts, such as suspicious login attempts or unusual account activity
- Marketing and promotional offers, discounts, and other promotional content

Reply STOP to opt-out. Reply HELP for support. Message & data rates may apply. Messaging frequency may vary. Carriers are not liable for delayed or undelivered messages.


Retention of Your Personal Data
The Company will retain Your Personal Data only for as long as is necessary for the purposes set out in this Privacy Policy. We will retain and use Your Personal Data to the extent necessary to comply with Our legal obligations (for example, if We are required to retain Your data to comply with applicable laws), resolve disputes, and enforce Our legal agreements and policies.

Where possible, We apply shorter retention periods and/or reduce identifiability by deleting, aggregating, or anonymizing data. Unless otherwise stated, the retention periods below are maximum periods ("up to") and We may delete or anonymize data sooner when it is no longer needed for the relevant purpose. We apply different retention periods to different categories of Personal Data based on the purpose of processing and legal obligations:

- Account Information
  - User Accounts: retained for the duration of Your Account relationship plus up to 24 months after account closure to handle any post-termination issues or resolve disputes.
- Customer Support Data
  - Support tickets and correspondence: up to 24 months from the date of ticket closure to resolve follow-up inquiries, track service quality, and defend against potential legal claims.
  - Chat transcripts: up to 24 months for quality assurance and staff training purposes.
- Usage Data
  - Application usage statistics: up to 24 months to understand feature adoption and service improvements.
  - Server logs (IP addresses, access times): up to 24 months for security monitoring and troubleshooting purposes.

Usage Data is retained in accordance with the retention periods described above, and may be retained longer only where necessary for security, fraud prevention, or legal compliance.

We may retain Personal Data beyond the periods stated above for different reasons:
- Legal obligation: We are required by law to retain specific data (e.g., financial records for tax authorities).
- Legal claims: Data is necessary to establish, exercise, or defend legal claims.
- Your explicit request: You ask Us to retain specific information.
- Technical limitations: Data exists in backup systems that are scheduled for routine deletion.

You may request information about how long We will retain Your Personal Data by contacting Us.

When retention periods expire, We securely delete or anonymize Personal Data according to the following procedures:
- Deletion: Personal Data is removed from Our systems and no longer actively processed.
- Backup retention: Residual copies may remain in encrypted backups for a limited period consistent with Our backup retention schedule and are not restored except where necessary for security, disaster recovery, or legal compliance.
- Anonymization: In some cases, We convert Personal Data into anonymous statistical data that cannot be linked back to You. This anonymized data may be retained indefinitely for research and analytics.


Transfer of Your Personal Data
Your information, including Personal Data, is processed at the Company's operating offices and in any other places where the parties involved in the processing are located. This means that this information may be transferred to — and maintained on — computers located outside of Your state, province, country or other governmental jurisdiction where the data protection laws may differ from those of Your jurisdiction.

Where required by applicable law, We will ensure that international transfers of Your Personal Data are subject to appropriate safeguards and, where relevant, supplementary measures. The Company will take all steps reasonably necessary to ensure that Your data is treated securely and in accordance with this Privacy Policy and no transfer of Your Personal Data will take place to an organization or a country unless there are adequate controls in place, including the security of Your data and other personal information.


Delete Your Personal Data
You have the right to delete or request that We assist in deleting the Personal Data that We have collected about You.

Our Service may give You the ability to delete certain information about You from within the Service.

You may update, amend, or delete Your information at any time by signing in to Your Account, if You have one, and visiting the account settings section that allows You to manage Your personal information. You may also contact Us to request access to, correct, or delete any Personal Data that You have provided to Us.

Please note, however, that We may need to retain certain information when We have a legal obligation or lawful basis to do so.


Disclosure of Your Personal Data

Business Transactions
If the Company is involved in a merger, acquisition or asset sale, Your Personal Data may be transferred. We will provide notice before Your Personal Data is transferred and becomes subject to a different Privacy Policy.

Law Enforcement
Under certain circumstances, the Company may disclose Your Personal Data if required to do so by law or in response to valid requests by public authorities (e.g. a court or a government agency).

Other Legal Requirements
The Company may disclose Your Personal Data in the good-faith belief that such action is necessary to:
- Comply with a legal obligation
- Protect and defend the rights or property of the Company
- Prevent or investigate possible wrongdoing in connection with the Service
- Protect the personal safety of Users of the Service or the public
- Protect against legal liability


Security of Your Personal Data
The security of Your Personal Data is important to Us, but remember that no method of transmission over the Internet, or method of electronic storage, is 100% secure. While We strive to use commercially reasonable means to protect Your Personal Data, We cannot guarantee its absolute security.


Children's and Minors' Privacy
The Service is not directed to, and We do not knowingly collect Personal Information from, anyone under the age of 16.

If You are a parent or guardian and You believe Your child has provided Us with Personal Information, please contact Us. If We become aware that We have collected Personal Information from anyone under the age of 16, We will take steps to remove that information from Our servers as soon as reasonably possible.

Some countries and states set a higher age at which an individual can consent to the processing of their own Personal Information. Where We rely on consent as a legal basis and the law applicable to a User sets an age higher than 16, We may require the consent of that User's parent or guardian before We collect and use their Personal Information.


Links to Other Websites
Our Service may contain links to other websites that are not operated by Us. If You click on a third-party link, You will be directed to that third party's site. We strongly advise You to review the Privacy Policy of every site You visit.

We have no control over and assume no responsibility for the content, privacy policies or practices of any third-party sites or services.


Changes to this Privacy Policy
We may update Our Privacy Policy from time to time. We will notify You of any changes by posting the new Privacy Policy on this page.

We will let You know via email and/or a prominent notice on Our Service, prior to the change becoming effective and update the "Last updated" date at the top of this Privacy Policy.

You are advised to review this Privacy Policy periodically for any changes. Changes to this Privacy Policy are effective when they are posted on this page.


Contact Us
If You have any questions about this Privacy Policy, You can contact Us:
- By email: noreply.dashapp@gmail.com
''';