// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';

/// Per-tab payload for [`crux_workspace`](https://github.com/Ferrite-Engineering/crux-shared)'s
/// generic `WorkspaceTab<P>`.
///
/// Holds the slice of per-tab state that lives directly in
/// `workspace.json` — the config path the tab points at, plus the bits
/// of dashboard UI state that the user expects to come back to when the
/// workspace is restored (selected test, filter chips, sort column,
/// view mode, expanded suites).
///
/// Heavier per-tab state (the result store snapshot, the in-flight job
/// scheduler, the inspector log buffers) lives in per-tab Riverpod
/// providers and is re-derived from the config file on restore; the
/// payload is the framework-visible summary needed to re-arm those
/// providers on launch.
///
/// This payload is the canonical shape of the per-tab `.simcrux-session`
/// export format (it superseded the earlier standalone single-tab
/// session model), so the workspace document and the session export
/// carry compatible state.
@immutable
class SimcruxTabPayload {
  /// Creates a [SimcruxTabPayload].
  SimcruxTabPayload({
    required this.configPath,
    this.selectedTestId,
    Set<TestStatus> filterStatuses = const <TestStatus>{},
    Set<String> filterSuites = const <String>{},
    Set<String> filterSimulators = const <String>{},
    this.filterTestNameSubstring = '',
    this.sort = const DashboardSort(),
    this.viewMode = DashboardViewMode.table,
    Set<String> expandedSuites = const <String>{},
  }) : filterStatuses = Set<TestStatus>.unmodifiable(filterStatuses),
       filterSuites = Set<String>.unmodifiable(filterSuites),
       filterSimulators = Set<String>.unmodifiable(filterSimulators),
       expandedSuites = Set<String>.unmodifiable(expandedSuites);

  /// Absolute path of the `simcrux.yaml` config this tab points at.
  ///
  /// Empty string means "no config opened yet". No live UI path
  /// produces such a tab anymore (the empty-tab "+" and "New Config"
  /// affordances were removed); the tab content widget still renders a
  /// "pick a config" placeholder defensively — e.g. if a restored
  /// `workspace.json` from an older build carries one — rather than
  /// trying to load nothing.
  final String configPath;

  /// The test id last selected in the inspector. Null = no selection.
  final String? selectedTestId;

  /// Active status filter chips.
  final Set<TestStatus> filterStatuses;

  /// Active suite filter chips.
  final Set<String> filterSuites;

  /// Active simulator filter chips.
  final Set<String> filterSimulators;

  /// Free-text substring filter against the flattened `TestSpec.id`.
  final String filterTestNameSubstring;

  /// Sort column + direction for the dashboard results table.
  final DashboardSort sort;

  /// Dashboard view mode (table / heatmap / inspector-focused).
  final DashboardViewMode viewMode;

  /// Suites currently expanded in suite-grouped views.
  final Set<String> expandedSuites;

  /// Returns a copy with the given fields replaced. Pass an empty set
  /// to clear a chip axis; the constructor wraps every set in
  /// `Set.unmodifiable` so callers cannot accidentally mutate them
  /// after the fact.
  SimcruxTabPayload copyWith({
    String? configPath,
    String? selectedTestId,
    bool clearSelectedTestId = false,
    Set<TestStatus>? filterStatuses,
    Set<String>? filterSuites,
    Set<String>? filterSimulators,
    String? filterTestNameSubstring,
    DashboardSort? sort,
    DashboardViewMode? viewMode,
    Set<String>? expandedSuites,
  }) {
    return SimcruxTabPayload(
      configPath: configPath ?? this.configPath,
      selectedTestId: clearSelectedTestId
          ? null
          : (selectedTestId ?? this.selectedTestId),
      filterStatuses: filterStatuses ?? this.filterStatuses,
      filterSuites: filterSuites ?? this.filterSuites,
      filterSimulators: filterSimulators ?? this.filterSimulators,
      filterTestNameSubstring:
          filterTestNameSubstring ?? this.filterTestNameSubstring,
      sort: sort ?? this.sort,
      viewMode: viewMode ?? this.viewMode,
      expandedSuites: expandedSuites ?? this.expandedSuites,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SimcruxTabPayload) return false;
    if (other.configPath != configPath) return false;
    if (other.selectedTestId != selectedTestId) return false;
    if (other.filterTestNameSubstring != filterTestNameSubstring) return false;
    if (other.sort != sort) return false;
    if (other.viewMode != viewMode) return false;
    if (!_setEquals(filterStatuses, other.filterStatuses)) return false;
    if (!_setEquals(filterSuites, other.filterSuites)) return false;
    if (!_setEquals(filterSimulators, other.filterSimulators)) return false;
    if (!_setEquals(expandedSuites, other.expandedSuites)) return false;
    return true;
  }

  @override
  int get hashCode => Object.hash(
    configPath,
    selectedTestId,
    filterTestNameSubstring,
    sort,
    viewMode,
    Object.hashAllUnordered(filterStatuses),
    Object.hashAllUnordered(filterSuites),
    Object.hashAllUnordered(filterSimulators),
    Object.hashAllUnordered(expandedSuites),
  );

  @override
  String toString() =>
      'SimcruxTabPayload(configPath: $configPath, '
      'selectedTestId: $selectedTestId, sort: $sort, viewMode: $viewMode)';

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }
}
