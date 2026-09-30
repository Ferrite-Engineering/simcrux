// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// No `package:crux_telemetry` import, and none may be added: this file is in
// the headless `simcrux` CLI's import closure (the CI runner reaches it
// through `simulator_telemetry_token.dart`), and crux_telemetry imports
// Flutter, which the standalone binary cannot compile. `tool/build_cli.sh`
// and the CI job that runs it fail on any such import.
import 'package:meta/meta.dart';

/// One entry of the SimCrux event catalog: an event name and the closed
/// vocabulary of each property it may carry.
///
/// [enumeratedValues] lists the string values a property key is allowed to
/// take. A key mapped to an empty list carries something that is not a closed
/// string set — a bool, or a bounded integer — and is checked by the
/// conformance test's per-key rules instead.
@immutable
class TelemetryCatalogEvent {
  /// Pins one catalog event and its property vocabulary.
  const TelemetryCatalogEvent(
    this.name, {
    this.enumeratedValues = const <String, List<String>>{},
    this.boolProperties = const <String>[],
    this.intProperties = const <String>[],
  });

  /// The catalog event name, as recorded.
  final String name;

  /// String-valued properties → every value the call site may emit.
  final Map<String, List<String>> enumeratedValues;

  /// Properties whose value is a `bool`.
  final List<String> boolProperties;

  /// Properties whose value is a bounded integer.
  final List<String> intProperties;

  /// Every property key this event may carry.
  Iterable<String> get propertyKeys => <String>[
    ...enumeratedValues.keys,
    ...boolProperties,
    ...intProperties,
  ];
}

