import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

class ProfilePictureAvatar extends StatelessWidget {
  final double aspectRatio;

  const ProfilePictureAvatar({super.key, this.aspectRatio = 0.12});
  
  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      radius: MediaQuery.sizeOf(context).width * aspectRatio,
      child: Text(
        "EV",
        style: Theme.of(context).textTheme.headlineLarge,
      ),
    );
  }
}