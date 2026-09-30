// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/providers/pane_render_stats_provider.dart';

void main() {
  group('PaneRenderStats', () {
    test('empty sentinel has zeroed counters and null timestamp', () {
      expect(PaneRenderStats.empty.lastPaintMs, 0);
      expect(PaneRenderStats.empty.sampleCount, 0);
      expect(PaneRenderStats.empty.lastFrameTimestamp, isNull);
    });
  });

  group('PaneRenderStatsNotifier', () {
    test('build returns the empty sentinel', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(paneRenderStatsProvider), PaneRenderStats.empty);
    });

    test('recordPaint bumps sampleCount and updates lastPaintMs + '
        'timestamp', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(paneRenderStatsProvider.notifier);
      final now = DateTime(2026, 5, 24, 12);
      notifier.recordPaint(paintMs: 7, when: now);
      final stats = container.read(paneRenderStatsProvider);
      expect(stats.lastPaintMs, 7);
      expect(stats.sampleCount, 1);
      expect(stats.lastFrameTimestamp, now);

      notifier.recordPaint(
        paintMs: 9,
        when: now.add(const Duration(seconds: 1)),
      );
      final stats2 = container.read(paneRenderStatsProvider);
      expect(stats2.lastPaintMs, 9);
      expect(stats2.sampleCount, 2);
    });

    test('reset clears samples back to the empty sentinel', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(paneRenderStatsProvider.notifier)
        ..recordPaint(paintMs: 7, when: DateTime(2026))
        ..reset();
      expect(container.read(paneRenderStatsProvider), PaneRenderStats.empty);
    });
  });
}
