import 'package:flutter/material.dart';

/// Cap on a route name, matching the one the `favoriteSession` Cloud Function
/// already applies, so a rename can never store more than a fresh favourite
/// is allowed to.
const int kMaxRouteNameLength = 120;

/// Prompts for a new name for a route. Resolves to the trimmed new name, or
/// null if the user cancelled or did not change anything meaningful.
Future<String?> showRenameRouteDialog(
  BuildContext context, {
  required String initialName,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _RenameRouteDialog(initialName: initialName),
    );

/// The rename prompt.
///
/// **It owns its own `TextEditingController`, and that is the whole reason it
/// is a widget rather than an inline `AlertDialog` in a builder.** The obvious
/// version — create the controller, `await showDialog(...)`, then dispose it —
/// disposes it the instant the future completes, which is when the dialog
/// *starts* its exit transition, not when it finishes. The `TextField` is
/// still mounted and still bound to that controller for the rest of the
/// animation, so tearing it down afterwards throws; the visible symptom is an
/// unrelated-looking `dependents.isEmpty` assertion in `framework.dart`,
/// because an exception during a subtree's deactivation leaves a dependent
/// registered on an ancestor `InheritedElement`, which asserts on its own
/// deactivation a moment later.
///
/// Owning the controller in a [State] ties its disposal to the dialog
/// subtree's actual unmount, which is the only correct moment.
class _RenameRouteDialog extends StatefulWidget {
  final String initialName;

  const _RenameRouteDialog({required this.initialName});

  @override
  State<_RenameRouteDialog> createState() => _RenameRouteDialogState();
}

class _RenameRouteDialogState extends State<_RenameRouteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  )..selection = TextSelection(
      // Selects the existing name, so typing replaces it rather than
      // appending — a rename usually means replacing.
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('Rename route', style: theme.textTheme.titleMedium),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: kMaxRouteNameLength,
        textInputAction: TextInputAction.done,
        style: theme.textTheme.bodyMedium,
        decoration: const InputDecoration(
          labelText: 'Name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        // A TextEditingController is a ValueNotifier, so Save can disable
        // itself on an empty field with no listener plumbing of its own —
        // and nothing to dispose beyond the controller above.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => TextButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
