// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_view_mode_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Segmented control above the dashboard table that switches between
/// the table view and the results-grid heatmap.
class DashboardViewModeToggle extends ConsumerWidget {
  /// Creates a [DashboardViewModeToggle].
  const DashboardViewModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final mode = ref.watch(dashboardViewModeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SegmentedButton<DashboardViewMode>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: DashboardViewMode.table,
            icon: const Icon(Icons.table_rows_outlined),
            label: Text(l10n.dashboardViewModeTable),
          ),
          ButtonSegment(
            value: DashboardViewMode.heatmap,
            icon: const Icon(Icons.grid_on_outlined),
            label: Text(l10n.dashboardViewModeHeatmap),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (selection) {
          ref.read(dashboardViewModeProvider.notifier).setMode(selection.first);
        },
      ),
    );
  }
}
