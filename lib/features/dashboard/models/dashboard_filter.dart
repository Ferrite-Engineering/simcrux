// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// User-driven filter state for the dashboard's results table.
///
/// Held in [dashboardFilterProvider] and consumed by
/// `filteredResultRowsProvider`. Empty sets / null / empty-string
/// fields mean "no constraint on this axis." The filter is applied
/// after the run-level results land in `currentRun`, so the table
/// updates as new results arrive without re-running the filter logic
/// for already-displayed rows.
@immutable
class DashboardFilter {
  /// Creates a [DashboardFilter].
  DashboardFilter({
    Set<TestStatus>? statuses,
    Set<String>? suites,
    Set<String>? simulators,
    this.testNameSubstring = '',
    this.minRuntime,
    this.maxRuntime,
  }) : statuses = Set<TestStatus>.unmodifiable(
         statuses ?? const <TestStatus>{},
       ),
       suites = Set<String>.unmodifiable(suites ?? const <String>{}),
       simulators = Set<String>.unmodifiable(simulators ?? const <String>{});

  /// Empty filter (no constraints) — equivalent to the all-rows view.
  static final DashboardFilter unset = DashboardFilter();

  /// Allowed statuses. Empty = all.
  final Set<TestStatus> statuses;

  /// Allowed suite names. Empty = all.
  final Set<String> suites;

  /// Allowed simulator ids. Empty = all.
  final Set<String> simulators;

  /// Substring match against the test id (case-insensitive). Empty
  /// string = no filter.
  final String testNameSubstring;

  /// Minimum runtime, inclusive. Null = no lower bound.
  final Duration? minRuntime;

  /// Maximum runtime, inclusive. Null = no upper bound.
  final Duration? maxRuntime;

  /// Returns a copy with the given fields replaced. Pass an empty
  /// set / empty string / null to clear a specific axis.
  DashboardFilter copyWith({
    Set<TestStatus>? statuses,
    Set<String>? suites,
    Set<String>? simulators,
    String? testNameSubstring,
    Duration? minRuntime,
    Duration? maxRuntime,
  }) {
    return DashboardFilter(
      statuses: statuses ?? this.statuses,
      suites: suites ?? this.suites,
      simulators: simulators ?? this.simulators,
      testNameSubstring: testNameSubstring ?? this.testNameSubstring,
      minRuntime: minRuntime ?? this.minRuntime,
      maxRuntime: maxRuntime ?? this.maxRuntime,
    );
  }

  /// True when no field constrains the result set.
  bool get isUnset =>
      statuses.isEmpty &&
      suites.isEmpty &&
      simulators.isEmpty &&
      testNameSubstring.isEmpty &&
      minRuntime == null &&
      maxRuntime == null;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DashboardFilter) return false;
    if (other.testNameSubstring != testNameSubstring) return false;
    if (other.minRuntime != minRuntime) return false;
    if (other.maxRuntime != maxRuntime) return false;
    if (other.statuses.length != statuses.length) return false;
    if (!statuses.containsAll(other.statuses)) return false;
    if (other.suites.length != suites.length) return false;
    if (!suites.containsAll(other.suites)) return false;
    if (other.simulators.length != simulators.length) return false;
    if (!simulators.containsAll(other.simulators)) return false;
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(statuses),
    Object.hashAllUnordered(suites),
    Object.hashAllUnordered(simulators),
    testNameSubstring,
    minRuntime,
    maxRuntime,
  );
}
