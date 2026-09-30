// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/models/dashboard_filter.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// The active [RegressionConfig], or null when no project is open.
///
/// Set by the screen that opens a project (CLI bootstrap, File →
/// Open). Consumed by the dashboard to map a [TestResult.testId]
/// back to its originating [TestSpec] so rows can display the
/// suite name and simulator id.
final NotifierProvider<ActiveConfigNotifier, RegressionConfig?>
activeConfigProvider =
    NotifierProvider<ActiveConfigNotifier, RegressionConfig?>(
      ActiveConfigNotifier.new,
    );

/// Notifier backing [activeConfigProvider].
class ActiveConfigNotifier extends Notifier<RegressionConfig?> {
  @override
  RegressionConfig? build() => null;

  /// Sets the active config (typically called once at project open).
  ///
  /// Kept as an imperative method (not a setter) for symmetry with
  /// [clear] and the other notifier-mutator entry points.
  // ignore: use_setters_to_change_properties
  void replace(RegressionConfig? config) => state = config;

  /// Clears the active config.
  void clear() => state = null;
}

/// The most recent config-load failure for the active project, or
/// `null` when the most recent attempt either succeeded or hasn't
/// completed yet. Populated by
/// `RegressionRunner.startFromConfigPath` on failure so the tab
/// content can render a specific diagnostic naming the failing path
/// and the loader's reason, instead of an opaque "no config"
/// empty state.
///
/// `(path, message)` pairing keeps the tab content honest — the
/// path stamps which fixture failed so users with multiple tabs
/// open can tell at a glance which one broke; the message is the
/// exception's `toString()` (typically `ConfigLoaderException`'s
/// human-readable rendering).
final NotifierProvider<ConfigLoadErrorNotifier, ConfigLoadError?>
configLoadErrorProvider =
    NotifierProvider<ConfigLoadErrorNotifier, ConfigLoadError?>(
      ConfigLoadErrorNotifier.new,
    );

/// Notifier backing [configLoadErrorProvider].
class ConfigLoadErrorNotifier extends Notifier<ConfigLoadError?> {
  @override
  ConfigLoadError? build() => null;

  /// Records a load failure. Cleared automatically the next time
  /// [activeConfigProvider] is populated successfully.
  // ignore: use_setters_to_change_properties
  void record(ConfigLoadError error) => state = error;

  /// Clears the load-error state (called when a load succeeds or
  /// when the user closes the failed tab).
  void clear() => state = null;
}

/// Snapshot of a config-load failure surfaced to the user via
/// [configLoadErrorProvider]. Captures both the path the user tried
/// to load and the human-readable failure reason.
@immutable
class ConfigLoadError {
  /// Creates a [ConfigLoadError].
  const ConfigLoadError({required this.path, required this.message});

  /// The filesystem path the loader was invoked against.
  final String path;

  /// Human-readable failure reason (the exception's `toString()`).
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigLoadError &&
          other.path == path &&
          other.message == message;

  @override
  int get hashCode => Object.hash(path, message);
}

/// The dashboard's filter state.
final NotifierProvider<DashboardFilterNotifier, DashboardFilter>
dashboardFilterProvider =
    NotifierProvider<DashboardFilterNotifier, DashboardFilter>(
      DashboardFilterNotifier.new,
    );

/// Notifier backing [dashboardFilterProvider]. Convenience mutators
/// let widgets toggle a single status / suite / simulator without
/// hand-managing the Set copy-on-write.
class DashboardFilterNotifier extends Notifier<DashboardFilter> {
  @override
  DashboardFilter build() => DashboardFilter.unset;

  /// Replace the entire filter.
  // ignore: use_setters_to_change_properties
  void setAll(DashboardFilter next) => state = next;

  /// Reset to the empty (no constraints) filter.
  void reset() => state = DashboardFilter.unset;

  /// Toggle [status] in the active filter's status set.
  void toggleStatus(TestStatus status) {
    final next = Set<TestStatus>.of(state.statuses);
    if (!next.add(status)) next.remove(status);
    state = state.copyWith(statuses: next);
  }

  /// Toggle [suite] in the active filter's suite set.
  void toggleSuite(String suite) {
    final next = Set<String>.of(state.suites);
    if (!next.add(suite)) next.remove(suite);
    state = state.copyWith(suites: next);
  }

