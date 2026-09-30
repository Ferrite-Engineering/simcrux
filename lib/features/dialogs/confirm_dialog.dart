// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

/// Shows a modal yes/no confirmation dialog and resolves to whether the
/// user confirmed.
///
/// Returns `false` when the user cancels, dismisses the barrier, or pops
/// the route — callers can treat a `false` result as "do nothing" without
/// a null check. Destructive actions dispatched from the menu bar /
/// command palette / keyboard (which have no undo affordance) route
/// through here so a mis-keyed chord cannot discard user state.
///
/// [confirmIsDestructive] renders the confirm button in the theme's error
/// colour, matching the platform convention for irreversible actions.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String cancelLabel,
  required String confirmLabel,
  bool confirmIsDestructive = true,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colors = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        key: const Key('confirmDialog'),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const Key('confirmDialogCancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          // Suite-standard destructive emphasis (matches
          // confirmCruxDestructiveAction in crux_ide_layout): an
          // error-FILLED button, not error-colored text — the same visual
          // the other three apps use for Reset Workspace-class confirms.
          FilledButton(
            key: const Key('confirmDialogConfirm'),
            style: confirmIsDestructive
                ? FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
