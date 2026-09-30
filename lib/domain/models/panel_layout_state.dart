// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Visibility + size state for the four IdeLayout panels.
///
/// The four-pane layout: left = test/run browser, center = run results, right = run
/// details, bottom = log stream. Pane sizes are stored as `double`
/// fractions in (0, 1) so they survive window-size changes without
/// drifting; `panes` interprets them as the initial relative weight
/// when the layout first renders.
///
/// Persisted via [SimcruxSettingsCodec] under the `simcrux.panel.*`
/// key namespace. Forward-compatible: unknown fields are silently
/// ignored on load; missing fields fall back to the defaults below.
@immutable
class PanelLayoutState {
  /// Creates a [PanelLayoutState]. Every field has a documented
  /// default so `const PanelLayoutState()` is the engineering
  /// baseline.
  const PanelLayoutState({
    this.testBrowserVisible = true,
    this.runDetailsVisible = true,
    this.logPanelVisible = true,
    this.testBrowserFraction = defaultLeftFraction,
    this.runDetailsFraction = defaultRightFraction,
    this.logPanelFraction = defaultBottomFraction,
  });

  /// Default fraction of the IdeLayout width given to the left
  /// (test/run browser) pane on first launch.
  static const double defaultLeftFraction = 0.22;

  /// Default fraction of the IdeLayout width given to the right
  /// (run details / inspector) pane on first launch.
  static const double defaultRightFraction = 0.28;

  /// Default fraction of the IdeLayout height given to the bottom
  /// (log stream) pane on first launch.
  static const double defaultBottomFraction = 0.30;

  /// Whether the left test/run browser pane is shown.
  final bool testBrowserVisible;

  /// Whether the right inspector / run details pane is shown.
  final bool runDetailsVisible;

  /// Whether the bottom log-stream pane is shown.
  final bool logPanelVisible;

  /// Test browser pane width as a fraction of the IDE layout width.
  final double testBrowserFraction;

  /// Run details pane width as a fraction of the IDE layout width.
  final double runDetailsFraction;

  /// Log panel height as a fraction of the IDE layout height.
  final double logPanelFraction;

  /// Returns a copy with the given fields replaced.
  PanelLayoutState copyWith({
    bool? testBrowserVisible,
    bool? runDetailsVisible,
    bool? logPanelVisible,
    double? testBrowserFraction,
    double? runDetailsFraction,
    double? logPanelFraction,
  }) {
    return PanelLayoutState(
      testBrowserVisible: testBrowserVisible ?? this.testBrowserVisible,
      runDetailsVisible: runDetailsVisible ?? this.runDetailsVisible,
      logPanelVisible: logPanelVisible ?? this.logPanelVisible,
      testBrowserFraction: testBrowserFraction ?? this.testBrowserFraction,
      runDetailsFraction: runDetailsFraction ?? this.runDetailsFraction,
      logPanelFraction: logPanelFraction ?? this.logPanelFraction,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PanelLayoutState &&
        other.testBrowserVisible == testBrowserVisible &&
        other.runDetailsVisible == runDetailsVisible &&
        other.logPanelVisible == logPanelVisible &&
        other.testBrowserFraction == testBrowserFraction &&
        other.runDetailsFraction == runDetailsFraction &&
        other.logPanelFraction == logPanelFraction;
  }

  @override
  int get hashCode => Object.hash(
    testBrowserVisible,
    runDetailsVisible,
    logPanelVisible,
    testBrowserFraction,
    runDetailsFraction,
    logPanelFraction,
  );
}
