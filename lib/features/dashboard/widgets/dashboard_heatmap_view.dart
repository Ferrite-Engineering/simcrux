// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Side of one heatmap cell, in logical pixels, before the grid stretches
/// the row to fill the pane's width.
const double _kCellExtent = 18;

/// Gap between cells, both axes.
const double _kCellSpacing = 2;

/// One-cell-per-test heatmap rendering of the active filtered run.
///
/// Cells are ~18×18 dp, colored by test status. Tapping a cell sets
/// the inspector selection so the right pane updates without
/// requiring the user to switch back to the table view first.
///
/// Virtualized, like the sibling [DashboardResultsTable]: a 10 000-row
/// regression is the size this view exists to make legible, and a `Wrap`
/// of 10 000 `Tooltip`s inside a `SingleChildScrollView` builds, lays out
/// and keeps every one of them — including the ~8 000 off screen.
class DashboardHeatmapView extends ConsumerWidget {
  /// Creates a [DashboardHeatmapView].
  const DashboardHeatmapView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final rowsAsync = ref.watch(dashboardRowsProvider);
    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(child: Text(l10n.dashboardError)),
      data: (rows) {
        if (rows.isEmpty) {
          return Center(child: Text(l10n.dashboardEmpty));
        }
        return _Grid(rows: rows);
      },
    );
  }
}

/// The lazily-built cell grid.
///
/// Deliberately **not** a `ConsumerWidget`. It used to watch
/// `selectedTestIdProvider` to decide which cell wore the selection
/// border, which meant every tap rebuilt the entire grid — all 10 000
/// cells to move one border. Each [_Cell] now watches its own
/// selectedness, so a tap rebuilds exactly the two cells that changed.
class _Grid extends StatelessWidget {
  const _Grid({required this.rows});

  final List<DashboardRow> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: _kCellExtent,
          crossAxisSpacing: _kCellSpacing,
          mainAxisSpacing: _kCellSpacing,
        ),
        itemCount: rows.length,
        itemBuilder: (context, index) => _Cell(row: rows[index]),
      ),
    );
  }
}

class _Cell extends ConsumerWidget {
  const _Cell({required this.row});

  final DashboardRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = _colorFor(row.result.status, theme.colorScheme);
    // `select` so a selection change elsewhere in the run rebuilds only
    // the cell that gained or lost the border.
    final selected = ref.watch(
      selectedTestIdProvider.select((id) => id == row.testId),
    );
    return Tooltip(
      message: '${row.suiteName}/${row.testName} · ${row.result.status.name}',
      child: GestureDetector(
        onTap: () {
          ref.read(selectedTestIdProvider.notifier).select(row.testId);
        },
        // A `Container`, not a bare `DecoratedBox`: the status-palette
        // consistency guard reads the cell's decoration off this widget.
        // It carries no width/height — the grid tile sizes it.
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: selected
                ? Border.all(color: theme.colorScheme.onSurface, width: 2)
                : null,
          ),
        ),
      ),
    );
  }

  static Color _colorFor(TestStatus status, ColorScheme scheme) =>
      SimcruxColors.statusColor(status, scheme);
}
