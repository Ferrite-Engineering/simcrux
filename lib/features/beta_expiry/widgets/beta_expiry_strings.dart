// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Binds SimCrux's ARB keys to `crux_license`'s [CruxBetaExpiryStrings] seam.
///
/// The banner itself used to be a hand-copy in every product; it now lives in
/// `crux_license` as [CruxBetaExpiryBanner], parameterized by this interface so
/// the shared widget never bakes in English. All three keys already existed —
/// adopting the shared banner was a re-binding, not a translation job.
class SimcruxBetaExpiryStrings extends CruxBetaExpiryStrings {
  /// Wraps a resolved [L10N].
  const SimcruxBetaExpiryStrings(this._l10n);

  final L10N _l10n;

  @override
  String bannerMessage(int days) => _l10n.betaExpiryBannerMessage(days);

  @override
  String get bannerAction => _l10n.betaExpiryBannerAction;

  @override
  String get dismissLabel => _l10n.betaExpiryDismissLabel;
}
