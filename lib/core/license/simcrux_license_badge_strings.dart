// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter satisfying the `crux_license` package's [LicenseBadgeStrings]
/// interface from SimCrux's ARB-generated [L10N].
///
/// The cross-suite [FeatureTierBadge] / [EditionBadge] widgets accept a
/// `LicenseBadgeStrings` so they never bake in English text. SimCrux's
/// `tierBadgePro` / `tierBadgeProSemantic` / `tierBadgeEnterprise` /
/// `tierBadgeEnterpriseSemantic` / `tierBadgeEdu` / `tierBadgeEduSemantic`
/// / the three `editionBadge*Semantic` phrases
/// ARB keys ship across en / zh_CN / zh / ja / ko — this adapter is the
/// only seam between the package widgets and `L10N`.
///
/// Call site:
///
/// ```dart
/// FeatureTierBadge(
///   requiredTier: feature.requiredTier,
///   strings: SimCruxLicenseBadgeStrings(L10N.of(context)),
/// );
/// ```
///
/// Mirrors `WaveCruxLicenseBadgeStrings` in the WaveCrux reference
/// implementation; see `wavecrux/lib/core/license/wavecrux_license_badge_strings.dart`.
class SimCruxLicenseBadgeStrings extends LicenseBadgeStrings {
  /// Creates an adapter that reads localized chip labels from [_l10n].
  const SimCruxLicenseBadgeStrings(this._l10n);

  final L10N _l10n;

  @override
  String get tierBadgePro => _l10n.tierBadgePro;

  @override
  String get tierBadgeProSemantic => _l10n.tierBadgeProSemantic;

  @override
  String get tierBadgeEnterprise => _l10n.tierBadgeEnterprise;

  @override
  String get tierBadgeEnterpriseSemantic => _l10n.tierBadgeEnterpriseSemantic;

  @override
  String get tierBadgeEdu => _l10n.tierBadgeEdu;

  @override
  String get tierBadgeEduSemantic => _l10n.tierBadgeEduSemantic;

  @override
  String get editionBadgeEduSemantic => _l10n.editionBadgeEduSemantic;

  @override
  String get editionBadgeProSemantic => _l10n.editionBadgeProSemantic;

  @override
  String get editionBadgeEnterpriseSemantic =>
      _l10n.editionBadgeEnterpriseSemantic;
}
