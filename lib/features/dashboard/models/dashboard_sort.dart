// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Column the dashboard's results table is currently sorted on.
///
/// Mirrors the visible columns in the table; the sort dispatcher in
/// `filteredResultRowsProvider` switches on this enum to produce the
/// comparator.
enum DashboardSortColumn {
  /// Status icon column — orders by [TestStatus.index].
  status,

  /// Suite-name column.
  suite,

  /// Test-name column.
  testName,

  /// Simulator id column.
  simulator,

  /// Wall-clock runtime column.
  duration,

  /// Started-at timestamp column.
  startedAt,
}

/// Sort direction.
enum DashboardSortDirection {
  /// Ascending (A→Z, smallest→largest, oldest→newest).
  ascending,

  /// Descending (Z→A, largest→smallest, newest→oldest).
  descending,
}

/// The dashboard's active sort. Default: descending startedAt
/// (most recent first), so an in-flight regression's latest result
/// is always at the top of the table.
@immutable
class DashboardSort {
  /// Creates a [DashboardSort].
  const DashboardSort({
    this.column = DashboardSortColumn.startedAt,
    this.direction = DashboardSortDirection.descending,
  });

  /// The active sort column.
  final DashboardSortColumn column;

  /// The active sort direction.
  final DashboardSortDirection direction;

  /// Returns a copy that sorts on [column], flipping the direction
  /// if [column] is the same as the current one (the standard
  /// "click header twice to reverse" pattern).
  DashboardSort toggle(DashboardSortColumn newColumn) {
    if (newColumn == column) {
      return DashboardSort(
        column: column,
        direction: direction == DashboardSortDirection.ascending
            ? DashboardSortDirection.descending
            : DashboardSortDirection.ascending,
      );
    }
    return DashboardSort(
      column: newColumn,
      direction: DashboardSortDirection.ascending,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DashboardSort &&
        other.column == column &&
        other.direction == direction;
  }

  @override
  int get hashCode => Object.hash(column, direction);
}
