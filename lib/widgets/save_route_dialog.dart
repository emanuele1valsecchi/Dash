import 'package:dash/extensions/responsive_spacing.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

enum SaveRouteAction { save, saveAndRun }

/// What the user chose in [showSaveRouteDialog].
class SaveRouteChoice {
  final SaveRouteAction action;

  /// Whether other people may see this route on the author's profile.
  final bool isPublic;

  const SaveRouteChoice({required this.action, required this.isPublic});
}

/// Asks what to do with a route about to be saved, and whether to publish it.
///
/// Shared by route creation and route search so the visibility choice is
/// worded and defaulted identically in both — a setting that decides who can
/// see something should never depend on which screen you happened to save
/// from. [offerRun] adds the "Save route and Run" option, which only route
/// creation has.
Future<SaveRouteChoice?> showSaveRouteDialog(
  BuildContext context, {
  bool offerRun = true,
}) =>
    showDialog<SaveRouteChoice>(
      context: context,
      builder: (_) => _SaveRouteDialog(offerRun: offerRun),
    );

class _SaveRouteDialog extends StatefulWidget {
  final bool offerRun;

  const _SaveRouteDialog({required this.offerRun});

  @override
  State<_SaveRouteDialog> createState() => _SaveRouteDialogState();
}

class _SaveRouteDialogState extends State<_SaveRouteDialog> {
  /// **Private by default, deliberately.** Publishing is an opt-in: a user who
  /// dismisses this without reading it ends up with the safer of the two
  /// outcomes, and it matches how every route saved before this existed is
  /// treated.
  bool _isPublic = false;

  void _pop(SaveRouteAction action) => Navigator.of(context).pop(
        SaveRouteChoice(action: action, isPublic: _isPublic),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = ResponsiveSpacing();

    return AlertDialog(
      title: Text('Save route', style: theme.textTheme.titleMedium),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: spacing.sm,
        children: [
          Text(
            'What would you like to do with this route?',
            style: theme.textTheme.bodyMedium,
          ),
          RouteVisibilitySwitch(
            isPublic: _isPublic,
            onChanged: (value) => setState(() => _isPublic = value),
          ),
          // Said plainly here because this is the only moment it can be
          // decided — there is no visibility toggle anywhere afterwards.
          Text(
            "This can't be changed later.",
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.offerRun)
          TextButton(
            onPressed: () => _pop(SaveRouteAction.saveAndRun),
            child: const Text('Save and Run'),
          ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
          ),
          onPressed: () => _pop(SaveRouteAction.save),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// States a route's visibility in one line — icon, label, and what it means
/// for other people.
///
/// Shared by the save dialog (where it sits next to the switch that sets it)
/// and the route detail page (where it is read-only, because the choice is
/// permanent — see [RouteVisibilitySwitch]), so the same state is described in
/// the same words in both places.
class RouteVisibilityInfo extends StatelessWidget {
  final bool isPublic;

  /// Whether to head the description with a bold "Public"/"Private".
  ///
  /// On by default for the save dialog, where the label names the thing the
  /// switch beside it sets. Off on the route detail page, which just states
  /// the consequence in one line — there is nothing to set there, so a label
  /// would only be repeating the sentence under it.
  final bool showLabel;

  const RouteVisibilityInfo({
    super.key,
    required this.isPublic,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = isPublic
        ? 'Anyone can see this route on your profile.'
        : 'Only you can see this route.';

    return Row(
      spacing: ResponsiveSpacing().sm,
      children: [
        Icon(
          isPublic ? Symbols.public_rounded : Symbols.lock_rounded,
          fill: 1,
          size: theme.textTheme.titleMedium!.fontSize,
          color: theme.colorScheme.secondary,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showLabel)
                Text(
                  isPublic ? 'Public' : 'Private',
                  style: theme.textTheme.bodyMedium!.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              Text(
                description,
                style: showLabel
                    ? theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : theme.textTheme.bodyMedium!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// [RouteVisibilityInfo] plus the switch that sets it.
///
/// **Only ever shown while a route is being saved.** Visibility is chosen once
/// and is permanent afterwards — `firestore.rules` pins `isPublic` on update,
/// so there is no later toggle anywhere in the app, and this widget has no
/// business appearing on a route that already exists.
class RouteVisibilitySwitch extends StatelessWidget {
  final bool isPublic;
  final ValueChanged<bool> onChanged;

  const RouteVisibilitySwitch({
    super.key,
    required this.isPublic,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: RouteVisibilityInfo(isPublic: isPublic)),
        Switch(value: isPublic, onChanged: onChanged),
      ],
    );
  }
}
