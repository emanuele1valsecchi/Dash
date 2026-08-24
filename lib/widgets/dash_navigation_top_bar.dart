import 'package:flutter/material.dart';

class DashNavigationTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget>? actions;

  const DashNavigationTopBar({
    super.key,
    required this.title,
    this.actions,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      elevation: 0,
      centerTitle: true,
      foregroundColor: Theme.of(context).colorScheme.primary,
      titleTextStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
        color: Theme.of(context).colorScheme.primary
      ),
      title: Text(title!),
      actions: actions,
    );
  }
}