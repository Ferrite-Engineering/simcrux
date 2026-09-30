// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';

/// The currently-focused test id (what the inspector pane and the
/// "Re-run selected test" command palette entry both target).
///
/// Single-select. The multi-select bulk-action surface uses
/// [dashboardSelectionProvider]; the inspector pane uses *this*
/// (which is the row most-recently clicked rather than the union of
/// checked checkboxes).
///
/// Set by the dashboard's row tap handler and the CLI bootstrap
/// (which selects the first failed test post-run as a convenience).
final NotifierProvider<SelectedTestNotifier, String?> selectedTestIdProvider =
    NotifierProvider<SelectedTestNotifier, String?>(SelectedTestNotifier.new);

/// Notifier backing [selectedTestIdProvider].
class SelectedTestNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Replace the active selection.
  // ignore: use_setters_to_change_properties
  void select(String? testId) => state = testId;

  /// Clear the active selection (used when closing a project).
  void clear() => state = null;
}

/// The materialized snapshot of the selected test: the latest
/// [TestResult] from the active run and the originating [TestSpec]
/// from the active config (or null when nothing is selected, or the
/// selected test hasn't yet reported a result).
@immutable
class SelectedTest {
  /// Creates a [SelectedTest].
  const SelectedTest({
    required this.row,
    this.spec,
  });

  /// The dashboard row carrying the latest [TestResult] plus the
  /// suite/sim/test name fan-out for header rendering.
  final DashboardRow row;

  /// The originating [TestSpec], or null if the active config no
  /// longer references this test id (e.g. the user changed configs).
  final TestSpec? spec;

  /// Convenience accessor for the underlying test result.
  TestResult get result => row.result;

  /// The full `suite/name` id.
  String get testId => row.testId;
}

/// Materializes the currently-selected test as a [SelectedTest]
/// snapshot. Returns null when no test is selected, or when the
/// active dashboard has no row for the selected test id.
final Provider<SelectedTest?> selectedTestProvider = Provider<SelectedTest?>(
  selectedTest,
);

/// Body of [selectedTestProvider]. Exposed as a top-level function so
/// `simcruxTabOverridesFactory` can override the provider per-tab with
/// the same implementation.
SelectedTest? selectedTest(Ref ref) {
  final id = ref.watch(selectedTestIdProvider);
  if (id == null) return null;
  final rowsAsync = ref.watch(dashboardRowsProvider);
  final rows = rowsAsync.maybeWhen<List<DashboardRow>>(
    data: (rows) => rows,
    orElse: () => const <DashboardRow>[],
  );
  DashboardRow? row;
  for (final candidate in rows) {
    if (candidate.testId == id) {
      row = candidate;
      break;
    }
  }
  if (row == null) return null;

  final config = ref.watch(activeConfigProvider);
  TestSpec? spec;
  if (config != null) {
    for (final suite in config.suites) {
      for (final test in suite.tests) {
        if (test.id == id) {
          spec = test;
          break;
        }
      }
      if (spec != null) break;
    }
  }
  return SelectedTest(row: row, spec: spec);
}
