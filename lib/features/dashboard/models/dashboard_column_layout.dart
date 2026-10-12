// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';

/// The results table's column widths, as relative weights.
///
/// Weights rather than pixels: the resizable columns always share the
/// width the fixed columns leave exactly, so a narrow pane never opens a
/// gap and a wide one never leaves one. Resizing moves width between two
/// neighbouring columns ([resize]), which keeps the total, and so every
/// other column, unchanged.
///
/// The check box column is fixed-width and not part of the layout.
@immutable
class DashboardColumnLayout {
  /// Creates a layout from [weights]. A column missing from [weights], or
  /// carrying a weight that is not a positive finite number, takes its
  /// default.
  DashboardColumnLayout(Map<DashboardSortColumn, double> weights)
    : weights = Map<DashboardSortColumn, double>.unmodifiable({
        for (final column in columns)
          column: _valid(weights[column]) ?? defaultWeights[column]!,
      });

  /// The resizable columns, left to right.
  static const List<DashboardSortColumn> columns = [
    DashboardSortColumn.status,
    DashboardSortColumn.suite,
    DashboardSortColumn.testName,
    DashboardSortColumn.simulator,
    DashboardSortColumn.duration,
    DashboardSortColumn.startedAt,
  ];

  /// The layout every table starts with. Status, Simulator and Duration
  /// are wide enough for their headers to read in full at the default pane
  /// width.
  static const Map<DashboardSortColumn, double> defaultWeights = {
    DashboardSortColumn.status: 1.2,
    DashboardSortColumn.suite: 2,
    DashboardSortColumn.testName: 3,
    DashboardSortColumn.simulator: 1.4,
    DashboardSortColumn.duration: 1.2,
    DashboardSortColumn.startedAt: 1.6,
  };

  /// The default layout.
  static final DashboardColumnLayout defaults = DashboardColumnLayout(
    defaultWeights,
  );

  /// The narrowest a column may be dragged, in logical pixels: the header's
  /// 16 px padding and the sorted column's 18 px arrow still leave a few
  /// characters of label.
  static const double minColumnWidth = 56;

  /// Each resizable column's weight.
  final Map<DashboardSortColumn, double> weights;

  /// The sum of every column's weight.
  double get totalWeight => weights.values.fold(0, (a, b) => a + b);

  /// Whether [column] has a width in this layout.
  static bool isResizable(DashboardSortColumn column) =>
      columns.contains(column);

  /// The integer flex for [column], fine-grained enough that a one-pixel
  /// drag moves a divider.
  int flexOf(DashboardSortColumn column) =>
      (weights[column]! * 1000).round().clamp(1, 1 << 30);

  /// Moves [dx] logical pixels of width from the column after [column] to
  /// [column] (a negative [dx] moves it the other way), in a table whose
  /// resizable columns span [tableWidth] pixels. Neither column goes below
  /// [minColumnWidth]. Returns this layout when [column] is the last one,
  /// is not resizable, or nothing can move.
  DashboardColumnLayout resize(
    DashboardSortColumn column,
    double dx,
    double tableWidth,
  ) {
    final index = columns.indexOf(column);
    if (index < 0 || index >= columns.length - 1 || tableWidth <= 0) {
      return this;
    }
    final next = columns[index + 1];
    final perPixel = totalWeight / tableWidth;
    final minWeight = minColumnWidth * perPixel;
    final pair = weights[column]! + weights[next]!;
    if (pair < 2 * minWeight) return this;
    final left = (weights[column]! + dx * perPixel).clamp(
      minWeight,
      pair - minWeight,
    );
    if (left == weights[column]) return this;
    return DashboardColumnLayout({
      ...weights,
      column: left,
      next: pair - left,
    });
  }

  static double? _valid(double? weight) =>
      weight != null && weight.isFinite && weight > 0 ? weight : null;

  @override
  bool operator ==(Object other) =>
      other is DashboardColumnLayout &&
      columns.every((c) => other.weights[c] == weights[c]);

  @override
  int get hashCode => Object.hashAll(columns.map((c) => weights[c]));

  @override
  String toString() => 'DashboardColumnLayout($weights)';
}
