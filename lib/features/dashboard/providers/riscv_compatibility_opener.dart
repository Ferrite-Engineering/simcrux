// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opener callback for the Pro RISC-V Compatibility Dashboard.
///
/// Receives a [BuildContext] anchored at the invocation site so the
/// override can decide whether to push a route, mount a modal dialog,
/// or attach the screen to the active pane.
typedef RiscvCompatibilityOpener = void Function(BuildContext context);

/// Extension-point seam the Pro overlay uses to mount the RISC-V
/// Compatibility Dashboard.
///
/// **Open-core default.** Returns `null` — the per-extension rollup,
/// the ISA-string attestation and the signature diff viewer are the
/// *analysis* layer and are Pro. No open-core surface reads this
/// provider; its only caller is the Pro overlay's own toolbar button.
///
/// **What this seam does NOT gate, and must never gate.** The
/// compatibility **verdict** is open core. `riscv_arch` runs, classifies
/// and records per-test pass/fail with no license, no row cap and no
/// post-`kBetaPeriod` gate, and the ordinary dashboard renders every one
/// of those rows in an unlicensed build. Compatibility is RVI's own
/// program; monetizing the verdict itself would read as tolling a
/// standard. This provider therefore exists **only** to mount an
/// additional analysis screen — never to condition the results
/// themselves. Do not "consistency-fix" a tier check onto the driver,
/// the detector, the comparator or the config loader because this
/// provider has one on the other side.
///
/// **Pro override.** The Pro overlay's `proOverrides` list replaces this
/// provider with a callback that mounts `RiscvCompatibilityScreen` and
/// layers the `proFeatureUnlocked` (`betaPeriodProvider` +
/// `licenseTierProvider`) check on top, so post-beta openCore builds see
/// the upgrade dialog rather than the screen. **The opener is the single
/// authoritative gate** for every caller — today the Pro toolbar button;
/// any later caller inherits the same gate — exactly as
/// `seedFailureHeatmapOpenerProvider` and `trend_screen_openers.dart`
/// established.
final Provider<RiscvCompatibilityOpener?> riscvCompatibilityOpenerProvider =
    Provider<RiscvCompatibilityOpener?>(
      (ref) => null,
    );