  /// Toggle [simulatorId] in the active filter's simulator set.
  void toggleSimulator(String simulatorId) {
    final next = Set<String>.of(state.simulators);
    if (!next.add(simulatorId)) next.remove(simulatorId);
    state = state.copyWith(simulators: next);
  }

  /// Update the substring-match field.
  void setTestNameSubstring(String substring) {
    state = state.copyWith(testNameSubstring: substring);
  }
}

/// The dashboard's active sort.
final NotifierProvider<DashboardSortNotifier, DashboardSort>
dashboardSortProvider = NotifierProvider<DashboardSortNotifier, DashboardSort>(
  DashboardSortNotifier.new,
);

/// Notifier backing [dashboardSortProvider].
class DashboardSortNotifier extends Notifier<DashboardSort> {
  @override
  DashboardSort build() => const DashboardSort();

  /// Click a column header. If it matches the active column, flip
  /// the direction; otherwise switch to the new column with
  /// ascending order.
  void toggleColumn(DashboardSortColumn column) {
    state = state.toggle(column);
  }

  /// Replace the sort wholesale.
  // ignore: use_setters_to_change_properties
  void setAll(DashboardSort sort) => state = sort;
}

/// Multi-selected dashboard row ids (test ids).
final NotifierProvider<DashboardSelectionNotifier, Set<String>>
dashboardSelectionProvider =
    NotifierProvider<DashboardSelectionNotifier, Set<String>>(
      DashboardSelectionNotifier.new,
    );

/// Notifier backing [dashboardSelectionProvider].
class DashboardSelectionNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  /// Toggle [testId] in the selected set.
  void toggle(String testId) {
    final next = Set<String>.of(state);
    if (!next.add(testId)) next.remove(testId);
    state = Set<String>.unmodifiable(next);
  }

  /// Select [testIds] in addition to any current selection.
  void selectAll(Iterable<String> testIds) {
    final next = Set<String>.of(state)..addAll(testIds);
    state = Set<String>.unmodifiable(next);
  }

  /// Replace the entire selection with [testIds].
  void replaceWith(Iterable<String> testIds) {
    state = Set<String>.unmodifiable(testIds);
  }

  /// Clear the selection.
  void clear() => state = const <String>{};
}

/// Window used to coalesce dashboard recomputation while results
/// stream in. Bursts of `currentRun` events collapse to at most one
/// rows/totals recompute per window (~10 Hz), with the first event of
/// a burst passing through immediately (snappy first paint) and the
/// latest pending event flushed on the trailing edge — so the final
/// state is never dropped or stale.
const Duration kDashboardCoalesceWindow = Duration(milliseconds: 100);

