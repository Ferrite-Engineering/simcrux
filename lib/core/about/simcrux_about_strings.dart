// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_about_dialog/crux_about_dialog.dart';
import 'package:crux_license/crux_license.dart';
import 'package:simcrux/core/license/simcrux_license_badge_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter satisfying the `crux_about_dialog` package's [CruxAboutStrings]
/// interface from SimCrux's ARB-generated [L10N].
///
/// The shared [CruxAboutDialog] never bakes in English text — it reads its
/// chrome strings (section headers, info-row labels, the beta chip) from a
/// caller-supplied [CruxAboutStrings], mirroring the `LicenseBadgeStrings`
/// pattern `crux_license` already uses. This adapter maps each getter to the
/// matching SimCrux ARB key and delegates the embedded EDU badge's strings to
/// [SimCruxLicenseBadgeStrings].
///
/// Mirrors `WaveCruxAboutStrings` in the WaveCrux reference implementation.
class SimcruxAboutStrings extends CruxAboutStrings {
  /// Creates an adapter reading localized About-dialog strings from [_l10n].
  const SimcruxAboutStrings(this._l10n);

  final L10N _l10n;

  @override
  String get betaChip => _l10n.aboutBetaChip;

  @override
  String get sectionVersion => _l10n.aboutSectionVersion;

  @override
  String get buildNumberLabel => _l10n.aboutBuildNumber;

  @override
  String get gitShaLabel => _l10n.aboutGitSha;

  @override
  String get sectionPlatform => _l10n.aboutSectionPlatform;

  @override
  String get operatingSystemLabel => _l10n.aboutOperatingSystem;

  @override
  String get architectureLabel => _l10n.aboutArchitecture;

  @override
  String get flutterVersionLabel => _l10n.aboutFlutterVersion;

  @override
  String get dartVersionLabel => _l10n.aboutDartVersion;

  @override
  String get copiedConfirmation => _l10n.aboutCopiedConfirmation;

  @override
  LicenseBadgeStrings get licenseBadgeStrings =>
      SimCruxLicenseBadgeStrings(_l10n);
}
