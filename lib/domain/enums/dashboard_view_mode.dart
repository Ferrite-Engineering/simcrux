// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The dashboard's active results-view mode.
///
/// Persisted per tab inside the workspace (`SimcruxTabPayload`) and
/// exported in the `.simcrux-session` share format. Extracted to its own
/// file when the superseded single-tab `SimcruxSession` model — which the
/// workspace codec replaced — was removed.
enum DashboardViewMode {
  /// The default table view.
  table,

  /// Heatmap (one cell per test, color-coded by status).
  heatmap,

  /// Inspector-focused view (right pane maximized).
  inspectorFocused;

  /// Look up by serialized name, returning the default [table] when
  /// the name is unknown.
  static DashboardViewMode fromName(String? name) {
    for (final mode in DashboardViewMode.values) {
      if (mode.name == name) return mode;
    }
    return DashboardViewMode.table;
  }
}
