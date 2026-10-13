// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Listens to [autoReloadNotifierProvider] and shows the suite's
/// source-changed prompt (`showCruxReloadPrompt`: Ignore / Re-run now)
/// whenever the prompt-mode notifier has pending changes.
///
/// Inserted as the body wrapper of the project screen. The name predates the
/// shared banner, which replaced a snackbar that could not be declined.
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
  @override
  Widget build(BuildContext context) {
    ref.listen<AutoReloadState>(autoReloadNotifierProvider, (prev, next) {
      if (next.pendingPaths.isEmpty) return;
      _showPrompt(context);
    });
    return widget.child;
  }

  /// The suite's source-changed prompt, the same banner in every product. It
  /// stays until the user chooses, and asks once however many changes land
  /// while it is up. Ignore clears the pending paths; Re-run now re-runs.
  void _showPrompt(BuildContext context) {
    final l10n = L10N.of(context);
    final notifier = ref.read(autoReloadNotifierProvider.notifier);
    showCruxReloadPrompt(
      context,
      message: l10n.watcherAutoReloadBanner,
      reloadLabel: l10n.watcherAutoReloadActionRerun,
      ignoreLabel: l10n.fileWatcherIgnore,
      // Either choice settles the prompt: rerun() clears the pending paths
      // only when a project is loaded.
      onReload: () {
        notifier.dismiss();
        unawaited(notifier.rerun());
      },
      onIgnore: notifier.dismiss,
    );
  }
}
