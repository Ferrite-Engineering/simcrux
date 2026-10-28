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
          'origin': kDebugInWaveCruxOriginTokens,
        },
      ),

      // ── formal verification (open core) ────────────────────────────────────
      // One per run per distinct (tool, mode, engine), counts summed: a
      // riscv-formal import is hundreds of tasks, and one event each would
      // evict every other counter from the queue. Six properties, the
      // Worker's cap today; `frontend` and `solver` are added when it takes
      // eight. Never a property name, a label, a path, a depth or a step.
      TelemetryCatalogEvent(
        'formal.run.completed',
        enumeratedValues: <String, List<String>>{
          'tool': kFormalRunToolTokens,
          'mode': kFormalRunModeTokens,
          'engine': kFormalRunEngineTokens,
          'frontend': kFormalRunFrontendTokens,
          'solver': kFormalRunSolverTokens,
        },
        intProperties: <String>['properties', 'failed', 'undecided'],
      ),
      // Recorded by the GUI importers only, after the file was written.
      TelemetryCatalogEvent(
        'formal.import.completed',
        enumeratedValues: <String, List<String>>{
          'kind': kFormalImportKindTokens,
        },
        intProperties: <String>['tasks'],
      ),
      // Once per run per way the job files turned assertions off. Which job
      // file did is never sent.
      TelemetryCatalogEvent(
        'formal.assertions.disabled',
        enumeratedValues: <String, List<String>>{
          'how': kFormalAssertionsDisabledTokens,
        },
      ),
      // Once per run per distinct (construct class, frontend) an open
      // frontend refused. The class is SimCrux's closed vocabulary; the
      // construct as written, its file and its line are never sent.
      TelemetryCatalogEvent(
        'formal.sva.unsupported',
        enumeratedValues: <String, List<String>>{
          'construct': kFormalSvaConstructTokens,
          'frontend': kFormalSvaFrontendTokens,
        },
      ),
      // Once per run per kind of property whose result depended on state
      // from before the trace began. Never the depth or the step.
      TelemetryCatalogEvent(
        'formal.pretrace.flagged',
        enumeratedValues: <String, List<String>>{
          'kind': kFormalPretraceKindTokens,
        },
      ),

      // ── implementation flow (open core) ────────────────────────────────────
      // One per flow run, launched (`source: run`, recorded when the
      // regression ends) or ingested (`source: ingest`). Six properties, the
      // Worker's cap. Never a metric value (no WNS, area or Fmax, not even
      // bucketed), a design or cell name, a PDK variant beyond the closed
      // target set, a path, a tag or a step name.
      TelemetryCatalogEvent(
        'flow.run.completed',
        enumeratedValues: <String, List<String>>{
          'kind': kFlowKindTokens,
          'source': kFlowSourceTokens,
          'outcome': kFlowOutcomeTokens,
          'target': kFlowTargetTokens,
          'reader': kFlowReaderTokens,
        },
        intProperties: <String>['steps'],
      ),
      // Once per run per (kind, reason) a reader could not verify.
      TelemetryCatalogEvent(
        'flow.reader.unsupported',
        enumeratedValues: <String, List<String>>{
          'kind': kFlowKindTokens,
          'reason': kFlowReaderUnsupportedTokens,
        },
      ),
      // Each worst path opened in the Flow Runs panel: the flow and how well
      // the path maps to the RTL. Never the path, its cells, its delay or
      // the design.
      TelemetryCatalogEvent(
        'flow.path.opened',
        enumeratedValues: <String, List<String>>{
          'kind': kFlowKindTokens,
          'fidelity': kFlowFidelityTokens,
        },
      ),
      // Each hand-off to an external viewer; `ok` false when it could not
      // be started.
      TelemetryCatalogEvent(
        'flow.handoff.launched',
        enumeratedValues: <String, List<String>>{
          'viewer': kFlowHandoffViewerTokens,
        },
        boolProperties: <String>['ok'],
      ),
      // Once per run per tool a flow could not start, and each hand-off
      // whose viewer is missing.
      TelemetryCatalogEvent(
        'flow.tool.missing',
        enumeratedValues: <String, List<String>>{'tool': kFlowToolTokens},
      ),
      // One per gate-level run, recorded when it ends. Six properties, the
      // Worker's cap. Never a count of differences, a signal name or a cycle.
      TelemetryCatalogEvent(
        'flow.gls.completed',
        enumeratedValues: <String, List<String>>{
          'outcome': kFlowGlsOutcomeTokens,
          'simulator': kFlowGlsSimulatorTokens,
          'netlist': kFlowGlsNetlistTokens,
          'delays': kFlowGlsDelaysTokens,
          'target': kFlowTargetTokens,
        },
        intProperties: <String>['tests'],
      ),
      // Each gate-level triage view shown, once per view per opening: the
      // differences, the X-asymmetry detail or the history. Pro; never a
      // signal name, a cycle or a count.
      TelemetryCatalogEvent(
        'flow.gls.triage_opened',
        enumeratedValues: <String, List<String>>{
          'view': kFlowGlsTriageViewTokens,
        },
      ),
      // Once per delay-annotated gate-level run, when its delays have been
      // read: whether every delay annotated, some did, or none did, and
      // whether every interconnect delay annotated. Pro; never a corner, a
      // cell, an instance or a count.
      TelemetryCatalogEvent(
        'flow.sdf.annotated',
        enumeratedValues: <String, List<String>>{
          'result': kFlowSdfAnnotationTokens,
        },
        boolProperties: <String>['interconnect'],
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

      // `crux_telemetry`'s `TelemetryUncleanShutdownDetector` records this
      // once at startup when the previous desktop session ended without a
      // clean exit. No properties: it says that a session was lost, never
      // why, where or what was open. Shipped dark: the package's single
      // enable constant is false, so nothing sends it until that flips, and
      // the entry is here so the day it flips is not a silent drop.
      //
      // A literal, not the package's `kTelemetryUncleanShutdownEvent`, for
      // the headless-closure reason above; the conformance test asserts the
      // two are equal.
      TelemetryCatalogEvent('app.unclean_shutdown'),

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

      // ── Pro: implementation-flow analysis ─────────────────────────────
      // History over runs whose verdicts, metrics and paths are free. Never
      // a metric value, a design, a tag, a path, a config variable or a
      // step name: these say which analysis is used, never what it showed.
      //
      // Each comparison of two runs: the flow and how many critical metrics
      // got worse (clamped), which answers "does comparison find
      // regressions" without one number from the design.
      TelemetryCatalogEvent(
        'flow.compare.run',
        enumeratedValues: <String, List<String>>{'kind': kFlowKindTokens},
        intProperties: <String>['critical_worse'],
      ),
      // Each history view opened: metric trends, the PPA dashboard, or the
      // calendar of runs.
      TelemetryCatalogEvent(
        'flow.trend.opened',
        enumeratedValues: <String, List<String>>{
          'view': kFlowTrendViewTokens,
        },
      ),
      // Once per entry per metric group an alert rule raised, after the
      // acknowledged filter. Never the metric, its value or the entry.
      TelemetryCatalogEvent(
        'flow.alert.raised',
        enumeratedValues: <String, List<String>>{
          'group': kFlowAlertGroupTokens,
        },
      ),
      // Each sweep view opened, with how many runs it grouped (clamped).
      TelemetryCatalogEvent(
        'flow.sweep.opened',
        intProperties: <String>['runs'],
      ),
      // Each baseline written, from the app or the headless verb's GUI
      // twin; headless never transmits.
      TelemetryCatalogEvent(
        'flow.baseline.set',
        enumeratedValues: <String, List<String>>{'kind': kFlowKindTokens},
      ),

      // ── Pro: formal analysis ────────────────────────────────────────────
      // Recorded at each Pro formal opener after its gate passes; a denied
      // open is `tier.gate_hit`. Which screen, and nothing about the run.
      TelemetryCatalogEvent(
        'formal.dashboard_opened',
        enumeratedValues: <String, List<String>>{
          'view': kFormalDashboardViewTokens,
        },
      ),
      // Once per run per kind of regression the run raised against the
      // previous recorded run. Never the property, the test or the times.
      TelemetryCatalogEvent(
        'formal.regression.raised',
        enumeratedValues: <String, List<String>>{
          'kind': kFormalRegressionKindTokens,
        },
      ),
      // Once per failing EQY partition the partition explorer explains, per
      // opening: which of the closed diagnoses it reached. Never the
      // partition, the design, the match point or the suggested edit.
      TelemetryCatalogEvent(
        'eqy.partition.diagnosed',
        enumeratedValues: <String, List<String>>{
          'diagnosis': kEqyPartitionDiagnosisTokens,
        },
      ),
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
/// underscores and so pass the Worker's value class as they stand. `sby`,
/// `eqy`, `librelane` and `nextpnr` are the formal and implementation-flow
/// engine ids, in the same spelling. Gate-level simulation adds no token: it
/// runs on `icarus` or `verilator` and reports as that engine. `demo` is
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
  'sby',
  'eqy',
  'librelane',
  'nextpnr',
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

/// What started a regression: the user, the file watcher, a headless run, an
/// ingested flow run, or a gate-level rerun.
///
/// Derived from `RegressionTrigger` by `telemetryEnumToken`; the conformance
/// test re-derives it from the enum so a new trigger cannot be added without
/// this list moving in the same change.
const List<String> kSimcruxRegressionTriggerTokens = <String>[
  'manual',
  'auto',
  'ci',
  'ingest',
  'gls',
];

/// How a project came to be opened.
///
/// `yaml` is a `simcrux.yaml` chosen from the file picker, `fusesoc` an
/// imported `.core`, `riscv` either of the two RISC-V importers, `formal`
/// File > Import Formal Project, `recent` a click in the empty canvas's
/// recents list, `session` a `.simcrux-session`, and `cli` a path handed to
/// the app on the command line. All seven are entry points that exist today;
/// the token names the *route in*, never the file at the end of it.
///
/// `recent`, `session` and `cli` are not new features — they are the routes a
/// user most plausibly takes, and a vocabulary that omitted them would drop
/// the property on every launch that opened a project from the command line,
/// which for a CI-adjacent tool is most of them.
const List<String> kSimcruxProjectSourceTokens = <String>[
  'yaml',
  'fusesoc',
  'riscv',
  'formal',
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

/// `TrendAlertKind.values` under `telemetryEnumToken`, less
/// `flowMetricRegression`, which reports as `flow.alert.raised` by group.
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
  'formal_dashboard',
  'formal_history',
  'formal_pretrace',
  'eqy_explorer',
  'flow_trends',
  'flow_compare',
  'flow_ppa_dashboard',
  'flow_alerts',
  'flow_sweep',
  'flow_baseline',
  'flow_org_dashboard',
  'flow_gls_triage',
  'flow_sdf_gls',
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

/// `formal.run.completed.tool`: the general SymbiYosys driver, the EQY
/// driver, and the RISC-V track.
const List<String> kFormalRunToolTokens = <String>[
  'sby',
  'eqy',
  'riscv_formal',
];

/// `formal.run.completed.mode`: `sby`'s four modes, `eqy`'s equivalence,
/// and `mixed`.
const List<String> kFormalRunModeTokens = <String>[
  'bmc',
  'prove',
  'cover',
  'live',
  'equiv',
  'mixed',
];

/// `formal.run.completed.engine`: the first word of the engine line that
/// decided; `other` for an engine outside this list.
const List<String> kFormalRunEngineTokens = <String>[
  'smtbmc',
  'abc',
  'aiger',
  'btor',
  'mixed',
  'other',
];

/// `formal.run.completed.frontend`: the frontend that read the design
/// (Yosys's built-in one, yosys-slang, Verific), and `unknown` when it was
/// not recorded or the runs of the group disagree.
const List<String> kFormalRunFrontendTokens = <String>[
  'builtin',
  'slang',
  'verific',
  'unknown',
];

/// `formal.run.completed.solver`: the solver behind the engine. `abc` for
/// the ABC engine, `yices` for an `smtbmc` line that names none (its
/// default), `mixed` when the runs of the group used different ones,
/// `other` for one outside this list, and `none` when no engine line was
/// recorded.
const List<String> kFormalRunSolverTokens = <String>[
  'yices',
  'boolector',
  'bitwuzla',
  'z3',
  'abc',
  'ric3',
  'mixed',
  'other',
  'none',
];

/// `formal.dashboard_opened.view`: the formal properties dashboard, the
/// proof history (which carries the regressions and the engine comparison),
/// the pre-trace and vacuity analysis, and the EQY partition explorer.
const List<String> kFormalDashboardViewTokens = <String>[
  'properties',
  'history',
  'pretrace',
  'eqy_partitions',
];

/// `eqy.partition.diagnosed.diagnosis`: a failing partition whose match
/// point the gate side restructured away, a real difference with matched
/// inputs, or neither established.
const List<String> kEqyPartitionDiagnosisTokens = <String>[
  'match_point_restructured',
  'genuine_mismatch',
  'undetermined',
];

/// `formal.regression.raised.kind`: a property that was proved and now is
/// not, and a task whose proof got markedly slower.
const List<String> kFormalRegressionKindTokens = <String>[
  'verdict_flip',
  'proof_time',
];

/// `formal.import.completed.kind`: which importer wrote the project file.
const List<String> kFormalImportKindTokens = <String>[
  'sby',
  'eqy',
  'riscv_formal',
];

/// `formal.assertions.disabled.how`: Yosys's `-noassert` read option and
/// yosys-slang's `--ignore-assertions`.
const List<String> kFormalAssertionsDisabledTokens = <String>[
  'noassert',
  'ignore_assertions',
];

/// `formal.sva.unsupported.construct`: the closed construct classes of
/// `SvaConstructClass`.
const List<String> kFormalSvaConstructTokens = <String>[
  'implication',
  'delay',
  'repetition',
  'sequence_op',
  'named_sequence',
  'default_clocking',
  'liveness_op',
  'other',
];

/// `formal.sva.unsupported.frontend`: the open frontends. A Verific run
/// never produces the diagnostic.
const List<String> kFormalSvaFrontendTokens = <String>['builtin', 'slang'];

/// `formal.pretrace.flagged.kind`: an assertion's counterexample or a
/// cover's witness.
const List<String> kFormalPretraceKindTokens = <String>['assert', 'cover'];

/// `debug_in_wavecrux.used.origin`: what kind of row was handed off. A
/// counterexample trace and a simulation dump ride the same hand-off, and
/// the funnel has to tell them apart.
const List<String> kDebugInWaveCruxOriginTokens = <String>[
  'test',
  'formal',
  'eqy',
];

/// `flow.*.kind`: the two flows SimCrux runs and reads.
const List<String> kFlowKindTokens = <String>['librelane', 'nextpnr'];

/// `flow.trend.opened.view`: the Pro history views over flow runs.
const List<String> kFlowTrendViewTokens = <String>['metric', 'ppa', 'calendar'];

/// `flow.gls.triage_opened.view`: the Pro gate-level triage views.
const List<String> kFlowGlsTriageViewTokens = <String>[
  'mismatches',
  'x_detail',
  'history',
];

/// `flow.sdf.annotated.result`: how much of the run's delay file the
/// simulator annotated.
const List<String> kFlowSdfAnnotationTokens = <String>[
  'full',
  'partial',
  'failed',
];

/// `flow.alert.raised.group`: the metric group an alert rule watches.
const List<String> kFlowAlertGroupTokens = <String>[
  'timing',
  'area',
  'drc',
  'lvs',
  'antenna',
  'slew',
  'power',
  'other',
];

/// `flow.run.completed.source`: SimCrux launched the run, or indexed one it
/// did not launch.
const List<String> kFlowSourceTokens = <String>['run', 'ingest'];

/// `flow.run.completed.outcome`: the `FlowVerdict` wire names.
const List<String> kFlowOutcomeTokens = <String>[
  'met',
  'violated',
  'stopped',
  'not_run',
  'unrecognised',
];

/// `flow.run.completed.target`: the PDK family or FPGA family, closed.
/// sky130A and sky130B both report `sky130`.
const List<String> kFlowTargetTokens = <String>[
  'sky130',
  'gf180mcu',
  'ihp_sg13g2',
  'ice40',
  'ecp5',
  'gowin',
  'gatemate',
  'other',
];

/// `flow.run.completed.reader`: whether the reader is verified for the
/// run's tool version.
const List<String> kFlowReaderTokens = <String>['verified', 'unverified'];

/// `flow.reader.unsupported.reason`.
const List<String> kFlowReaderUnsupportedTokens = <String>[
  'version_unknown',
  'layout_unknown',
  'schema_unknown',
];

/// `flow.path.opened.fidelity`: the `MappingFidelity` wire names.
const List<String> kFlowFidelityTokens = <String>[
  'register',
  'statement',
  'span',
  'unmapped',
];

/// `flow.handoff.launched.viewer`.
const List<String> kFlowHandoffViewerTokens = <String>[
  'klayout',
  'openroad_gui',
  'openroad_web',
  'nextpnr_gui',
];

/// `flow.tool.missing.tool`.
const List<String> kFlowToolTokens = <String>[
  'librelane',
  'openroad',
  'yosys',
  'nextpnr',
  'klayout',
  'fusesoc',
  'nix',
  'docker',
  'pdk',
  'pdk_models',
];

/// `flow.gls.completed.outcome`: the `GlsOutcome` wire names.
const List<String> kFlowGlsOutcomeTokens = <String>[
  'equal',
  'x_only',
  'differs',
  'not_run',
];

/// `flow.gls.completed.simulator`. Gate level runs under Icarus in this
/// release; the closed set keeps the other name for the day it is measured.
const List<String> kFlowGlsSimulatorTokens = <String>['icarus', 'verilator'];

/// `flow.gls.completed.netlist`.
const List<String> kFlowGlsNetlistTokens = <String>['nl', 'pnl'];

/// `flow.gls.completed.delays`: functional (unit delays) or SDF-annotated.
const List<String> kFlowGlsDelaysTokens = <String>['functional', 'sdf'];

/// Every catalog event name, for the source-scanning conformance test.
Set<String> get kSimcruxEventNames => <String>{
  for (final event in kSimcruxEventCatalog) event.name,
};