/// **The** SimCrux event catalog — every telemetry event either repository
/// may record, with the closed vocabulary of every property.
///
/// This list is the pinned SimCrux event catalog. Two tests hold it to that
/// role: one scans both source trees and fails on an
/// event name that is recorded but not listed here, and one checks every name,
/// key and value in this list against the ingestion Worker's grammar.
///
/// The second check is the load-bearing one. The Worker drops a malformed
/// event name *silently* — the batch still returns 202, the row is counted
/// only in the response's `dropped` field, and the client is not told. A
/// property whose key or value fails its class is dropped while the event is
/// kept, which is worse: the counter looks healthy and its dimension is
/// simply, permanently empty. Neither failure is visible from the app, from
/// the queue, or from a dashboard that has never seen the missing rows. The
/// conformance test is the only place either one can be caught.
///
/// **The never-collect rule bites hardest in this product.** SimCrux's whole job is running
/// somebody's testbench, so the things nearest to hand at every call site —
/// the test id, the suite name, the seed, the simulator's stdout — are exactly
/// the things that must never leave the machine. Every property below is
/// either a count or a token from a set this file enumerates. There is no
/// `String → String` sanitizer anywhere in the pipeline, deliberately: one
/// would accept a test name and wash it into something that passes the
/// Worker's character class, and the Worker could not catch it because the
/// output *is* well formed.
const List<TelemetryCatalogEvent> kSimcruxEventCatalog =
    <TelemetryCatalogEvent>[
      // ── workspace, tabs, panes (open core) ─────────────────────────────────
      // Same names and the same property shapes as WaveCrux's catalog: these
      // are the shared workspace set, and a dashboard that groups them across
      // products can only do that if all four spell them identically.
      //
      // Two of the eight names in the suite's shared set are **absent**, and
      // deliberately: SimCrux has no "New Workspace" and no "Save Workspace
      // As" action, so `workspace.created` and `workspace.named.saved` have no
      // call site in this product. A catalog entry with no reachable call site
      // is worse than a missing one — on a dashboard it is indistinguishable
      // from a feature nobody uses, which is the exact question these counters
      // exist to answer. They go back in the day the actions do.
      TelemetryCatalogEvent(
        'workspace.restored',
        intProperties: <String>['tabs', 'panes'],
      ),
      TelemetryCatalogEvent('workspace.reset'),
      TelemetryCatalogEvent(
        'workspace.named.opened',
        intProperties: <String>['tabs', 'panes'],
      ),
      TelemetryCatalogEvent(
        'tab.opened',
        intProperties: <String>['tabs', 'panes'],
      ),
      TelemetryCatalogEvent('pane.split'),
      TelemetryCatalogEvent('pane.closed'),

      // ── the regression loop (open core) ────────────────────────────────────
      TelemetryCatalogEvent(
        'regression.completed',
        enumeratedValues: <String, List<String>>{
          'simulator': kSimcruxRegressionSimulatorTokens,
          'trigger': kSimcruxRegressionTriggerTokens,
        },
        // Counts, never identities. `tests` is how many specs the run
        // submitted and `failed` is how many of them the fail gate counted —
        // two integers that answer "what size are real suites, and how red are
        // they" without naming a single test. Both are clamped; see
        // [kTelemetryMaxCount].
        intProperties: <String>['tests', 'failed'],
      ),
      TelemetryCatalogEvent('regression.cancelled'),
      TelemetryCatalogEvent(
        'engine.missing',
        enumeratedValues: <String, List<String>>{
          // No `mixed`: a missing engine is one engine. The token comes from
          // `SimulatorNotAvailableException.simulatorId` through
          // [simulatorTelemetryToken], so a plugin-contributed id — arbitrary
          // user text — reports `plugin` rather than itself.
          'simulator': kSimcruxSimulatorTokens,
        },
      ),
      TelemetryCatalogEvent(
        'test.rerun',
        boolProperties: <String>['waveform_forced'],
      ),
      TelemetryCatalogEvent(
        'project.opened',
        enumeratedValues: <String, List<String>>{
          'source': kSimcruxProjectSourceTokens,
        },
      ),
      TelemetryCatalogEvent(
        'dashboard.view_changed',
        enumeratedValues: <String, List<String>>{
          'mode': kSimcruxDashboardModeTokens,
        },
      ),
      TelemetryCatalogEvent(
        'editor.launched',
        boolProperties: <String>['ok'],
      ),
      TelemetryCatalogEvent(
        'export.completed',
        enumeratedValues: <String, List<String>>{
          'format': kSimcruxExportFormatTokens,
        },
      ),
      TelemetryCatalogEvent(
        'detector.matched',
        enumeratedValues: <String, List<String>>{
          // The project file's own `pass_fail: type:` vocabulary, verbatim —
          // the same words the user wrote in `simcrux.yaml`. Never the
          // pattern, the string, or the golden path the detector matched
          // against.
          'kind': kSimcruxDetectorKindTokens,
        },
      ),
      TelemetryCatalogEvent(
        'debug_in_wavecrux.used',
        enumeratedValues: <String, List<String>>{
          'outcome': kDebugInWaveCruxOutcomeTokens,
        },
      ),
      TelemetryCatalogEvent(
        'cxp.crossprobe',
        enumeratedValues: <String, List<String>>{
          'direction': <String>['inbound', 'outbound'],
        },
        boolProperties: <String>['honored'],
      ),

      // ── recorded by the shared telemetry package ─────────────────────
      // `crux_telemetry`'s `TelemetryUncaughtErrorCounter` records this from
      // the global error handlers `captureFlutterErrors` installs, so no call
      // site in either repository spells it. At most once per (source, kind,
      // library) per session and ten per session; never the message, the stack
      // or a file name. `kind` is the error's class bucketed by `is` checks,
      // never its runtime type name, and `library` is the Flutter framework
      // library that reported it.
      //
      // The value lists are a literal copy of the package's
      // `kTelemetryUncaughtError{Sources,Kinds,Libraries}`, which the
      // ingestion Worker enforces value by value for this one event. A copy,
      // not a reference, because this file is in the headless CLI's import
      // closure and crux_telemetry is not (see the note above the imports).
      // The catalog conformance test asserts each list equals the package's,
      // so a value added to the shared counter and missing here goes red.
      TelemetryCatalogEvent(
        'app.uncaught_error',
        enumeratedValues: <String, List<String>>{
          'source': <String>['flutter', 'platform'],
          'kind': <String>[
            'flutter_error',
            'state_error',
            'argument_error',
            'range_error',
            'format_exception',
            'file_system_exception',
            'io_exception',
            'platform_exception',
            'timeout_exception',
            'type_error',
            'no_such_method_error',
            'assertion_error',
            'unsupported_error',
            'concurrent_modification_error',
            'out_of_memory_error',
            'stack_overflow_error',
            'other',
          ],
          'library': <String>[
            'framework',
            'foundation',
            'animation',
            'gestures',
            'painting',
            'image_resource_service',
            'rendering',
            'scheduler',
            'semantics',
            'services',
            'widgets',
            'widget_inspector',
            'material',
            'none',
            'other',
          ],
        },
        boolProperties: <String>['silent'],
      ),

      // ── the commercial group ───────────────────────────────────────────────
      // Every other counter in this file records a feature
      // being *used*, which by construction only ever happens on an
      // installation that already holds the tier. This one records the
      // opposite — somebody reaching for a feature they do not have — which is
      // the strongest upgrade signal the product emits and the only one the
      // envelope cannot supply on its own.
      //
      // The envelope already carries `license_tier`, the tier the user *has*,
      // so there is no `tier` property here; `required` is the tier the
      // feature *needs*, and the pair is what makes the row answerable.
      //
      // **Dormant until the post-beta flip, by construction.** The only site
      // that records this is `showProUpgradeDialog`, and every caller reaches
      // it through a `proFeatureUnlocked` check that short-circuits to *allow*
      // while `kBetaPeriod` is true. Nothing can emit it today. That is not
      // dead code to be tidied away — it is the same dark launch telemetry
      // itself is on, and it starts reporting on the day the
      // flag flips.
      //
      // One row per dialog the user saw, not per denial: the dialog opener
      // suppresses a second dialog while one is up (a held shortcut
      // re-dispatches the denial on every key repeat), and the row is
      // recorded only when the dialog actually opens.
      TelemetryCatalogEvent(
        'tier.gate_hit',
        enumeratedValues: <String, List<String>>{
          // Never the dialog's `featureName`: that is localized display text,
          // so it varies by locale and fails the Worker's value class outright.
          // See [SimcruxGatedFeature].
          'feature': kSimcruxGatedFeatureTokens,
          'required': kSimcruxRequiredTierTokens,
        },
      ),

      // ── Pro overlay ────────────────────────────────────────────────────────
      TelemetryCatalogEvent('flaky.panel_opened'),
      TelemetryCatalogEvent(
        'flaky.retry_applied',
        enumeratedValues: <String, List<String>>{
          // The recorded flakiness band that made the test retry-eligible —
          // never the test that was retried, and never the seed the retry ran
          // with. Both are within arm's reach at that call site and both are
          // design data telemetry never carries.
          'classification': kSimcruxRetriedClassificationTokens,
        },
      ),
      TelemetryCatalogEvent(
        'trend.chart_opened',
        enumeratedValues: <String, List<String>>{
          'chart': kSimcruxTrendChartTokens,
        },
      ),
      TelemetryCatalogEvent(
        'trend.alert_raised',
        enumeratedValues: <String, List<String>>{
          'kind': kSimcruxTrendAlertKindTokens,
        },
      ),
      TelemetryCatalogEvent('seed_heatmap.opened'),
      TelemetryCatalogEvent('comparison.run'),
      TelemetryCatalogEvent('baseline.set'),
      TelemetryCatalogEvent(
        'pr_annotation.dispatched',
        enumeratedValues: <String, List<String>>{
          'target': kSimcruxPrAnnotationTargetTokens,
        },
      ),
      TelemetryCatalogEvent('plugin.driver_loaded'),
      TelemetryCatalogEvent(
        'project.switched',
        enumeratedValues: <String, List<String>>{
          'source': kSimcruxProjectSwitchSourceTokens,
        },
      ),
      TelemetryCatalogEvent(
        'cross_project.searched',
        enumeratedValues: <String, List<String>>{
          // Which surface was searched. Never the pattern — the pattern is
          // the user's text, and it is the single most tempting free-form
          // string anywhere in this product.
          'scope': kSimcruxCrossProjectScopeTokens,
        },
      ),
      TelemetryCatalogEvent(
        'riscv.dashboard_opened',
        enumeratedValues: <String, List<String>>{
          'view': kSimcruxRiscvDashboardTokens,
        },
      ),
      TelemetryCatalogEvent('riscv.report_exported'),
    ];

