// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter satisfying `crux_license`'s [CruxEduNoticeStrings] from SimCrux's
/// ARB-generated [L10N]: the status-bar chip's label and tooltip, and the
/// mark stamped on a report exported under an educational licence.
///
/// The `eduNotice*` ARB keys ship across en / zh_CN / zh / ja / ko; this
/// adapter is the only seam between them and the package. Same shape as
/// `SimCruxLicenseBadgeStrings`, the seam for the edition chips.
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
      _l10n.eduNoticeExportMark(productName);
}
