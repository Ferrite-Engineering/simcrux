// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/features/workspace/providers/pane_render_stats_provider.dart';

/// Produces the SimCrux-specific per-pane Riverpod override list
/// applied on top of the `crux_workspace` package's
/// [`crux.paneIdProvider`] when the framework creates a fresh per-pane
/// `ProviderContainer`.
///
/// Currently scoped to [`paneRenderStatsProvider`]: each pane carries
/// its own paint-time sample buffer so the per-pane segments of the
/// live statistics strip and the
/// Pane Render Stats popover both swap content cleanly when the user
/// focuses a different pane under split-pane.
List<Override> simcruxPaneOverrides(crux.PaneId paneId) {
  return <Override>[
    paneRenderStatsProvider.overrideWith(PaneRenderStatsNotifier.new),
  ];
}