/// The ingestion Worker's ceiling on an integer property value: anything with
/// `|v| > 100000` fails the value class and is **dropped**, leaving the event
/// stored with that dimension silently empty.
///
/// SimCrux is the one product in the suite whose counters can plausibly reach
/// it — a parameter sweep over a few thousand seeds and a few hundred tests
/// multiplies out fast — so `tests` and `failed` are clamped rather than sent
/// raw. See [telemetryCount] for the choice and its consequence.
const int kTelemetryMaxCount = 100000;

/// Clamps a count to the Worker's integer ceiling.
///
/// **The clamp saturates; it does not bucket.** A run of 250 000 tests reports
/// 100 000, so the top value means "100 000 or more" and nothing above it is
/// distinguishable. That is deliberate, and it is the lesser of the three
/// options:
///
///  * Sending the raw count loses the property *entirely* for exactly the
///    installations whose suite size is most interesting — and loses it
///    silently, which is the failure mode this whole file exists to prevent.
///  * Bucketing every count (powers of ten, say) would cost resolution at the
///    small end, where nearly every real run lives and where the roadmap
///    question ("what size are real suites?") is actually answered.
///  * Saturating costs resolution only in a tail that is already off the end
///    of any histogram we would draw.
///
/// A dashboard reading these counters must therefore treat 100 000 as an open
/// upper bin, not as a measurement.
int telemetryCount(int value) =>
    value < 0 ? 0 : (value > kTelemetryMaxCount ? kTelemetryMaxCount : value);

