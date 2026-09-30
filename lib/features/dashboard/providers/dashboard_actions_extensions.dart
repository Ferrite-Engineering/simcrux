// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Extension-point seam the Pro overlay uses to inject one or more
/// action widgets (icon buttons, dropdowns, etc.) into the dashboard
/// chrome above the filter bar.
///
/// **Open-core default.** Returns an empty list — open-core ships no
/// extra dashboard actions; the dashboard chrome is filter / view-mode
/// chips and nothing else.
///
/// **Pro override.** The Pro overlay populates this provider with:
///
/// - The "Re-run failures" toolbar button (tier-badged; enabled only
///   when the latest run contains at least one failure, per the
///   `parameterizationRerunFailures*` ARB strings).
/// - The "Show seed-failure heatmap" toolbar button (tier-badged;
///   enabled only when at least one parameterized parent spec is
///   present in the latest run).
///
/// **Why a Riverpod provider rather than a const list.** Pro action
/// buttons watch tier providers, the active run, and the result store
/// to compute their enabled/disabled state. Surfacing them through a
/// provider lets the dashboard rebuild when the active tier or run
/// changes without coupling the chrome layout to the Pro feature set.
///
/// **Tier-gating discipline.** Each widget added here is responsible
/// for its own [SimCruxFeatureTierBadge] / [FeatureGate.isAvailable] checks.
/// Open-core consumers of this extension point do not need to bake in
/// tier checks themselves — an open-core build sees an empty list.
final Provider<List<Widget>> extraDashboardActionsProvider =
    Provider<List<Widget>>(
      (ref) => const <Widget>[],
    );
