import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/image_upload_service.dart';


class ProfileAvatarWidget extends StatefulWidget {
  final String? initialImageUrl;
  final double size;
  final void Function(String newUrl)? onImageUploaded;

  const ProfileAvatarWidget({
    super.key,
    this.initialImageUrl,
    this.size = 110,
    this.onImageUploaded,
  });

  @override
  State<ProfileAvatarWidget> createState() => _ProfileAvatarWidgetState();
}


class _ProfileAvatarWidgetState extends State<ProfileAvatarWidget> {
  String? _imageUrl;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _imageUrl = widget.initialImageUrl;
  }

  Future<void> _handleTap() async {
    // ✅ Richiede il permesso a runtime prima di aprire la galleria
    final bool granted = await _requestGalleryPermission();
    if (!granted) return;

    setState(() => _isLoading = true);

    final String? url = await ImageUploadService.pickAndUpload(
      source: ImageSource.gallery,
      onError: (err) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (url != null) {
      setState(() => _imageUrl = url);
      widget.onImageUploaded?.call(url);
    }
  }

  Future<bool> _requestGalleryPermission() async {
    // Android 13+ usa READ_MEDIA_IMAGES, sotto usa READ_EXTERNAL_STORAGE
    Permission permission;
    if (await Permission.photos.status.isGranted) {
      return true; // già concesso
    }

    // Android 13+ (API 33+)
    permission = Permission.photos;
    PermissionStatus status = await permission.request();

    if (status.isGranted) return true;

    if (status.isPermanentlyDenied && mounted) {
      // L'utente ha negato permanentemente → manda alle impostazioni
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "Permesso galleria negato. Abilitalo nelle impostazioni.",
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: "Impostazioni",
            textColor: Colors.white,
            onPressed: () => openAppSettings(),
          ),
        ),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    final double badgeSize = size * 0.28;

    return GestureDetector(
      onTap: _isLoading ? null : _handleTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [

            // ── Cerchio immagine profilo ──────────────────────────────
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFE8F5D6),
                border: Border.all(
                  color: const Color(0xFF4A5D3F).withOpacity(0.25),
                  width: 2,
                ),
                image: _imageUrl != null && !_isLoading
                    ? DecorationImage(
                        image: NetworkImage(_imageUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _buildAvatarContent(size),
            ),

            // ── Badge "+" in basso a destra ───────────────────────────
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF4A5D3F),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.add,
                  color: Colors.white,
                  size: badgeSize * 0.55,
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }

  Widget _buildAvatarContent(double size) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF4A5D3F),
          strokeWidth: 2.5,
        ),
      );
    }
    if (_imageUrl == null) {
      return Center(
        child: Icon(
          Icons.person_rounded,
          size: size * 0.48,
          color: const Color(0xFF4A5D3F).withOpacity(0.45),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}