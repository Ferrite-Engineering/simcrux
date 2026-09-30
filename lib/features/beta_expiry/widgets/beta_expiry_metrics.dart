// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Sizing constants for the beta-expiry banner and blocking modal.
///
/// SimCrux is desktop-first with a desktop-class web viewer and has no
/// `MobileMetrics`-style device-class system (see `CLAUDE.md` → Platform
/// Targets), so the WaveCrux reference's `MobileMetrics.of(context,
/// deviceClass)` lookup collapses to these constants. They are the desktop
/// values WaveCrux resolves to, and they already clear the suite-wide 44 dp
/// accessibility floor.
library;

/// Minimum hit-area edge (dp) for every interactive affordance in the
/// beta-expiry surfaces. The suite-wide accessibility floor is 44 dp — never
/// lower this.
const double kBetaExpiryTouchTarget = 44;

/// Icon size (dp) for the banner's leading glyph and its dismiss button.
const double kBetaExpiryIconSize = 20;

/// Font size (dp) for the banner message and the modal body.
const double kBetaExpiryBodyFontSize = 13;
