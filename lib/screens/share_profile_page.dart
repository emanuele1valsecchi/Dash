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
              // Trimmed, matching `DashUserTile`: a user with no surname
              // recorded would otherwise render a trailing space, which
              // centres the name visibly off-centre.
              '$name $surname'.trim(),
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
    // `Wrap`, not `Row`, so the two buttons drop to a second line instead of
    // clipping when they cannot fit side by side.
    //
    // At the default text scale a `Row` fits fine on any phone — this is not
    // fixing a bug anyone has reported. It matters at a large accessibility
    // text scale, where the two labels plus their icons genuinely do outgrow
    // a 320-390pt screen and a `Row` would silently clip "Share External"
    // off the right edge. `Wrap` costs nothing when there is room.
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: ResponsiveSpacing().md,
      runSpacing: ResponsiveSpacing().sm,
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