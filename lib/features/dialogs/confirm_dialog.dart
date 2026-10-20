// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
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
  final confirmed = await showCruxDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return CruxDialog(
        key: const Key('confirmDialog'),
        title: title,
        width: 400,
        content: Text(body),
        actions: [
          CruxDialogAction(
            key: const Key('confirmDialogCancel'),
            label: cancelLabel,
            // The safe choice takes focus when the confirm destroys state.
            autofocus: confirmIsDestructive,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          // Suite-standard destructive emphasis: an error-filled button,
          // not error-coloured text.
          CruxDialogAction(
            key: const Key('confirmDialogConfirm'),
            label: confirmLabel,
            role: confirmIsDestructive
                ? CruxDialogActionRole.destructive
                : CruxDialogActionRole.primary,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
