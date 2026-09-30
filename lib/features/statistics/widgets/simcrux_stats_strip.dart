// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_stats_strip/crux_stats_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/statistics/providers/job_scheduler_stats_provider.dart';
import 'package:simcrux/features/workspace/providers/pane_render_stats_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's live statistics strip.
///
/// Assembles the shared app-level segments (memory, FPS, frame overruns)
/// with SimCrux's own job-scheduler segments and hands them to the shared
/// [CruxStatsStrip].
///
/// ### Why the job segments are the point
///
/// A regression is not a single-event operation like opening a file — it is
/// a minute-to-hours-long process with continuously evolving state. The
/// scheduler segments are the peripheral-awareness layer for that process:
/// concurrency tells you whether the pool is saturated, queue depth tells
/// you how much is left, throughput tells you whether it is speeding up or
/// grinding, and mean runtime tells you whether a few heavy tests are
/// dominating.
///
/// When no regression is running the job segments **dim rather than
/// disappear**, and their final tallies stay visible. A strip whose segment
/// list changes length every time a run starts and stops makes the layout
/// jump; and after a two-hour regression, the numbers vanishing the instant
/// it completes is the opposite of useful.
class SimcruxStatsStrip extends ConsumerWidget {
  /// Creates the strip.
  const SimcruxStatsStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final frame = ref.watch(cruxFrameStatsProvider);
    final memory = ref.watch(cruxMemoryStatsProvider);
    final jobs = ref.watch(jobSchedulerStatsProvider);
    // Per-pane: each pane keeps its own samples, so switching panes swaps
    // the reading rather than blending two tables' costs into one number.
    final paint = ref.watch(paneRenderStatsProvider);

    final idle = jobs.isRunning
        ? CruxStatEmphasis.normal
        : CruxStatEmphasis.dimmed;

    return CruxStatsStrip(
      label: l10n.statsStripLabel,
      // The caption is the short "Stats"; a screen reader hears the full word.
      semanticLabel: l10n.statisticsStripTitle,
      expandTooltip: l10n.statsStripExpandTooltip,
      collapseTooltip: l10n.statsStripCollapseTooltip,
      segments: <CruxStatSegment>[
        CruxStatSegment(
          label: l10n.statsSegmentMemory,
          value: memory.hasSample ? cruxFormatBytes(memory.residentBytes) : '—',
          sparkline: memory.recentResidentBytes,
          tooltip: l10n.statsSegmentMemoryTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentFps,
          value: frame.sampledFrames == 0
              ? '—'
              : frame.framesPerSecond.toStringAsFixed(1),
          sparkline: frame.recentFrameMillis,
          tooltip: l10n.statsSegmentFpsTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentJank,
          value: '${frame.budgetOverruns}',
          // Any dropped frame is worth noticing, but a handful over a long
          // session is normal; warn only once stutter is a visible fraction
          // of the window.
          emphasis: frame.overrunRatio > 0.05
              ? CruxStatEmphasis.warning
              : CruxStatEmphasis.normal,
          tooltip: l10n.statsSegmentJankTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentRender,
          value: paint.sampleCount == 0 ? '—' : '${paint.lastPaintMs} ms',
          tooltip: l10n.statsSegmentRenderTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentConcurrency,
          value: '${jobs.runningTests}/${jobs.maxConcurrency}',
          emphasis: idle,
          tooltip: l10n.statsSegmentConcurrencyTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentQueue,
          value: '${jobs.queuedTests}',
          emphasis: idle,
          tooltip: l10n.statsSegmentQueueTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentThroughput,
          value: jobs.testsPerMinute <= 0
              ? '—'
              : jobs.testsPerMinute.toStringAsFixed(1),
          sparkline: jobs.recentThroughput,
          emphasis: idle,
          tooltip: l10n.statsSegmentThroughputTooltip,
        ),
        CruxStatSegment(
          label: l10n.statsSegmentMeanRuntime,
          value: jobs.meanRuntimeSeconds <= 0
              ? '—'
              : '${jobs.meanRuntimeSeconds.toStringAsFixed(1)}s',
          emphasis: idle,
          tooltip: l10n.statsSegmentMeanRuntimeTooltip,
        ),
      ],
    );
  }
}
