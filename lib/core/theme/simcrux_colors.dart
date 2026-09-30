// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// SimCrux brand color tokens.
///
/// The accent color is a muted indigo, deliberately distinct from
/// WaveCrux's teal/cyan, NetCrux's amber, and LintCrux's green. The
/// indigo evokes "process running, work in flight" — fitting for a
/// regression runner whose dashboard is the centerpiece of the app.
///
/// The pass/fail status colors follow universal CI / EDA convention
/// (green / red / amber / blue / gray) and are NOT derived from the
/// brand seed — engineers expect a green dot to mean "pass" regardless
/// of the brand color of the tool around it. The same colors appear
/// in WaveCrux's SVA assertion visualization, so the suite
/// is consistent across tools.
abstract final class SimcruxColors {
  /// Brand seed color used to derive the Material 3 [ColorScheme]. A
  /// muted indigo — darker and less saturated than Material's default
  /// indigo so it reads as an engineering-tool accent rather than a
  /// notification color.
  static const Color brandSeed = Color(0xFF5C6BC0);

  /// Pure-black canvas background used by the dashboard surface in
  /// dark mode. Matches the WaveCrux convention of near-black
  /// engineering-tool backgrounds.
  static const Color darkCanvasBackground = Color(0xFF0F0F10);

  /// Light-mode canvas background.
  static const Color lightCanvasBackground = Color(0xFFFAFAFA);

  // ───────────────────────────────────────────────────────────────────────
  // Universal CI / regression status colors.
  //
  // These are intentionally NOT brand-tinted. Engineers read these the
  // same way across every CI tool, oscilloscope, logic analyzer, and
  // simulator dashboard they have ever used; SimCrux follows convention.
  // ───────────────────────────────────────────────────────────────────────

  /// Test passed.
  static const Color statusPass = Color(0xFF2E7D32);

  /// Test failed (assertion fired, exit-code nonzero, etc.).
  static const Color statusFail = Color(0xFFC62828);

  /// Test passed vacuously (assertion never enabled, antecedent never
  /// held). Mirrors WaveCrux's SVA assertion visualization.
  static const Color statusVacuous = Color(0xFFEF6C00);

  /// Coverage point hit (cover assertion fired). Same hue as the brand
  /// seed but chosen from the universal "cover = blue" convention; the
  /// overlap with the brand is coincidence, not derivation.
  static const Color statusCover = Color(0xFF1976D2);

  /// Skipped / not run.
  static const Color statusSkipped = Color(0xFF9E9E9E);

  /// The single source of truth mapping a [TestStatus] to the hue every
  /// dashboard status surface renders it in — the results-table status
  /// icon, the heatmap cell, the left-pane test-browser icon, and the
  /// web viewer's status chip. Wiring all four through this method is
  /// what keeps a given status one hue across the whole app instead of
  /// four hand-rolled, mutually-inconsistent `Colors.*` palettes.
  ///
  /// The five canonical CI statuses (pass / fail / vacuous / cover /
  /// skipped) resolve to the brand-neutral [statusPass] … [statusSkipped]
  /// tokens above and are theme-independent by design — a green pass dot
  /// reads the same in light and dark mode, matching every other CI tool.
  /// A timeout is a failure sub-type, so it shares the fail hue; the
  /// remaining transient/edge states (running / cancelled / unknown) have
  /// no canonical token and derive from the active [scheme] so they stay
  /// theme-aware.
  static Color statusColor(TestStatus status, ColorScheme scheme) {
    return switch (status) {
      TestStatus.pass => statusPass,
      TestStatus.fail => statusFail,
      TestStatus.vacuous => statusVacuous,
      TestStatus.cover => statusCover,
      TestStatus.skipped => statusSkipped,
      TestStatus.timeout => statusFail,
      TestStatus.running => scheme.primary,
      TestStatus.cancelled => scheme.onSurfaceVariant,
      TestStatus.unknown => scheme.outlineVariant,
    };
  }
}