/// The simulator tokens a single engine may report.
///
/// The first six are the built-in driver ids registered by
/// `simulatorDriverRegistryProvider`, which are already lowercase-with-
/// underscores and so pass the Worker's value class as they stand. `demo` is
/// the hidden `SIMCRUX_DEMO_RUNNER` driver — it is in the list because it can
/// legitimately appear in a run, and leaving it out would silently drop the
/// property on every demo walkthrough.
///
/// `plugin` is the one token every runtime-loaded plugin driver reports,
/// whatever its manifest calls itself. A plugin's `simulatorId` is arbitrary
/// text chosen by whoever wrote the plugin — it is not our vocabulary, it is
/// not a closed set, and it could carry anything at all — so it is folded to
/// a single token rather than forwarded. Same rule, and the same reason, as
/// WaveCrux's `decoder: plugin`.
const List<String> kSimcruxSimulatorTokens = <String>[
  'icarus',
  'verilator',
  'ghdl',
  'cocotb',
  'riscv_arch',
  'riscv_formal',
  'demo',
  'plugin',
];

/// [kSimcruxSimulatorTokens] plus `mixed`, for `regression.completed`.
///
/// A SimCrux run is a set of specs and each spec names its own simulator, so
/// "run the same testbench on Icarus and Verilator" — the product's signature
/// workflow — is a single run with two engines. There is no honest single
/// token for that, and picking the majority engine would quietly overstate one
/// and erase the other, so a multi-engine run says so.
const List<String> kSimcruxRegressionSimulatorTokens = <String>[
  ...kSimcruxSimulatorTokens,
  'mixed',
];

