// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Adapter satisfying `package:crux_issue_reporter`'s
/// [CruxIssueReporterStrings] interface from SimCrux's ARB-generated [L10N].
///
/// Only the *chrome* the user sees is localized here — the dialog title, the
/// category tiles, the buttons, the toasts. The markdown field labels inside
/// the generated issue body (`**App version:**`, `**Configured simulators:**`,
/// …) are deliberately English: that body is read by maintainers in the GitHub
/// repository, and a mixed-language body makes triage harder. That is the
/// shared package's documented contract, and the same choice WaveCrux made.
class SimcruxIssueReporterStrings extends CruxIssueReporterStrings {
  /// Creates an adapter reading localized reporter strings from [_l10n].
  const SimcruxIssueReporterStrings(this._l10n);

  final L10N _l10n;

  @override
  String get dialogTitle => _l10n.issueReporterTitle;

  @override
  String get titleFieldLabel => _l10n.issueReporterTitleFieldLabel;

  @override
  String get titleFieldHint => _l10n.issueReporterTitleFieldHint;

  @override
  String get privacyNotice => _l10n.issueReporterPrivacyNotice;

  @override
  String get previewHeader => _l10n.issueReporterPreviewHeader;

  @override
  String get categoryAppEnv => _l10n.issueReporterCategoryAppEnv;

  @override
  String get categoryAppEnvDescription =>
      _l10n.issueReporterCategoryAppEnvDescription;

  @override
  String get categorySession => _l10n.issueReporterCategorySession;

  @override
  String get categorySessionDescription =>
      _l10n.issueReporterCategorySessionDescription;

  @override
  String get categoryLog => _l10n.issueReporterCategoryLog;

  @override
  String get categoryLogDescription =>
      _l10n.issueReporterCategoryLogDescription;

  @override
  String get categoryScreenshot => _l10n.issueReporterCategoryScreenshot;

  @override
  String get categoryScreenshotDescription =>
      _l10n.issueReporterCategoryScreenshotDescription;

  @override
  String get lockedCategorySemantics =>
      _l10n.issueReporterLockedCategorySemantics;

  @override
  String get submitButton => _l10n.issueReporterSubmitButton;

  @override
  String get cancelButton => _l10n.issueReporterCancelButton;

  @override
  String get openedToast => _l10n.issueReporterOpenedToast;

  @override
  String get openedToastPrefilled => _l10n.issueReporterOpenedToastPrefilled;

  @override
  String screenshotSaved(String path) =>
      _l10n.issueReporterScreenshotSaved(path);

  @override
  String get emptyLogPlaceholder => _l10n.issueReporterEmptyLog;

  @override
  String get emptySessionLogPlaceholder => _l10n.issueReporterEmptySessionLog;
}
