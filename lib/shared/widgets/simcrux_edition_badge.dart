// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:simcrux/core/license/simcrux_license_badge_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux-flavored wrapper around the cross-suite
/// `package:crux_license/crux_license.dart` [EditionBadge].
///
/// Reads [L10N] from the current [BuildContext] and supplies a
/// [SimCruxLicenseBadgeStrings] adapter so the package widget renders the
/// localized EDU chip without each call site constructing the adapter
/// itself.
///
/// States the edition in force — EDU, PRO or ENT — and renders nothing at
/// open core. It takes no tier: the package widget reads
/// `licenseTierProvider` itself, because a statement about what the user owns
/// has exactly one correct source.
class SimCruxEditionBadge extends StatelessWidget {
  /// Creates an edition badge for the licence currently in force.
  const SimCruxEditionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return EditionBadge(
      strings: SimCruxLicenseBadgeStrings(L10N.of(context)),
    );
  }
}
