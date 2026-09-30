// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro Flaky Tests panel.
///
/// Receives the [BuildContext] anchored at the invocation site so the
/// Pro overlay can decide how to present the panel (a modal dialog
/// today).
typedef FlakyTestsPanelOpener = void Function(BuildContext context);

/// Extension-point seam for the Pro Flaky Tests panel.
///
/// **Open-core default.** Returns `null` — the standalone panel is a Pro
/// surface. The `SimcruxAction.showFlakyTests` menu / command-palette
/// entry stays visible for discoverability (with its Pro tier badge),
/// but firing it is a no-op that surfaces the upgrade snackbar until the
/// Pro overlay registers the opener.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces this
/// provider with a callback that mounts `FlakyTestsPanel` in a dialog,
/// layering a `FeatureGate.isAvailable(LicenseTier.pro, ref)` check on
/// top so post-beta openCore builds see the upgrade dialog rather than
/// the panel.
final Provider<FlakyTestsPanelOpener?> flakyTestsPanelOpenerProvider =
    Provider<FlakyTestsPanelOpener?>((ref) => null);
