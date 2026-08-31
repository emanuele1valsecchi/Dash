import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dash/extensions/dash_snackbar.dart';
import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/models/home_badge_ui_model.dart';
import 'package:dash/screens/run_tracking_page.dart';
import 'package:dash/widgets/badge/dash_badge.dart';
import 'package:dash/widgets/dash_action_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class BadgeOverlayContainer extends StatefulWidget {
  final HomeBadgeUiModel badge;
  final double? progress;
  final String? userId;

  const BadgeOverlayContainer({
    super.key, 
    required this.badge,
    required this.progress, 
    this.userId,
  });

  @override
  State<BadgeOverlayContainer> createState() => _BadgeOverlayContainerState();
}

class _BadgeOverlayContainerState extends State<BadgeOverlayContainer> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _isSharing = false;

  String get _targetUserId => widget.userId ?? FirebaseAuth.instance.currentUser?.uid ?? '';
  String get profileLink => 'https://dash-efb1d.web.app/profile/$_targetUserId';

  @override
  Widget build(BuildContext context) {
    final TextStyle textStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    final double elementsSpacing = ResponsiveSpacing().md;

    return Padding(
      padding: context.paddingSm,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: elementsSpacing,
        children: [
          _buildTopRow(textStyle.fontSize!),

          _buildMainSharedImage(elementsSpacing, textStyle),

          SizedBox(
            height: textStyle.fontSize,
            width: textStyle.fontSize,
          )
        ],
      ),
    );
  }

  Widget _buildTopRow(double iconSize){

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if ( widget.progress != null && widget.progress == 1.0 )
          _isSharing
              ? SizedBox(
                  height: iconSize,
                  width: iconSize,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Symbols.share_rounded),
                  onPressed: _shareBadgeImage,
                )
        else
          SizedBox(
            height: iconSize,
            width: iconSize,
          ),

        IconButton(
          icon: const Icon(
            Symbols.close_rounded,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildMainSharedImage(double elementsSpacing, TextStyle textStyle){
    return RepaintBoundary(
      key: _boundaryKey,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: context.paddingSm,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: elementsSpacing,
            children: [
              DashBadge(
                badge: widget.badge,
                progress: widget.badge.progress,
                dimFactor: 0.44,
                clickable: false,
              ),

              _BadgeStatusIndicator(
                progress: widget.progress,
              ),

              Text(
                widget.badge.description,
                textAlign: TextAlign.center,
                style: textStyle,
              ),
            ],
          ),
        )
      ),
    );
  }

  Future<void> _shareBadgeImage() async {
    setState(() {
      _isSharing = true;
    });

    try {
      RenderRepaintBoundary? boundary = 
          _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      
      if (boundary == null) {
        throw Exception("Boundary not found");
      }

      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      
      if (byteData == null) {
        throw Exception("Failed to encode image bytes");
      }

      Uint8List pngBytes = byteData.buffer.asUint8List();

      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/dash_badge_${widget.badge.badgeId}.png';
      final file = File(filePath);
      await file.writeAsBytes(pngBytes);

      final xFile = XFile(filePath);
      await SharePlus.instance.share(
        ShareParams(
          files: [xFile],
          text: 'Check out my unlocked badge on Dash: ${widget.badge.title}!\n\nView it on my profile here: $profileLink',
          subject: 'My Dash Badge',
        ),
      );
    } catch (e) {
      debugPrint("Error sharing badge: $e");
      if (mounted) {
        context.showErrorSnackBar('Failed to share badge image.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSharing = false;
        });
      }
    }
  }
}

class _BadgeStatusIndicator extends StatelessWidget {
  final double? progress;

  const _BadgeStatusIndicator({
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    if ( progress == 1.0 ) {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: ResponsiveSpacing().md, 
          vertical: ResponsiveSpacing().sm
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: context.radiusXl,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.flag_rounded,
              color: Theme.of(context).colorScheme.outline
            ),
            
            Text(
              "You have completed this badge",
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    } else if (progress != null && progress! > 0.0) {
      final percentage = (progress! * 100).toInt();

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Text(
          "$percentage% Completed",
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
        ),
      );
    } else {
      return DashActionButton(
        onPressed: () async {
          Navigator.of(context).pop();
          await pushRunTracking(context);
        },
        label: "Complete it now",
        icon: Symbols.play_arrow_rounded
      );
    }
  }
}