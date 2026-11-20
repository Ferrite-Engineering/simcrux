// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter satisfying `crux_license`'s [CruxEduNoticeStrings] from SimCrux's
/// ARB-generated [L10N]: the status-bar chip's label and tooltip.
///
/// The `eduNotice*` ARB keys ship across en / zh_CN / zh / ja / ko; this
/// adapter is the only seam between them and the package. Same shape as
/// `SimCruxLicenseBadgeStrings`, the seam for the edition chips.
///
/// The export mark is not localized: every EDACrux export is an English
/// document, and the line stamped on it is English with it. [exportMark]
/// returns the package's English so this class still satisfies the whole
/// interface; the export paths call `cruxEduExportMark` with the default
/// strings directly.
class SimCruxEduNoticeStrings extends CruxEduNoticeStrings {
  /// Creates an adapter that reads the localized notice from [_l10n].
  const SimCruxEduNoticeStrings(this._l10n);

  final L10N _l10n;

  @override
  String get statusLabel => _l10n.eduNoticeStatusLabel;

  @override
  String statusTooltip({String? email, String? validUntil}) =>
      _l10n.eduNoticeStatusTooltip(
        email == null ? 'false' : 'true',
        email ?? '',
        validUntil == null ? 'false' : 'true',
        validUntil ?? '',
      );

  @override
  String exportMark(String productName) =>
      const CruxEduNoticeStringsEn().exportMark(productName);
}
