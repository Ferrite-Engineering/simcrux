// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Listens to [autoReloadNotifierProvider] and renders a snackbar with
/// "Re-run now / Dismiss" actions whenever the prompt-mode notifier
/// has pending changes.
///
/// Inserted as the body wrapper of the project screen so the snackbar
/// surfaces above the dashboard's content but below the toolbar.
class AutoReloadSnackbarHost extends ConsumerStatefulWidget {
  /// Creates an [AutoReloadSnackbarHost].
  const AutoReloadSnackbarHost({required this.child, super.key});

  /// The host content (typically the [SimcruxIdeLayout]).
  final Widget child;

  @override
  ConsumerState<AutoReloadSnackbarHost> createState() =>
      _AutoReloadSnackbarHostState();
}

class _AutoReloadSnackbarHostState
    extends ConsumerState<AutoReloadSnackbarHost> {
  bool _snackbarShowing = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<AutoReloadState>(autoReloadNotifierProvider, (prev, next) {
      if (next.pendingPaths.isEmpty) return;
      if (_snackbarShowing) return;
      _showSnackbar(context);
    });
    return widget.child;
  }

  void _showSnackbar(BuildContext context) {
    final l10n = L10N.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _snackbarShowing = true;
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${l10n.watcherAutoReloadPromptTitle} — ${l10n.watcherAutoReloadPromptMessage}',
        ),
        action: SnackBarAction(
          label: l10n.watcherAutoReloadActionRerun,
          onPressed: () {
            unawaited(
              ref.read(autoReloadNotifierProvider.notifier).rerun(),
            );
          },
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
      ),
    );
    unawaited(
      controller.closed.whenComplete(() {
        _snackbarShowing = false;
        // If the snackbar timed out without an explicit action,
        // treat it as Dismiss so the pending set clears.
        final state = ref.read(autoReloadNotifierProvider);
        if (state.pendingPaths.isNotEmpty) {
          ref.read(autoReloadNotifierProvider.notifier).dismiss();
        }
      }),
    );
  }
}
