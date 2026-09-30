// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/dashboard_view_mode.dart';

/// The dashboard's active view mode. Persisted alongside other UI
/// state in the per-tab workspace payload
/// (`SimcruxTabPayload.viewMode`) and the `.simcrux-session` export.
final NotifierProvider<DashboardViewModeNotifier, DashboardViewMode>
dashboardViewModeProvider =
    NotifierProvider<DashboardViewModeNotifier, DashboardViewMode>(
      DashboardViewModeNotifier.new,
    );

/// Notifier backing [dashboardViewModeProvider].
class DashboardViewModeNotifier extends Notifier<DashboardViewMode> {
  @override
  DashboardViewMode build() => DashboardViewMode.table;

  /// Replace the active view mode.
  ///
  /// Records `dashboard.view_changed` only on an actual change. The segmented
  /// control calls this with the already-active mode whenever the user taps
  /// the selected segment, and counting that would answer "how often is this
  /// control touched" rather than the question the counter exists for — does the
  /// heatmap earn its place.
  void setMode(DashboardViewMode mode) {
    if (state == mode) return;
    state = mode;
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'dashboard.view_changed',
            properties: <String, Object?>{'mode': telemetryEnumToken(mode)},
          ),
        );
  }
}
