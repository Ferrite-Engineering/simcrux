// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's localized [CruxEditionLineStrings] adapter, mapping each
/// getter onto the ARB-generated string.
///
/// The line it feeds is the disabled first item of the macOS application menu,
/// above `About SimCrux` — see `CruxDesktopMenuBar.editionLine`. It lives in
/// open core because the menu bar does; the Pro overlay supplies the licence
/// STATUS that decides what the line says, not the words it says it in.
class SimCruxEditionLineStrings extends CruxEditionLineStrings {
  /// Wraps the localizations for the nearest context.
  const SimCruxEditionLineStrings(this._l10n);

  final L10N _l10n;

  @override
  String editionWithIdentity(String edition, String identity) =>
      _l10n.editionMenuLine(edition, identity);

  @override
  String editionLicensedByOrganization(String edition) =>
      _l10n.editionMenuLineOrganization(edition);

  @override
  String get editionNameEdu => _l10n.editionNameEducational;

  @override
  String get editionNamePro => _l10n.editionNamePro;

  @override
  String get editionNameEnterprise => _l10n.editionNameEnterprise;
}
