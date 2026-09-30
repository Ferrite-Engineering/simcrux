// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro RISC-V formal property dashboard.
///
/// Receives a [BuildContext] anchored at the invocation site so the
/// override can decide whether to push a route, mount a modal dialog,
/// or attach the screen to the active pane.
typedef RiscvFormalOpener = void Function(BuildContext context);

/// Extension-point seam the Pro overlay uses to mount the RISC-V formal
/// property dashboard.
///
/// **Open-core default.** Returns `null` — the check-set coverage
/// rollup, the proof-depth reporting and the counterexample hand-off are
/// the *analysis* layer and are Pro. No open-core surface reads this
/// provider; its only caller is the Pro overlay's own toolbar button.
///
/// **What this seam does NOT gate, and must never gate.** The formal
/// **verdict**. `riscv_formal` runs, reads `sby`'s `DONE (…)` line,
/// classifies every bounded proof and records the whole `riscv.formal.*`
/// metric set — plus the counterexample VCD on
/// `TestResult.waveformPath` — with no license, no row cap and no
/// post-`kBetaPeriod` gate, and the ordinary dashboard renders every one
/// of those rows in an unlicensed build. A proof that says a property
/// does not hold is correctness, and correctness is free. This
/// provider therefore exists **only** to mount an additional analysis
/// screen — never to condition the results themselves. Do not
/// "consistency-fix" a tier check onto the driver, the importer, the
/// `SbyLogReader` or the config loader because this provider has one on
/// the other side.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces this
/// provider with a callback that mounts `RiscvFormalScreen` and layers
/// the `proFeatureUnlocked` (`betaPeriodProvider` + `licenseTierProvider`)
/// check on top, so post-beta openCore builds see the upgrade dialog
/// rather than the screen. **The opener is the single authoritative
/// gate** for every caller — today the Pro toolbar button; any later
/// caller inherits the same gate — exactly as
/// `riscvCompatibilityOpenerProvider` and
/// `seedFailureHeatmapOpenerProvider` established.
final Provider<RiscvFormalOpener?> riscvFormalOpenerProvider =
    Provider<RiscvFormalOpener?>(
      (ref) => null,
    );
