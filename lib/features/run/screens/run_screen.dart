// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Placeholder for a single regression run's detail view.
///
/// Reached via the `/projects/:projectId/runs/:runId` route. Only a stub,
/// so the URL stays bookmarkable; the inspector pane and run-level summary
/// live in the workspace dashboard.
class RunScreen extends StatelessWidget {
  /// Creates a [RunScreen] for the given [projectId] / [runId].
  const RunScreen({
    required this.projectId,
    required this.runId,
    super.key,
  });

  /// Path parameter from the `/projects/:projectId/...` route.
  final String projectId;

  /// Path parameter from the `runs/:runId` route segment.
  final String runId;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.runScreenTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l10n.runScreenPlaceholder,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
