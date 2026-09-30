// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Parenthetical license-tier suffix for a *native* menu-bar item's label —
/// e.g. `" (PRO)"` / `" (ENT)"`, or an empty string for open-core / edu.
///
/// The platform `PlatformMenuBar` can only render a `String` label (no badge
/// widget), so Pro/Enterprise menu items communicate their required tier with
/// this text suffix. The Flutter surfaces (command palette, overflow menu)
/// render a `SimCruxFeatureTierBadge` widget instead and do not use this.
///
/// Mirrors WaveCrux's `tierLabelSuffix`. `edu` is treated like `openCore`
/// (no suffix) because an EDU license is feature-equivalent to Pro — the
/// user already has access, so no upgrade marker is shown.
String tierLabelSuffix(LicenseTier tier, L10N l10n) => switch (tier) {
  LicenseTier.pro => l10n.menuItemTierSuffix(l10n.tierBadgePro),
  LicenseTier.enterprise => l10n.menuItemTierSuffix(l10n.tierBadgeEnterprise),
  LicenseTier.openCore || LicenseTier.edu => '',
};
