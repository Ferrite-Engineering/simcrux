// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_about_dialog/crux_about_dialog.dart';
import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/about/simcrux_about_strings.dart';
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/shared/widgets/glowing_app_icon.dart';
import 'package:url_launcher/url_launcher.dart';

/// The SimCrux About dialog.
///
/// A thin builder over the cross-suite [CruxAboutDialog] (from
/// `crux_about_dialog`): it maps SimCrux's branding / build-info / edition
/// providers and ARB strings onto the shared surface and supplies the
/// SimCrux-specific pieces — the glowing app icon and the canonical suite
/// action row (Visit Website, Documentation, Report Issue, Check for Updates,
/// Privacy Policy, Terms of Service, Copy Version Info). SimCrux ships no
/// third-party attribution section. Tier and beta-period chips are driven by
/// `crux_license` providers inside the shared widget.
abstract final class SimcruxAboutDialog {
  /// Opens the About box: a modal dialog on desktop, a pushed route on mobile.
  /// Re-entrancy guarded ([ModalGuard]) inside the opener so every caller —
  /// menu item, command palette, keyboard shortcut — is covered: a repeated
  /// gesture while the box is open (or while its build info is still
  /// resolving) must not stack a second copy.
  static Future<void> openAdaptive(BuildContext context, WidgetRef ref) =>
      ModalGuard.run('about', () => _openAdaptive(context, ref));

  static Future<void> _openAdaptive(BuildContext context, WidgetRef ref) async {
    final l10n = L10N.of(context);
    final branding = ref.read(aboutBrandingProvider);

    // Resolve build info up front so the version section renders data rather
    // than a perpetual spinner. On failure the shared widget hides the section.
    ApplicationBuildInfo? pkgInfo;
    AsyncValue<ApplicationBuildInfo> buildInfo;
    try {
      final resolved = await ref.read(aboutBuildInfoProvider.future);
      pkgInfo = resolved;
      buildInfo = AsyncValue.data(resolved);
    } on Object catch (error, stackTrace) {
      buildInfo = AsyncValue.error(error, stackTrace);
    }

    if (!context.mounted) return;

    final edition = aboutEditionLabel(ref, l10n);
    // A non-null capture so the Copy Version Info closure stays type-promoted.
    final info = pkgInfo;

    await CruxAboutDialog.show(
      context,
      title: l10n.aboutDialogTitle,
      tagline: l10n.aboutTagline,
      companyTagline: l10n.aboutCompanyName,
      appIcon: const GlowingAppIcon(size: 80),
      branding: branding,
      buildInfo: buildInfo,
      // Hide the edition chip for the open-core edition.
      editionLabel: edition == l10n.aboutEditionOpenCore ? '' : edition,
      strings: SimcruxAboutStrings(l10n),
      actions: [
        AboutAction(
          label: l10n.aboutButtonVisitWebsite,
          icon: Icons.language_outlined,
          onTap: (_) => unawaited(launchUrl(Uri.parse(branding.websiteUrl))),
        ),
        AboutAction(
          label: l10n.aboutButtonDocs,
          icon: Icons.menu_book_outlined,
          onTap: (_) => unawaited(launchUrl(Uri.parse(HelpUrls.docs))),
        ),
        // Beta issue reporter, reachable from the box that already tells the
        // user their version and build SHA — the two facts a report needs.
        AboutAction(
          label: l10n.actionSubmitIssue,
          icon: Icons.bug_report_outlined,
          onTap: (ctx) => unawaited(CruxIssueReporterDialog.openAdaptive(ctx)),
        ),
        // Manual update check: the About box offers one in every build.
        // `runManualUpdateCheck` shows its own snackbars; the dialog stays
        // open so the user can read the version it just confirmed.
        AboutAction(
          label: l10n.actionCheckForUpdates,
          icon: Icons.system_update_alt_outlined,
          onTap: (ctx) => unawaited(runManualUpdateCheck(ctx, ref)),
        ),
        AboutAction(
          label: l10n.aboutButtonPrivacy,
          icon: Icons.privacy_tip_outlined,
          onTap: (_) => unawaited(launchUrl(Uri.parse(HelpUrls.privacyPolicy))),
        ),
        AboutAction(
          label: l10n.aboutButtonTerms,
          icon: Icons.description_outlined,
          onTap: (_) =>
              unawaited(launchUrl(Uri.parse(HelpUrls.termsOfService))),
        ),
        AboutAction(
          label: l10n.aboutButtonCopyVersionInfo,
          icon: Icons.copy_outlined,
          onTap: info == null
              ? null
              : (ctx) => unawaited(_copyVersionInfo(ctx, l10n, edition, info)),
        ),
      ],
    );
  }

  static Future<void> _copyVersionInfo(
    BuildContext context,
    L10N l10n,
    String edition,
    ApplicationBuildInfo info,
  ) async {
    await Clipboard.setData(
      ClipboardData(
        text: aboutVersionInfoText(
          appName: 'SimCrux',
          editionLabel: edition,
          info: info,
        ),
      ),
    );
    if (context.mounted) {
      showCruxInfoSnack(context, l10n.aboutCopiedConfirmation);
    }
  }
}
