// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_actions.dart';
import 'package:simcrux/features/inspector/widgets/inspector_details.dart';
import 'package:simcrux/features/inspector/widgets/inspector_header.dart';
import 'package:simcrux/features/inspector/widgets/inspector_log_preview.dart';
import 'package:simcrux/features/inspector/widgets/inspector_trend.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Right-side dashboard pane that renders the currently-selected
/// test's status, key details, recent log lines, the trend sparkline
/// across recent runs, and the per-test action buttons (Re-run,
/// Re-run with waveform, Open full log, Open testbench source, Open
/// waveform).
///
/// Listens to [selectedTestProvider] for the materialized
/// [SelectedTest] snapshot, falling back to the suite-standard
/// [CruxPanelEmptyState] when no test is selected (or when the selected
/// test has no row in the active run yet).
class InspectorPane extends ConsumerWidget {
  /// Creates an [InspectorPane].
  const InspectorPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectedTestProvider);
    if (selection == null) {
      final l10n = L10N.of(context);
      return CruxPanelEmptyState(message: l10n.inspectorEmpty);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InspectorHeader(selection: selection),
          const SizedBox(height: 12),
          InspectorActions(selection: selection),
          const SizedBox(height: 16),
          InspectorDetails(selection: selection),
          const SizedBox(height: 16),
          InspectorLogPreview(selection: selection),
          const SizedBox(height: 16),
          InspectorTrend(selection: selection),
        ],
      ),
    );
  }
}
