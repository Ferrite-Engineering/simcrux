// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:simcrux/core/license/simcrux_license_badge_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux-flavored wrapper around the cross-suite
/// `package:crux_license/crux_license.dart` [FeatureTierBadge].
///
/// Reads [L10N] from the current [BuildContext] and supplies a
/// [SimCruxLicenseBadgeStrings] adapter so the package widget renders
/// localized PRO / ENT labels without each call site constructing the
/// adapter itself. All visual behavior is the package widget's —
/// `SizedBox.shrink` for `openCore` / `edu`, PRO chip in
/// `colorScheme.primary`, ENT chip in `colorScheme.tertiary`.
class SimCruxFeatureTierBadge extends StatelessWidget {
  /// Creates a tier badge labeling a feature that requires [requiredTier].
  const SimCruxFeatureTierBadge({
    required this.requiredTier,
    super.key,
  });

  /// The minimum tier required to use the feature this badge labels.
  final LicenseTier requiredTier;

  @override
  Widget build(BuildContext context) {
    return FeatureTierBadge(
      requiredTier: requiredTier,
      strings: SimCruxLicenseBadgeStrings(L10N.of(context)),
    );
  }
}
