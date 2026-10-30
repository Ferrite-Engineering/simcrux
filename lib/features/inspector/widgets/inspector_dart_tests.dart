// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_dart_test_row.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/simulator/dart_test_metrics.dart';

/// The most cases the inspector lists; the rest are counted in the summary.
const int kInspectorMaxDartTestRows = 40;

/// The cases of a Dart test run in the inspector: one row each, failing cases
/// first, each with a Go to Source button that opens the Dart file at the line.
///
/// Renders nothing for a row that is not a Dart test run.
class InspectorDartTests extends StatelessWidget {
  /// Creates the section for [selection].
  const InspectorDartTests({required this.selection, super.key});

  /// The selected test.
  final SelectedTest selection;

  @override
  Widget build(BuildContext context) {
    final view = DartTestResultView.fromMetrics(selection.result.metrics);
    if (view == null) return const SizedBox.shrink();
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final metrics = selection.result.metrics;
    final failing =
        (int.tryParse(metrics['dart.fail'] ?? '') ?? 0) +
        (int.tryParse(metrics['dart.error'] ?? '') ?? 0);
    final skipped = int.tryParse(metrics['dart.skip'] ?? '') ?? 0;
    // Failing cases first, each group in run order.
    final rows = <DartTestRow>[
      ...view.rows.where((r) => r.failing),
      ...view.rows.where((r) => !r.failing),
    ].take(kInspectorMaxDartTestRows).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        key: const ValueKey('inspectorDartTests'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.inspectorSectionDartTests,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          _Note(l10n.inspectorDartTestsSummary(view.tests, failing, skipped)),
          if (view.objectionWarnings > 0)
            _Note(l10n.inspectorDartTestsObjections(view.objectionWarnings)),
          if (!view.complete) _Note(l10n.inspectorDartTestsIncomplete),
          const SizedBox(height: 4),
          for (final row in rows) InspectorDartTestRow(row: row),
        ],
      ),
    );
  }
}

/// One selectable sentence in the section header.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Semantics(
      label: text,
      child: ExcludeSemantics(
        child: SelectableText(
          text,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ),
  );
}
