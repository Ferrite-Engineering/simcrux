// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Placeholder for a single test's detail view.
///
/// Reached via the `/projects/:projectId/runs/:runId/tests/:testId`
/// route. Only a stub, so the URL stays bookmarkable; the log preview,
/// "Re-run", and "Open waveform" actions live in the workspace inspector.
class TestDetailScreen extends StatelessWidget {
  /// Creates a [TestDetailScreen] for the given path parameters.
  const TestDetailScreen({
    required this.projectId,
    required this.runId,
    required this.testId,
    super.key,
  });

  /// Path parameter from the `/projects/:projectId/...` route.
  final String projectId;

  /// Path parameter from the `runs/:runId/...` route segment.
  final String runId;

  /// Path parameter from the `tests/:testId` route segment.
  final String testId;

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.testDetailScreenTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l10n.testDetailScreenPlaceholder,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
