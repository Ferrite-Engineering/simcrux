// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_license/crux_license.dart';
import 'package:crux_status_bar/crux_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/license/simcrux_edu_notice_strings.dart';
import 'package:simcrux/core/license/simcrux_license_badge_strings.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's mount of the cross-suite [CruxEduStatusChip]: the EDU chip,
/// `Non-commercial use` and the holder's address, in the status bar's
/// trailing slot after progress and the extension slot.
///
/// Supplies the localized strings and the bar's own text style, and opens
/// Settings > License on a click through [SettingsScreen.openAdaptive], the
/// same door the licence-expiry strip uses.
///
/// Renders nothing unless the licence in force is educational, so it is
/// mounted unconditionally: open core never sees it, and neither does a
/// Pro or Enterprise licence. The check is repeated here, ahead of the
/// package widget, so the padding that keeps the chip off the window edge
/// is not left behind as a gap when there is no chip.
class SimCruxEduStatusChip extends ConsumerWidget {
  /// Creates the status-bar EDU notice.
  const SimCruxEduStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!cruxIsEduLicense(ref.watch(licenseStatusProvider))) {
      return const SizedBox.shrink();
    }
    final l10n = L10N.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: CruxEduStatusChip(
        strings: SimCruxEduNoticeStrings(l10n),
        badgeStrings: SimCruxLicenseBadgeStrings(l10n),
        textStyle: CruxStatusBar.resolveTextStyle(context),
        onTap: () => unawaited(
          SettingsScreen.openAdaptive(
            context,
            initialCategoryId: kCruxLicenseCategoryId,
          ),
        ),
      ),
    );
  }
}
