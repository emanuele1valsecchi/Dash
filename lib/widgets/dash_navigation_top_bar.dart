import 'package:flutter/material.dart';

class DashNavigationTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;

  const DashNavigationTopBar({
    super.key,
    required this.title,
    this.actions,
  }) : titleWidget = null;

  const DashNavigationTopBar.centerActions({
    super.key,
    required this.titleWidget,
    this.actions
  }) : title = null;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      elevation: 0,
      centerTitle: true,
      shadowColor: Theme.of(context).shadowColor.withAlpha(60),
      foregroundColor: Theme.of(context).colorScheme.primary,
      titleTextStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
        color: Theme.of(context).colorScheme.primary
      ),
      title: titleWidget ?? ((title != null) ? Text(title!) : null),
      animateColor: true,
      actions: actions,
      toolbarOpacity: 1,
    );
  }
}