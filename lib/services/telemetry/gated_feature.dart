// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The closed vocabulary of `tier.gate_hit {feature}` — one id per site in
/// SimCrux that can raise the suite-standard `CruxUpgradeDialog`.
///
/// **Why an enum and not a string.** The dialog's own `featureName` argument
/// is a *localized display string*: it changes with the user's locale and it
/// fails the ingestion Worker's `[a-z0-9_]{1,64}` value class outright, so a
/// call site that forwarded it would record a permanently empty dimension and
/// nothing would say so. This enum is the product's own vocabulary instead —
/// every value is a word that could appear in our documentation, and
/// `telemetryEnumToken` turns it into the token the Worker accepts. Both
/// halves of that rule bind all four products.
///
/// **Why it lives in open core.** The gate *sites* are all in the Pro overlay
/// today (they are the navigation openers `proOverrides` registers), but the
/// catalog they answer to is here, and the conformance test that pins the
/// catalog's vocabulary to this enum can only run in the repository that owns
/// both. If open core ever grows a gate site of its own, it already has the
/// vocabulary to name it.
///
/// **This cannot fire during the beta.** Every gate site consults
/// `proFeatureUnlocked` / `FeatureGate`, both of which short-circuit to
/// *allow* while `kBetaPeriod` is true, so the deny path — and therefore this
/// whole enum — is unreachable until the post-beta flip. That is the same
/// dark launch telemetry itself is on, not an oversight,
/// and the apparent dead code is load-bearing on the day the flag flips.
///
/// **A gate hit is inherently a GUI event.** Every value below names a
/// `BuildContext`-taking opener that only the desktop app registers;
/// `simcrux --ci` and `simcrux export-dashboard` install no `proOverrides`,
/// mount no `Navigator`, and so cannot reach any of them.
enum SimcruxGatedFeature {
  /// The Flaky Tests panel (`flakyTestsPanelOpenerProvider`).
  flakyPanel,

  /// The seed-failure heatmap (`seedFailureHeatmapOpenerProvider`).
  seedHeatmap,

  /// The run-comparison screen (`regressionComparisonOpenerProvider`).
  regressionComparison,

  /// The per-test trend chart (`perTestTrendChartOpenerProvider`).
  trendPerTest,

  /// The per-suite trend chart (`perSuiteTrendChartOpenerProvider`).
  trendPerSuite,

  /// The calendar heatmap (`calendarHeatmapOpenerProvider`).
  trendCalendar,

  /// Trend retention settings (`retentionPolicySettingsOpenerProvider`).
  retentionPolicy,

  /// The PR-annotation target settings (`prAnnotationSettingsOpenerProvider`).
  prAnnotationSettings,

  /// Posting the active run's annotations
  /// (`prAnnotationDispatchOpenerProvider`).
  prAnnotationDispatch,

  /// The driver-plugin manager (`pluginManagerOpenerProvider`).
  pluginManager,

  /// Re-scanning the plugin directory (`reloadPluginsOpenerProvider`).
  pluginReload,

  /// The RISC-V compatibility dashboard
  /// (`riscvCompatibilityOpenerProvider`).
  riscvCompatibility,

  /// The RISC-V formal dashboard (`riscvFormalOpenerProvider`).
  riscvFormal,

  /// The project switcher (`projectSwitcherOpenerProvider`).
  projectSwitcher,

  /// Reopening the most-recently-closed project
  /// (`reopenRecentProjectOpenerProvider`).
  reopenRecentProject,

  /// Closing every unpinned project (`closeAllProjectsOpenerProvider`).
  closeAllProjects,

  /// Pinning the active project (`pinActiveProjectOpenerProvider`).
  pinProject,

  /// Cross-project search (`crossProjectSearchOpenerProvider`).
  crossProjectSearch,

  // Formal. Each value is a priced capability, never a menu item: one
  // capability may be reached from several controls, and they all report
  // the one id. Every verdict, counterexample and per-property status stays
  // ungated; these name the analysis over them.

  /// The formal properties dashboard: rollups by task, kind and bucket
  /// (`formalPropertiesOpenerProvider`).
  formalDashboard,

  /// Proof history, verdict-flip regressions and engine comparison across
  /// runs (`formalHistoryOpenerProvider`).
  formalHistory,

  /// Pre-trace `$past` analysis and vacuity
  /// (`pretraceAnalysisOpenerProvider`).
  formalPretrace,

  /// The EQY partition explorer, for RTL and flow-netlist equivalence alike
  /// (`eqyExplorerOpenerProvider`).
  eqyExplorer,

  // Flow. The same rule: running a flow, its verdict, metrics, worst paths,
  // RTL mapping, the CI gate and functional gate-level simulation are never
  // gated.

  /// Metric trends across flow runs (`FlowTrendsOpener`).
  flowTrends,

  /// Comparing any two flow runs (`FlowCompareOpener`).
  flowCompare,

  /// The PPA dashboard (`FlowPpaOpener`).
  flowPpaDashboard,

  /// Regression alerts on flow metrics.
  flowAlerts,

  /// The design-space sweep view over existing runs (`FlowSweepOpener`).
  flowSweep,

  /// Writing and managing a flow baseline (`FlowBaselineWriter`). Gating a
  /// run against a baseline file stays free.
  flowBaseline,

  /// The organization-wide flow rollup from the team database. The one
  /// Enterprise value in this group.
  flowOrgDashboard,

  /// Gate-level simulation triage: first divergence, X-classification detail
  /// and GLS history, one capability (`FlowGlsTriageOpener`).
  flowGlsTriage,

  /// Delay-annotated gate-level simulation with SDF, no timing checks
  /// (`FlowSdfGlsRunner`).
  flowSdfGls,
}
