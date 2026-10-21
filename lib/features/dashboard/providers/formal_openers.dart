// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for one of the Pro formal analysis screens.
///
/// Receives a [BuildContext] anchored at the invocation site so the
/// override can decide whether to push a route, open a dialog or attach the
/// screen to the active pane.
typedef FormalScreenOpener = void Function(BuildContext context);

// The four Pro formal seams, in one file so every one is reachable from the
// action handler that reads the first.
//
// **Open-core default: null.** Each screen is Pro analysis over a result set
// that is not gated at all: the `sby` and `riscv_formal` drivers, the
// four-bucket Verdict column, the per-property rows and the counterexample
// hand-off render in an unlicensed build. These providers exist only to
// mount an additional screen, never to condition a verdict. Do not move a
// tier check onto a driver, an importer or the results table because one
// lives on the other side of these seams.
//
// **Pro override.** The overlay's `proOverrides` replaces each with a
// callback that checks `proFeatureUnlocked` (`betaPeriodProvider` and
// `licenseTierProvider`) and either mounts the screen or calls
// `showProUpgradeDialog` with the matching `SimcruxGatedFeature`. The opener
// is the single gate for every caller.

/// The formal properties dashboard: rollups by task, kind and bucket, the
/// depth pair, wall time. Gate `SimcruxGatedFeature.formalDashboard`.
///
/// Read by View > Formal Properties…, which answers "requires SimCrux Pro"
/// while this is null.
final Provider<FormalScreenOpener?> formalPropertiesOpenerProvider =
    Provider<FormalScreenOpener?>((ref) => null);

/// Proof history per property, verdict-flip and proof-time regressions and
/// the engine comparison. Gate `SimcruxGatedFeature.formalHistory`.
final Provider<FormalScreenOpener?> formalHistoryOpenerProvider =
    Provider<FormalScreenOpener?>((ref) => null);

/// The pre-trace `$past` analysis and vacuity. Gate
/// `SimcruxGatedFeature.formalPretrace`. The one-line pre-trace marker on a
/// row is open core and does not go through this seam.
final Provider<FormalScreenOpener?> pretraceAnalysisOpenerProvider =
    Provider<FormalScreenOpener?>((ref) => null);

/// The EQY partition explorer. Gate `SimcruxGatedFeature.eqyExplorer`. The
/// per-partition status of an EQY row is open core and does not go through
/// this seam.
final Provider<FormalScreenOpener?> eqyExplorerOpenerProvider =
    Provider<FormalScreenOpener?>((ref) => null);