/// Rate-limits [source] to at most one event per [window].
///
/// Leading + trailing edge semantics: an event arriving while no
/// window is open is emitted immediately and opens a window; events
/// arriving inside an open window are conflated to the *latest*,
/// which is emitted when the window elapses (opening the next
/// window). On `done`, any pending latest event is flushed
/// immediately before closing, so the completed-run snapshot always
/// reaches consumers promptly.
///
/// Exposed for direct unit testing; production consumers are the
/// dashboard rows/totals providers below.
@visibleForTesting
Stream<T> coalesceLatest<T>(Stream<T> source, Duration window) {
  late final StreamController<T> controller;
  StreamSubscription<T>? sub;
  Timer? timer;
  T? pending;
  var hasPending = false;
  var done = false;

  void onWindowElapsed() {
    timer = null;
    if (hasPending) {
      final value = pending as T;
      hasPending = false;
      pending = null;
      controller.add(value);
      if (!done) timer = Timer(window, onWindowElapsed);
    }
    if (done && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  controller = StreamController<T>(
    onListen: () {
      sub = source.listen(
        (event) {
          if (timer == null) {
            controller.add(event);
            timer = Timer(window, onWindowElapsed);
          } else {
            pending = event;
            hasPending = true;
          }
        },
        onError: controller.addError,
        onDone: () {
          done = true;
          timer?.cancel();
          timer = null;
          if (hasPending) {
            final value = pending as T;
            hasPending = false;
            pending = null;
            controller.add(value);
          }
          unawaited(controller.close());
        },
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () {
      timer?.cancel();
      timer = null;
      return sub?.cancel();
    },
  );
  return controller.stream;
}

/// Stream of the active run, joined to test specs and filtered /
/// sorted per [dashboardFilterProvider] / [dashboardSortProvider].
final StreamProvider<List<DashboardRow>> dashboardRowsProvider =
    StreamProvider<List<DashboardRow>>(dashboardRows);

/// Body of [dashboardRowsProvider]. Exposed as a top-level function so
/// `simcruxTabOverridesFactory` can override the provider per-tab with
/// the same implementation — see `lib/features/workspace/providers/`.
Stream<List<DashboardRow>> dashboardRows(Ref ref) {
  final store = ref.watch(resultStoreProvider);
  if (store == null) return Stream<List<DashboardRow>>.value(<DashboardRow>[]);
  final config = ref.watch(activeConfigProvider);
  final filter = ref.watch(dashboardFilterProvider);
  final sort = ref.watch(dashboardSortProvider);
  // Memoized per provider build: `ref.watch(activeConfigProvider)`
  // rebuilds this whole provider (and hence the map) whenever the
  // config changes, so the spec index is computed once per config —
  // not once per finished test as before.
  final specsById = _buildSpecsById(config);
  return coalesceLatest(store.currentRun, kDashboardCoalesceWindow).map((run) {
    return _filterAndSortWithSpecs(
      run: run,
      specsById: specsById,
      filter: filter,
      sort: sort,
    );
  });
}

/// Aggregate totals across the active run (unfiltered). Powers the
/// status-bar summary at the bottom of the dashboard.
final StreamProvider<DashboardTotals> dashboardTotalsProvider =
    StreamProvider<DashboardTotals>(dashboardTotals);

/// Body of [dashboardTotalsProvider]. Exposed as a top-level function
/// so `simcruxTabOverridesFactory` can override the provider per-tab
/// with the same implementation.
Stream<DashboardTotals> dashboardTotals(Ref ref) {
  final store = ref.watch(resultStoreProvider);
  if (store == null) {
    return Stream<DashboardTotals>.value(DashboardTotals.empty());
  }
  // Coalesced like dashboardRows: totals rescan the full result list,
  // so recomputing per finished test is O(n²) across a run — at
  // ~10 Hz the cost is bounded regardless of arrival rate.
  return coalesceLatest(
    store.currentRun,
    kDashboardCoalesceWindow,
  ).map(DashboardTotals.fromRun);
}

/// Totals computed from a [TestRun]'s results.
class DashboardTotals {
  /// Creates a [DashboardTotals].
  DashboardTotals({
    required this.total,
    required Map<TestStatus, int> byStatus,
  }) : byStatus = Map<TestStatus, int>.unmodifiable(byStatus);

  /// All-zero totals (no run active).
  factory DashboardTotals.empty() => DashboardTotals(
    total: 0,
    byStatus: const <TestStatus, int>{},
  );

  /// Builds totals from an in-flight or finished [TestRun].
  factory DashboardTotals.fromRun(TestRun run) {
    final counts = <TestStatus, int>{};
    for (final r in run.results) {
      counts.update(r.status, (n) => n + 1, ifAbsent: () => 1);
    }
    return DashboardTotals(
      total: run.testIds.length,
      byStatus: counts,
    );
  }

  /// Total tests scheduled for the run.
  final int total;

  /// Count per [TestStatus] across the run.
  final Map<TestStatus, int> byStatus;

  /// Convenience accessor: count of tests with [status].
  int countOf(TestStatus status) => byStatus[status] ?? 0;
}

/// Applies the dashboard's filter + sort to the active run.
///
/// Exposed for tests. Production callers consume this indirectly
/// via [dashboardRowsProvider], which wires the same logic to the
/// live [resultStoreProvider.currentRun] stream.
@visibleForTesting
List<DashboardRow> filterAndSortDashboardRows({
  required TestRun run,
  required RegressionConfig? config,
  required DashboardFilter filter,
  required DashboardSort sort,
}) => _filterAndSortWithSpecs(
  run: run,
  specsById: _buildSpecsById(config),
  filter: filter,
  sort: sort,
);

/// Every row of [run], joined to its specs, with no filter applied.
///
/// The dashboard's filter is a **view, not a scope**. A user looking at a
/// "failures only" filter still wants an exported JUnit report to say 3 of 400
/// failed, not 3 of 3 — a report that silently redefines the denominator is
/// worse than no report, and CI tooling downstream would read it as a shrunken
/// suite. The Pro PR-annotation dispatcher takes the same position on the same
/// data for the same reason.
///
/// Sorted by the default `startedAt` order rather than the user's active
/// column, so two exports of one run are byte-identical regardless of what the
/// table happened to be sorted by.
List<DashboardRow> allDashboardRows({
  required TestRun run,
  required RegressionConfig? config,
}) => _filterAndSortWithSpecs(
  run: run,
  specsById: _buildSpecsById(config),
  filter: DashboardFilter.unset,
  sort: const DashboardSort(),
);

List<DashboardRow> _filterAndSortWithSpecs({
  required TestRun run,
  required Map<String, TestSpec> specsById,
  required DashboardFilter filter,
  required DashboardSort sort,
}) {
  final rows = <DashboardRow>[];
  for (final result in run.results) {
    final spec = specsById[result.testId];
    final row = DashboardRow(
      result: result,
      suiteName: spec?.suiteName ?? _suitePartOf(result.testId),
      simulatorId: spec?.simulatorId ?? 'unknown',
      testName: spec?.name ?? _namePartOf(result.testId),
    );
    if (!_matches(row, filter)) continue;
    rows.add(row);
  }
  _sort(rows, sort);
  return List<DashboardRow>.unmodifiable(rows);
}

Map<String, TestSpec> _buildSpecsById(RegressionConfig? config) {
  if (config == null) return const <String, TestSpec>{};
  final out = <String, TestSpec>{};
  for (final suite in config.suites) {
    for (final test in suite.tests) {
      out[test.id] = test;
    }
  }
  return out;
}

String _suitePartOf(String testId) {
  final slash = testId.indexOf('/');
  if (slash <= 0) return '';
  return testId.substring(0, slash);
}

String _namePartOf(String testId) {
  final slash = testId.indexOf('/');
  if (slash < 0) return testId;
  return testId.substring(slash + 1);
}

bool _matches(DashboardRow row, DashboardFilter filter) {
  if (filter.statuses.isNotEmpty &&
      !filter.statuses.contains(row.result.status)) {
    return false;
  }
  if (filter.suites.isNotEmpty && !filter.suites.contains(row.suiteName)) {
    return false;
  }
  if (filter.simulators.isNotEmpty &&
      !filter.simulators.contains(row.simulatorId)) {
    return false;
  }
  if (filter.testNameSubstring.isNotEmpty) {
    final needle = filter.testNameSubstring.toLowerCase();
    if (!row.testId.toLowerCase().contains(needle)) return false;
  }
  if (filter.minRuntime != null && row.result.runtime < filter.minRuntime!) {
    return false;
  }
  if (filter.maxRuntime != null && row.result.runtime > filter.maxRuntime!) {
    return false;
  }
  return true;
}

void _sort(List<DashboardRow> rows, DashboardSort sort) {
  int Function(DashboardRow, DashboardRow) keyCmp;
  switch (sort.column) {
    case DashboardSortColumn.status:
      keyCmp = (a, b) => a.result.status.index.compareTo(b.result.status.index);
    case DashboardSortColumn.suite:
      keyCmp = (a, b) => a.suiteName.compareTo(b.suiteName);
    case DashboardSortColumn.testName:
      keyCmp = (a, b) => a.testName.compareTo(b.testName);
    case DashboardSortColumn.simulator:
      keyCmp = (a, b) => a.simulatorId.compareTo(b.simulatorId);
    case DashboardSortColumn.duration:
      keyCmp = (a, b) => a.result.runtime.compareTo(b.result.runtime);
    case DashboardSortColumn.startedAt:
      keyCmp = (a, b) => a.result.startedAt.compareTo(b.result.startedAt);
  }
  rows.sort(
    sort.direction == DashboardSortDirection.ascending
        ? keyCmp
        : (a, b) => -keyCmp(a, b),
  );
}
