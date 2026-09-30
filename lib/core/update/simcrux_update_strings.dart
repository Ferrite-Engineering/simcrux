// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_updates/crux_updates.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter satisfying `package:crux_updates`' [CruxUpdateStrings] interface
/// from SimCrux's ARB-generated [L10N].
///
/// crux-shared packages carry no ARB files — every user-visible string reaches
/// them through a caller-supplied string bundle, the same
/// `LicenseBadgeStrings` / [CruxAboutStrings]-style seam the suite already
/// uses. The product name is baked into SimCrux's own ARB entry
/// (`"SimCrux {version} is available."`), which is why
/// [bannerMessage] receives only the version.
class SimcruxUpdateStrings extends CruxUpdateStrings {
  /// Creates an adapter reading localized update strings from [_l10n].
  const SimcruxUpdateStrings(this._l10n);

  final L10N _l10n;

  @override
  String bannerMessage(String version) => _l10n.updateBannerMessage(version);

  @override
  String get viewChangesAction => _l10n.updateViewChangesAction;

  @override
  String get updateNowAction => _l10n.updateNowAction;

  @override
  String get dismissLabel => _l10n.updateDismissLabel;

  @override
  String get checkInProgress => _l10n.updateCheckInProgress;

  @override
  String checkUpToDate(String version) => _l10n.updateCheckUpToDate(version);

  @override
  String get checkFailed => _l10n.updateCheckFailed;
}
