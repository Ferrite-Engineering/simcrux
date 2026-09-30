// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/features/issue_reporter/providers/issue_reporter_session_context.dart';

/// The GitHub repository issue reports are filed against.
///
/// The public open-core repository. Selecting the slug here rather than inside
/// `crux_issue_reporter` keeps per-product routing out of the shared package.
/// It is deliberately *not* keyed off `kBetaPeriod`: that flag governs tier
/// gating and flips on its own schedule, while the issue tracker moved to the
/// open-core repo at the 1.0 launch.
const String simcruxIssueRepositorySlug = 'Ferrite-Engineering/simcrux';

/// SimCrux's binding of the cross-suite beta issue reporter — the **root**
/// half.
///
/// The reporter is **open to every tier** — no `FeatureTierBadge`, no `FeatureGate`.
/// It is a support channel, not a feature, and gating it would mean the users
/// most likely to hit a bug (open-core, during beta) are the ones who cannot
/// report it.
///
/// Spread into `bootstrap()`'s root `ProviderContainer` before
/// `extraOverrides`, so the Pro overlay can layer
/// `cruxIssueReporterDataProviderProvider` (its "Pro State" category) on top.
///
/// Two bindings live elsewhere:
///
/// - `cruxIssueSessionContextProvider` → [simcruxIssueReporterScopedOverrides],
///   because it reaches the per-tab containers. See the doc there.
/// - `cruxIssueReporterStringsProvider` → the widget layer, because it needs a
///   `BuildContext` for `L10N.of` (see `SimcruxApp.build`).
final List<Override> simcruxIssueReporterOverrides = <Override>[
  // Product identity + the repository reports land in. The package default
  // throws, so an unwired build fails loudly rather than filing a user's bug
  // against the wrong repository.
  cruxIssueReporterConfigProvider.overrideWithValue(
    const CruxIssueReporterConfig(
      productName: 'SimCrux',
      repositorySlug: simcruxIssueRepositorySlug,
      issueTemplate: 'bug_report.yml',
    ),
  ),

  // App & Environment category. `null` would omit the category entirely.
  cruxIssueReporterBuildInfoProvider.overrideWith(
    (ref) => ref.watch(aboutBuildInfoProvider).value,
  ),

  // `cruxIssueDiagnosticsReportProvider` is deliberately left at its `null`
  // default. SimCrux's Tab Diagnostics report (`buildTabDiagnosticsReport`,
  // the drawer's Copy button) opens with `Config: <projectFilePath>` — an
  // absolute path. That report is fine on the user's clipboard, where they
  // choose the recipient; folding it into a public GitHub issue body would
  // breach the reporter's no-paths contract. The Diagnostic Log category
  // therefore carries the ring-buffer log only. (The App Diagnostics dialog's
  // copy is the scrubbed session context the reporter already sends.)
];

/// The **scoped** half of the issue-reporter wiring, spread into the same
/// child container that carries `workspaceContainerManagersProvider`.
///
/// This is not a stylistic split. A Riverpod provider materializes in the
/// topmost container that overrides it, and reads its dependencies from
/// *there*. `bootstrap()` builds the container managers only after the root
/// container exists, so `workspaceContainerManagersProvider` can only be
/// overridden in the child. Registering the session contributor in the **root**
/// would therefore materialize it above the managers override, its per-tab
/// lookup would hit the provider's `UnsupportedError` default, the
/// contributor's defensive `catch` would swallow it, and every bug report
/// would silently ship all-zero counts — a report that looks fine and says
/// nothing.
///
/// Consequence for the overlay: the Pro overlay cannot replace
/// `cruxIssueSessionContextProvider` from `proOverrides` (those land in the
/// root, and the child override wins). That is the intended shape — the
/// documented overlay seam is `cruxIssueReporterDataProviderProvider`, which
/// contributes whole extra categories from the same snapshot.
final List<Override> simcruxIssueReporterScopedOverrides = <Override>[
  // PRODUCT SEAM — the privacy-scrubbed Session State snapshot. See
  // `buildSimcruxIssueSessionContext` for the field-by-field privacy rationale
  // and the exclusions.
  cruxIssueSessionContextProvider.overrideWith(
    buildSimcruxIssueSessionContext,
  ),
];
