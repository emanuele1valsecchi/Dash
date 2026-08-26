import 'package:flutter/material.dart';

extension SnackbarExtension on BuildContext {

  void _buildAndShowSnackBar(String message, DashSnackbarType type, {SnackBarAction? action}) {

    final Color backgroundColor;
    final Color textColor;

    switch (type){
      case DashSnackbarType.confirm:
        backgroundColor = Theme.of(this).colorScheme.primaryContainer;
        textColor = Theme.of(this).colorScheme.onPrimaryContainer;

      case DashSnackbarType.error:
        backgroundColor = Theme.of(this).colorScheme.errorContainer;
        textColor = Theme.of(this).colorScheme.onErrorContainer;

      case DashSnackbarType.information:
        backgroundColor = Theme.of(this).colorScheme.tertiaryContainer;
        textColor = Theme.of(this).colorScheme.onTertiaryContainer;

      case DashSnackbarType.warning:
        backgroundColor = Theme.of(this).colorScheme.surfaceContainerHighest;
        textColor = Theme.of(this).colorScheme.onSurfaceVariant;
    }

    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: Theme.of(this).textTheme.bodySmall!.copyWith(
              color: textColor,
            ),
          ),
          backgroundColor: backgroundColor,
          behavior: SnackBarBehavior.floating,
          action: action,
        ),
      );
  }

  // 2. Public method for Errors
  void showErrorSnackBar(String message, {SnackBarAction? action}) {
    _buildAndShowSnackBar(
      message, 
      DashSnackbarType.error,
      action: action
    );
  }

  // 3. Public method for Success / Info messages
  void showSuccessSnackBar(String message, {SnackBarAction? action}) {
    _buildAndShowSnackBar(
      message, 
      DashSnackbarType.confirm,
      action: action
    );
  }

  void showInformationSnackBar(String message, {SnackBarAction? action}){
    _buildAndShowSnackBar(
      message, 
      DashSnackbarType.information,
      action: action,
    );
  }

  void showWarningSnackBar(String message, {SnackBarAction? action}){
    _buildAndShowSnackBar(
      message, 
      DashSnackbarType.warning,
      action: action,
    );
  }
}

enum DashSnackbarType {
  error,
  confirm,
  information,
  warning
}