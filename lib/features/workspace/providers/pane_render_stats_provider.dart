// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// Per-pane render-pipeline statistics.
///
/// A placeholder shape: the field set mirrors WaveCrux's
/// [`paneRenderStatsProvider`](https://github.com/Ferrite-Engineering/wavecrux/blob/main/lib/features/diagnostics/providers/pane_render_stats_provider.dart)
/// (paint time + last frame timestamp + sample count) so the Pane
/// Render Stats popover and the per-pane segments of the live
/// statistics strip have something to bind against. The canvas-paint
/// instrumentation that fills these fields lives behind the
/// regression-dashboard table / heatmap render path.
@immutable
class PaneRenderStats {
  /// Creates a [PaneRenderStats].
  const PaneRenderStats({
    this.lastPaintMs = 0,
    this.sampleCount = 0,
    this.lastFrameTimestamp,
  });

  /// Sentinel "no samples yet" state, used by both the empty pane and
  /// the very first build inside a newly-created pane container.
  static const PaneRenderStats empty = PaneRenderStats();

  /// Wall-clock milliseconds the last paint pass took. 0 = no samples.
  final int lastPaintMs;

  /// How many frames the collector has timed since the pane opened.
  final int sampleCount;

  /// When the last sample was captured. Null = no samples.
  final DateTime? lastFrameTimestamp;
}

/// Per-pane render-pipeline metrics. Overridden per pane via
/// `simcruxPaneOverrides`; consumers read from the active pane's
/// container.
final NotifierProvider<PaneRenderStatsNotifier, PaneRenderStats>
paneRenderStatsProvider =
    NotifierProvider<PaneRenderStatsNotifier, PaneRenderStats>(
      PaneRenderStatsNotifier.new,
    );

/// Notifier backing [paneRenderStatsProvider]. Used by future
/// canvas-paint instrumentation to publish frame-timing samples per
/// pane.
class PaneRenderStatsNotifier extends Notifier<PaneRenderStats> {
  @override
  PaneRenderStats build() => PaneRenderStats.empty;

  /// Records a paint sample. Bumps [PaneRenderStats.sampleCount] and
  /// replaces [PaneRenderStats.lastPaintMs] / `lastFrameTimestamp`.
  void recordPaint({required int paintMs, required DateTime when}) {
    state = PaneRenderStats(
      lastPaintMs: paintMs,
      sampleCount: state.sampleCount + 1,
      lastFrameTimestamp: when,
    );
  }

  /// Resets the per-pane sample buffer. Called when the pane is
  /// re-armed or when the user clears the strip's history.
  void reset() => state = PaneRenderStats.empty;
}