/// What started a regression: the user, the file watcher, or a headless run.
///
/// Derived from `RegressionTrigger` by `telemetryEnumToken`; the conformance
/// test re-derives it from the enum so a new trigger cannot be added without
/// this list moving in the same change.
const List<String> kSimcruxRegressionTriggerTokens = <String>[
  'manual',
  'auto',
  'ci',
];

/// How a project came to be opened.
///
/// `yaml` is a `simcrux.yaml` chosen from the file picker, `fusesoc` an
/// imported `.core`, `riscv` either of the two RISC-V importers, `recent` a
/// click in the empty canvas's recents list, `session` a `.simcrux-session`,
/// and `cli` a path handed to the app on the command line. All six are entry
/// points that exist today; the token names the *route in*, never the file at
/// the end of it.
///
/// `recent`, `session` and `cli` are not new features — they are the routes a
/// user most plausibly takes, and a vocabulary that omitted them would drop
/// the property on every launch that opened a project from the command line,
/// which for a CI-adjacent tool is most of them.
const List<String> kSimcruxProjectSourceTokens = <String>[
  'yaml',
  'fusesoc',
  'riscv',
  'recent',
  'session',
  'cli',
];

/// `DashboardViewMode.values` under `telemetryEnumToken`.
///
/// Three, not two: `inspectorFocused` is a real
/// mode the segmented control can reach, and a vocabulary that omitted it
/// would drop the property — silently — on exactly the transitions into the
/// view whose value is least obvious.
const List<String> kSimcruxDashboardModeTokens = <String>[
  'table',
  'heatmap',
  'inspector_focused',
];

/// `ExportFormat.values` plus the static-site dashboard bundle.
///
/// The four enum ids are already lowercase, so the call site sends `.id`
/// directly. `web_bundle` has no `ExportFormat` constant because it is not one
/// — it is `simcrux export-dashboard` / the Export Dashboard action, which
/// writes a directory rather than encoding a single document.
const List<String> kSimcruxExportFormatTokens = <String>[
  'junit',
  'json',
  'csv',
  'html',
  'web_bundle',
];

/// The project file's `pass_fail: type:` vocabulary.
///
/// Taken from the config loader's own switch (`config_loader_pass_fail.dart`),
/// so the token a user sees in the data is the word they wrote in their YAML.
/// `composite` is included because a composite *is* a dispatch the registry
/// performs, and its leaves contribute their own tokens alongside it.
const List<String> kSimcruxDetectorKindTokens = <String>[
  'exit_code',
  'string_match',
  'regex',
  'uvm_report',
  'golden_compare',
  'composite',
];

/// `DebugInWaveCruxOutcome.values` under `telemetryEnumToken`, 1:1.
///
/// Every outcome the dispatcher can return, including
/// `dispatched_with_limitation`, `rejected` and `unacknowledged`. Those three
/// are the *interesting* ones: they are the
/// shapes in which the flagship suite integration fails while still looking
/// like it worked, and a funnel that could not see them would read healthy
/// exactly when it is not.
const List<String> kDebugInWaveCruxOutcomeTokens = <String>[
  'dispatched',
  'dispatched_with_limitation',
  'rejected',
  'unacknowledged',
  'no_peer',
  'server_disabled',
  'no_waveform',
  'waveform_missing',
];

/// Which Pro trend view was opened.
const List<String> kSimcruxTrendChartTokens = <String>[
  'per_test',
  'per_suite',
  'calendar',
];

/// `PrAnnotationPlatform.values` under `telemetryEnumToken`.
const List<String> kSimcruxPrAnnotationTargetTokens = <String>[
  'github',
  'gitlab',
  'webhook',
];

/// `TrendAlertKind.values` under `telemetryEnumToken`.
///
/// Which of the three alert rules actually fired. The alert itself names a
/// test and carries two runtimes; none of that travels — only which rule
/// produced it.
const List<String> kSimcruxTrendAlertKindTokens = <String>[
  'runtime_regression',
  'new_persistent_failure',
  'flip_flop_run_detected',
];

