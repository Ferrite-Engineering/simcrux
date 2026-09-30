// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// Tiny horizontal sparkline that renders a list of [TestStatus]
/// values (oldest at left, newest at right) as a row of equally-sized
/// colored cells.
///
/// Used in the inspector's trend section and as the per-row badge in
/// the dashboard table.
class TestTrendSparkline extends StatelessWidget {
  /// Creates a [TestTrendSparkline].
  const TestTrendSparkline({
    required this.statuses,
    this.cellWidth = 12,
    this.height = 14,
    this.gap = 1,
    super.key,
  });

  /// Statuses in chronological order (caller passes most-recent-first
  /// data reversed; this widget displays them left-to-right exactly
  /// as provided so the caller controls direction).
  final List<TestStatus> statuses;

  /// Width of each status cell.
  final double cellWidth;

  /// Total widget height.
  final double height;

  /// Pixel gap between cells.
  final double gap;

  @override
  Widget build(BuildContext context) {
    // Wrap so the strip flows to a second row when the parent's width
    // can't accommodate every cell on one line — previously the Row
    // overflowed and silently clipped the rightmost cell, hiding the
    // most-recent (or oldest, depending on caller direction) run from
    // view. Inside the inspector pane (~100–120 dp wide) 10 default
    // cells at 12 dp + 1 dp gap = 129 dp exceeds the slot.
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final status in statuses)
          Container(
            width: cellWidth,
            height: height,
            decoration: BoxDecoration(
              color: _colorFor(status, Theme.of(context).colorScheme),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }

  static Color _colorFor(TestStatus status, ColorScheme scheme) {
    switch (status) {
      case TestStatus.pass:
      case TestStatus.vacuous:
        return Colors.green;
      case TestStatus.fail:
        return scheme.error;
      case TestStatus.timeout:
        return Colors.deepOrange;
      case TestStatus.cancelled:
        return scheme.outline;
      case TestStatus.skipped:
        return scheme.outlineVariant;
      case TestStatus.running:
        return Colors.blueGrey;
      case TestStatus.cover:
        return Colors.indigo;
      case TestStatus.unknown:
        return scheme.surfaceContainerHigh;
    }
  }
}
