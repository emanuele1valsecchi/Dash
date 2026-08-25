import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ProfilePictureAvatar extends StatelessWidget {
  final double aspectRatio;
  final String? imageUrl;
  final File? imageFile;
  final String initialNameSurname;

  const ProfilePictureAvatar({
    super.key, 
    this.aspectRatio = 0.12, 
    this.imageUrl, 
    this.imageFile,
    required this.initialNameSurname,
  });
  
  @override
  Widget build(BuildContext context) {
    final bool hasLocalFile = imageFile != null;
    final bool hasNetworkUrl = imageUrl != null && imageUrl!.isNotEmpty;
    final bool hasAnyImage = hasLocalFile || hasNetworkUrl;

    ImageProvider? getForegroundImage() {
      if (hasLocalFile) {
        return FileImage(imageFile!);
      } else if (hasNetworkUrl) {
        return CachedNetworkImageProvider(imageUrl!);
      }

      return null;
    }

    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      radius: MediaQuery.sizeOf(context).width * aspectRatio,
      foregroundImage: getForegroundImage(),
      child: !hasAnyImage 
        ? Text(
            initialNameSurname,
            style: Theme.of(context).textTheme.headlineLarge,
          ) 
        : null,
    );
  }
}