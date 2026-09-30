// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Decides whether this seat may **originate** a cross-probe, and explains
/// itself when it may not.
///
/// Returns `true` when the send may proceed. When it returns `false` it has
/// already told the user why — a snack bar here, the upgrade dialog in the
/// Pro overlay — so the caller simply returns. A user pressed a button; the
/// one answer that is never acceptable is nothing.
typedef CrossProbeOriginateGate = bool Function(BuildContext context);

/// The gate the cross-probe panel's per-peer send button consults.
///
/// ### Why the panel needs a gate of its own
///
/// Cross-probe *origination* — pointing another product at the selected test
/// — is a Pro capability. The Pro overlay gates its own route to it, the
/// dashboard row's cross-probe menu. But the docked cross-probe panel ships
/// in open core, is mounted from the open-core dock, and carries a send
/// button per discovered peer that reaches the very same capability. Without
/// this seam that button was a second, unguarded route: the paywall existed
/// on one door and not the other.
///
/// The same rule applies to any priced capability whose code lives in open
/// core: the gate lives beside the code, in open core, reading the suite's
/// own tier providers — not in the overlay, where it would only guard the
/// overlay's door.
///
/// ### What the default does
///
/// Admits every tier while the public beta is in effect
/// (`betaPeriodProvider`), and afterwards only a tier that satisfies Pro
/// (`FeatureGate.satisfiesTier`, so EDU and Enterprise pass). A denied press
/// gets the open-core "requires SimCrux Pro" snack — the same feedback an
/// open-core build gives every other Pro-tier action it cannot run.
///
/// The Pro overlay overrides this provider so the denial is the localized
/// upgrade dialog with a *See pricing* action, and records the gate hit.
/// Both branches read the overridable providers, so the post-beta denial is
/// reachable from a test today.
final Provider<CrossProbeOriginateGate> crossProbeOriginateGateProvider =
    Provider<CrossProbeOriginateGate>(
      (ref) => (context) {
        final unlocked =
            ref.read(betaPeriodProvider) ||
            FeatureGate.satisfiesTier(
              LicenseTier.pro,
              ref.read(licenseTierProvider),
            );
        if (unlocked) return true;
        if (!context.mounted) return false;
        final l10n = L10N.of(context);
        showCruxInfoSnack(
          context,
          l10n.snackActionRequiresPro(l10n.crossProbeSendTooltip),
        );
        return false;
      },
      name: 'crossProbeOriginateGateProvider',
    );
