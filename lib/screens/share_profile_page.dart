import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/utils/strings_utils.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:dash/widgets/profile/profile_picture_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';

class ShareProfilePage extends StatelessWidget {
  final String userId;
  final String name;
  final String surname;
  final String profileImageUrl;

  const ShareProfilePage({
    super.key,
    required this.userId,
    required this.name,
    required this.surname,
    required this.profileImageUrl,
  });

  String get profileLink => 'https://dash-efb1d.web.app/profile/$userId';

  @override
  Widget build(BuildContext context) {
    final ThemeData contextTheme = Theme.of(context);

    final double qrCodeSize = MediaQuery.widthOf(context) / 2;
    
    return Scaffold(
      backgroundColor: contextTheme.scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Share Profile",
      ),
      body: SingleChildScrollView(
        padding: context.paddingXl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: ResponsiveSpacing().xl,
          children: [
            ProfilePictureAvatar(
              imageUrl: profileImageUrl,
              initialNameSurname: getFirstLetters(name, surname),
              aspectRatio: 0.20,
            ),
            
            SizedBox(
              width: qrCodeSize,
              height: qrCodeSize,
              child: PrettyQrView.data(
                data: profileLink,
                decoration: PrettyQrDecoration(
                  shape: PrettyQrSmoothSymbol(
                    color: Theme.of(context).primaryColor,
                    roundFactor: 1,
                  ),
                ),
              ),
            ),
            
            Text(
              '$name $surname',
              style: contextTheme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: contextTheme.colorScheme.onSurface,
              ),
            ),

            _buildActionButtons(context, contextTheme),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, ThemeData contextTheme){
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: ResponsiveSpacing().md,
      children: [
        DashActionButton(
          onPressed: () => _copyLink(context),
          icon: Symbols.link_rounded,
          label: "Copy Link",
        ),
        DashActionButton(
          onPressed: () => _shareExternal(context),
          icon: Symbols.share_rounded,
          label: "Share External"
        )
      ],
    );
  }

  void _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: profileLink));
    if (context.mounted) {
      context.showSuccessSnackBar('Link copied to clipboard!');
    }
  }

  void _shareExternal(BuildContext context) {
    SharePlus.instance.share(
      ShareParams(
        text: 'Check out my profile on Dash! $profileLink',
        subject: 'My Dash Profile',
      ),
    );
  }
}