/// The `FlakyClassification` values that can make a test retry-eligible,
/// under `telemetryEnumToken`.
///
/// Three of the enum's five, and the two that are missing are the point:
/// `stable` and `consistently_failing` are the classifications
/// `FlakyRetryPolicy` refuses to retry, so no run can produce them here. A
/// vocabulary that listed all five would show two tokens that are always
/// zero, which on a dashboard is indistinguishable from a band nobody's
/// tests fall into.
const List<String> kSimcruxRetriedClassificationTokens = <String>[
  'intermittent',
  'flaky',
  'highly_flaky',
];

/// How the project switcher reached the project it activated.
///
/// `open` is a project already in the workspace — the multi-project workflow
/// the tier matrix sells. `recent` is a re-open from the registry's recents
/// list, which is a single-project workflow with a shortcut. The two answer
/// different questions about whether the multi-project *workspace* earns its
/// complexity, and one token could not tell them apart.
const List<String> kSimcruxProjectSwitchSourceTokens = <String>[
  'open',
  'recent',
];

/// `CrossProjectSearchScope.values` under `telemetryEnumToken`.
const List<String> kSimcruxCrossProjectScopeTokens = <String>[
  'test_names',
  'failure_messages',
  'file_paths',
  'all',
];

/// The two Pro RISC-V analysis surfaces.
///
/// `compatibility` is the architectural-signature dashboard, `formal` the
/// bounded-proof one. Both are Pro *surfaces* over a result set that is not
/// gated at all (§15.1) — the verdicts render in an unlicensed build — so
/// this counter measures the dashboards, not the drivers.
const List<String> kSimcruxRiscvDashboardTokens = <String>[
  'compatibility',
  'formal',
];

/// `SimcruxGatedFeature.values` under `telemetryEnumToken` — the `feature`
/// vocabulary of `tier.gate_hit`.
///
/// One id per site that can raise `CruxUpgradeDialog`, spelled out here as
/// well as in the enum so the conformance test can hold the two to each
/// other: a new gate site that forgets this list would record a value the
/// Worker drops, and the counter would survive with an empty dimension.
const List<String> kSimcruxGatedFeatureTokens = <String>[
  'flaky_panel',
  'seed_heatmap',
  'regression_comparison',
  'trend_per_test',
  'trend_per_suite',
  'trend_calendar',
  'retention_policy',
  'pr_annotation_settings',
  'pr_annotation_dispatch',
  'plugin_manager',
  'plugin_reload',
  'riscv_compatibility',
  'riscv_formal',
  'project_switcher',
  'reopen_recent_project',
  'close_all_projects',
  'pin_project',
  'cross_project_search',
  'cross_probe',
];

/// The tiers a gate may demand: `pro` or `enterprise`, and nothing else.
///
/// **No `edu` and no `open_core`.** `LicenseTierFeatures.featureEquivalent`
/// maps `edu → pro`, so a gate never demands EDU — an EDU seat satisfies
/// every Pro gate — and a feature that demanded `openCore` would not be a
/// gate. This is suite-wide, not per-product.
///
/// SimCrux ships no Enterprise gate site today: the overlay's Enterprise
/// features (distributed execution, hosted ingest, org rollup) do not exist
/// in any repository, so `enterprise` is a vocabulary entry with no current
/// emitter. It is listed anyway because the alternative — discovering the
/// omission the day the first Enterprise gate lands, by way of a silently
/// dropped property — is the failure mode this whole file exists to prevent.
const List<String> kSimcruxRequiredTierTokens = <String>[
  'pro',
  'enterprise',
];

/// Every catalog event name, for the source-scanning conformance test.
Set<String> get kSimcruxEventNames => <String>{
  for (final event in kSimcruxEventCatalog) event.name,
};
