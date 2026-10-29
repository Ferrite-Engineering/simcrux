// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart' show cxpDesignIdForPath;
import 'package:crux_flow/crux_flow.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/flow/flow_labels.dart';
import 'package:simcrux/features/flow/gls_labels.dart';
import 'package:simcrux/features/flow/providers/flow_pro_seams.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_dispatcher.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_message.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/viewer/providers/right_dock_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_archive_extractor.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_handoff_provider.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';
import 'package:simcrux/services/flow/librelane_path_check.dart';
import 'package:simcrux/services/job_scheduler/gls_scratch.dart';
import 'package:simcrux/services/telemetry/flow_telemetry.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

/// Reads a provider from the app's root scope: `WidgetRef.read` or
/// `ProviderContainer.read`.
typedef FlowRead = T Function<T>(ProviderListenable<T> provider);

/// What the Flow actions do, for the action handlers to call. Each takes the
/// active tab's container (null when no tab is open) and a context inside
/// the navigator for its toasts.
abstract final class FlowActions {
  /// View > Flow Runs: shows or hides the panel, revealing its tab (and its
  /// dock region) when it shows.
  static void toggleFlowRuns(WidgetRef ref) {
    final willShow = !ref.read(flowRunsVisibleProvider);
    ref.read(flowRunsVisibleProvider.notifier).toggle();
    if (willShow) revealFlowRuns(ref.read);
  }

  /// Shows the Flow Runs panel and brings its tab forward wherever it is
  /// docked.
  static void revealFlowRuns(FlowRead read) {
    read(flowRunsVisibleProvider.notifier).set(visible: true);
    if (read(dockTabRegionProvider)[kDockTabFlowRuns] == kDockRegionRight) {
      read(rightDockTabProvider.notifier).reveal(kDockTabFlowRuns);
    } else {
      read(bottomDockTabProvider.notifier).reveal(kDockTabFlowRuns);
    }
  }

  /// Tools > Run Flow Entry: runs the entry of the run selected in Flow
  /// Runs, else every flow entry of the project.
  static void runFlowEntry(
    BuildContext? context,
    ProviderContainer? tab,
    FlowRead read,
  ) {
    final config = tab?.read(activeConfigProvider);
    if (tab == null || config == null) {
      _toast(context, (l10n) => l10n.snackNoProjectOpen);
      return;
    }
    final entries = <TestSpec>[
      for (final suite in config.suites)
        if (suite.name == FlowRunImporter.kFlowSuiteName) ...suite.tests,
    ];
    if (entries.isEmpty) {
      _toast(context, (l10n) => l10n.flowRunNoEntries);
      return;
    }
    final design = tab.read(flowSelectedRunProvider)?.design;
    final chosen = design == null
        ? entries
        : entries
              .where((s) => s.id == FlowRunImporter.specIdFor(design))
              .toList();
    final specs = chosen.isEmpty ? entries : chosen;
    // An entry LibreLane cannot run from is refused here, said in a toast,
    // and never submitted; the others still run.
    final refused = refuseUnsupportedPaths(context, specs);
    final runnable = <TestSpec>[
      for (final s in specs)
        if (!refused.contains(s.id)) s,
    ];
    if (runnable.isEmpty) return;
    revealFlowRuns(read);
    unawaited(
      tab
          .read(regressionRunnerProvider.notifier)
          .submitSpecs(runnable, concurrency: runnable.length.clamp(1, 4)),
    );
  }

  /// The LibreLane entries among [specs] whose design directory LibreLane
  /// cannot run from ([LibreLanePathCheck]: a space, a tab, a line break, a
  /// double quote or a backslash in its real path), said in one error toast
  /// that names the first one's path. Returns the refused specs' ids.
  ///
  /// Run Flow Entry leaves them out of the run; Run Regression runs the whole
  /// project, and the LibreLane driver refuses them before launching with
  /// the same reason in their results.
  static Set<String> refuseUnsupportedPaths(
    BuildContext? context,
    Iterable<TestSpec> specs,
  ) {
    final refused = <String, LibreLaneUnsupportedPath>{};
    for (final spec in specs) {
      final flow = spec.flow;
      if (flow == null) continue;
      final unsupported = LibreLanePathCheck.forEntry(flow);
      if (unsupported != null) refused[spec.id] = unsupported;
    }
    if (refused.isNotEmpty) {
      final first = refused.values.first;
      _toast(
        context,
        (l10n) => FlowLabels.unsupportedPath(l10n, first),
        error: true,
      );
    }
    return refused.keys.toSet();
  }

  /// [refuseUnsupportedPaths] over every flow entry of [config], for Run
  /// Regression on a project with a `flow:` block.
  static void refuseUnsupportedFlowPaths(
    BuildContext? context,
    RegressionConfig config,
  ) {
    refuseUnsupportedPaths(context, <TestSpec>[
      for (final suite in config.suites)
        if (suite.name == FlowRunImporter.kFlowSuiteName) ...suite.tests,
    ]);
  }

  /// Tools > Run Gate-Level Simulation: reruns the tests the selected
  /// LibreLane run's entry names under `gls:` against the run's netlist.
  ///
  /// Functional simulation under Icarus with unit delays; each test is run at
  /// RTL and at gate level, both under Icarus (a Verilator test reruns under
  /// Icarus, and the toast says so), and the design's top-level ports are
  /// compared. The results land in the results table as an ordinary run with
  /// the `gls` trigger. Free in every tier.
  ///
  /// Nothing is synthesised and nothing is written into the run: the
  /// generated port-dump modules and the dumps live in SimCrux's own scratch.
  static Future<void> runGateLevel(
    BuildContext? context,
    ProviderContainer? tab,
    FlowRead read,
  ) async {
    final prepared = await _prepareGateLevel(context, tab, read);
    if (prepared == null) return;
    final request = prepared.request;
    final runner = prepared.runner;
    final info = request.info;
    final options = request.options;
    final scratch = request.scratch;
    final background = request.background;
    final String runDir;
    try {
      runDir = await scratch.allocateRun(
        'gls-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      );
    } on FileSystemException catch (e) {
      // A refused scratch (a link, or a directory other users can write) or
      // one that cannot be made: said, not thrown into the zone.
      if (context != null && context.mounted) {
        _toast(
          context,
          (l10n) => l10n.flowGlsCannotRun('${e.message} (${e.path})'),
          error: true,
        );
      }
      return;
    }
    final planSet = await GlsPlanner.plan(
      info: info,
      options: options,
      selected: request.tests,
      runDir: runDir,
      scratch: scratch,
      background: background,
    );
    // Said plainly, before anything runs: a Verilator test reruns under
    // Icarus, both its RTL and its gate-level run.
    if (request.tests.any((s) => s.simulatorId == 'verilator') &&
        context != null &&
        context.mounted) {
      _toast(context, (l10n) => l10n.flowGlsIcarusNote);
    }
    await runner.submitSpecs(
      <TestSpec>[for (final plan in planSet.plans) plan.submitSpec],
      concurrency: 2,
      trigger: RegressionTrigger.gls,
      wrapScheduler: (inner) => GlsScheduler(
        inner: inner,
        plans: planSet.plans,
        info: info,
        options: options,
        background: background,
      ),
    );
  }

  /// Hands the selected LibreLane run's gate-level request to the edition's
  /// delay-annotated runner ([flowSdfGlsRunnerProvider]), with the same
  /// checks and inputs as [runGateLevel]. The runner owns the tier gate, the
  /// run and the result surface. Does nothing when no runner is installed:
  /// the panel offers this only when one is.
  static Future<void> runGateLevelWithDelays(
    BuildContext? context,
    ProviderContainer? tab,
    FlowRead read,
  ) async {
    final runner = read(flowSdfGlsRunnerProvider);
    if (runner == null) return;
    final prepared = await _prepareGateLevel(context, tab, read);
    if (prepared == null || context == null || !context.mounted) return;
    await runner.run(context, prepared.request);
  }

  /// What both gate-level actions start from: the selected LibreLane run,
  /// its entry's `gls:` tests, and the run's netlist and models, read; or
  /// null after a toast that says why not.
  static Future<({GlsRunRequest request, RegressionRunner runner})?>
  _prepareGateLevel(
    BuildContext? context,
    ProviderContainer? tab,
    FlowRead read,
  ) async {
    final config = tab?.read(activeConfigProvider);
    if (tab == null || config == null) {
      _toast(context, (l10n) => l10n.snackNoProjectOpen);
      return null;
    }
    final selection = tab.read(flowSelectedRunProvider);
    if (selection == null) {
      _toast(context, (l10n) => l10n.flowGlsNoRun);
      return null;
    }
    if (selection.kind != FlowKind.librelane) {
      _toast(context, (l10n) => l10n.flowGlsNeedsLibreLane);
      return null;
    }
    FlowEntry? entry;
    for (final e in config.flow?.entries ?? const <FlowEntry>[]) {
      if (e.kind == FlowKind.librelane && e.name == selection.design) {
        entry = e;
      }
    }
    final gls = entry?.gls;
    if (entry == null || gls == null || gls.tests.isEmpty) {
      _toast(context, (l10n) => l10n.flowGlsNoTests);
      return null;
    }
    final candidates = <TestSpec>[
      for (final suite in config.suites)
        if (suite.name != FlowRunImporter.kFlowSuiteName) ...suite.tests,
    ];
    final chosen = GlsPlanner.select(candidates, gls.tests);
    if (chosen.unmatched.isNotEmpty) {
      _toast(
        context,
        (l10n) => l10n.flowGlsNoMatch(chosen.unmatched.join(', ')),
      );
      return null;
    }

    // Everything the rest needs, read before the first await: the tab can
    // close behind it.
    final settings = read(appSettingsProvider).value;
    final background = read(flowBackgroundRunnerProvider);
    final scratch = GlsScratch(root: read(flowGlsScratchProvider));
    final runner = tab.read(regressionRunnerProvider.notifier);
    final index = tab.read(flowRunIndexProvider(flowProjectRoot(config))).value;
    final reading = index?.byRoot(selection.root)?.reading;
    final flowRunId = reading == null
        ? null
        : FlowRunIngestor.runIdFor(reading);
    final pdkRoot = settings?.flowTools.pdkRoot ?? '';
    final env = Platform.environment;
    final root = selection.root;
    final netlist = gls.netlist;
    final entryName = entry.name;

    final read0 = await background(
      () => GlsRunInfo.read(
        runRoot: root,
        netlist: netlist,
        pdkRootFallback: pdkRoot.isEmpty ? env['PDK_ROOT'] : pdkRoot,
        home: env['HOME'] ?? env['USERPROFILE'],
        flowRunId: flowRunId,
      ),
    );
    final info = read0.info;
    if (info == null) {
      final reason = read0.problem ?? GlsNotRunReason.runUnreadable;
      if (context != null && context.mounted) {
        _toast(
          context,
          (l10n) => l10n.flowGlsCannotRun(GlsLabels.reason(l10n, reason)),
          error: true,
        );
      }
      return null;
    }
    return (
      request: GlsRunRequest(
        info: info,
        options: GlsOptions(
          netlist: netlist,
          strictX: gls.strictX,
          clock: gls.clock,
          tests: gls.tests,
        ),
        tests: chosen.selected,
        entry: entryName,
        scheduler: () => runner.schedulerFor(config),
        scratch: scratch,
        background: background,
      ),
      runner: runner,
    );
  }

  /// The gate-level result selected in the results table, or null.
  static GlsTriageTarget? glsTriageTarget(ProviderContainer? tab) {
    final result = tab?.read(selectedTestProvider)?.result;
    if (result == null) return null;
    final view = GlsResultView.of(result);
    return view == null ? null : GlsTriageTarget(result: result, view: view);
  }

  /// What WaveCrux puts on the canvas for a gate-level port dump: every
  /// signal under the dumped scope. The dump holds only the design's
  /// top-level ports, so without this the tab opens empty.
  @visibleForTesting
  static List<String> glsWaveformSignals(GlsResultView view) {
    final scope = view.scope;
    return scope == null || scope.isEmpty
        ? const <String>[]
        : <String>['$scope.*'];
  }

  /// Tools > Open Gate-Level Waveform in WaveCrux…: the selected gate-level
  /// result's port dump, handed to WaveCrux. A free cross-probe.
  static Future<void> openGateLevelWaveform(
    BuildContext? context,
    ProviderContainer? tab,
    WidgetRef ref,
  ) async {
    final config = tab?.read(activeConfigProvider);
    if (tab == null || config == null) {
      _toast(context, (l10n) => l10n.snackNoProjectOpen);
      return;
    }
    final target = glsTriageTarget(tab);
    if (target == null) {
      _toast(context, (l10n) => l10n.flowGlsSelectResult);
      return;
    }
    final dispatcher = ref.read(debugInWaveCruxDispatcherProvider);
    final result = await dispatcher.dispatch(
      waveformPath: target.view.gateVcd,
      displayName: target.result.testId,
      suggestedSignals: glsWaveformSignals(target.view),
      designId: cxpDesignIdForPath(config.projectFilePath),
      topModule: tab.read(selectedTestProvider)?.spec?.top,
      result: target.result,
    );
    if (context == null || !context.mounted) return;
    final l10n = L10N.of(context);
    final message = debugInWaveCruxMessage(l10n, result);
    if (debugInWaveCruxSucceeded(result)) {
      showCruxInfoSnack(context, message);
    } else {
      showCruxErrorSnack(context, message);
    }
  }

  /// The run the hand-off opens: the one selected in Flow Runs, else the
  /// selected result when it is a flow result.
  static FlowRunSelection? handoffTarget(ProviderContainer tab) {
    final selected = tab.read(flowSelectedRunProvider);
    if (selected != null) return selected;
    final result = tab.read(selectedTestProvider)?.result;
    final metrics = result?.metrics ?? const <String, String>{};
    final root = metrics[FlowMetricKeys.runDir];
    final kind = metrics[FlowMetricKeys.kind];
    if (root == null || root.isEmpty || kind == null) return null;
    final FlowKind parsed;
    try {
      parsed = FlowKind.fromWireName(kind);
    } on FormatException {
      return null;
    }
    final id = result!.testId;
    const prefix = '${FlowRunImporter.kFlowSuiteName}/';
    return FlowRunSelection(
      root: root,
      kind: parsed,
      design: id.startsWith(prefix) ? id.substring(prefix.length) : null,
    );
  }

  /// Tools > Open in KLayout… / Open in OpenROAD… / Open in nextpnr GUI…:
  /// hands the selected run to [viewer], detached. A missing viewer, a run
  /// of the other kind, or no run at all is said in a toast.
  static Future<void> handoff(
    BuildContext? context,
    ProviderContainer? tab,
    FlowRead read,
    FlowViewer viewer,
  ) async {
    if (tab == null) {
      _toast(context, (l10n) => l10n.snackNoProjectOpen);
      return;
    }
    final target = handoffTarget(tab);
    if (target == null) {
      _toast(context, (l10n) => l10n.flowHandoffNoRun);
      return;
    }
    final wanted = viewer == FlowViewer.nextpnrGui
        ? FlowKind.nextpnr
        : FlowKind.librelane;
    if (target.kind != wanted) {
      _toast(
        context,
        (l10n) => wanted == FlowKind.librelane
            ? l10n.flowHandoffNeedsLibreLane(_viewerName(viewer))
            : l10n.flowHandoffNeedsNextpnr,
      );
      return;
    }
    // Read everything before the await: the tab can close behind it.
    final config = tab.read(activeConfigProvider);
    FlowEntry? entry;
    for (final e in config?.flow?.entries ?? const <FlowEntry>[]) {
      if (e.name == target.design) entry = e;
    }
    entry ??= tab.read(selectedTestProvider)?.spec?.flow;
    final settings = read(appSettingsProvider).value;
    final launcher = read(flowHandoffLauncherProvider);
    final result = await launcher.open(
      viewer,
      kind: target.kind,
      runRoot: target.root,
      entry: entry,
      settings: settings?.flowTools ?? const FlowToolSettings(),
      nextpnrPath: settings?.simulatorBinaryOverrides['nextpnr'],
      librelanePath: settings?.simulatorBinaryOverrides['librelane'],
    );
    if (result.ok || context == null || !context.mounted) return;
    _toast(
      context,
      (l10n) => result.missingTool != null
          ? l10n.inspectorFlowViewerMissing(_viewerName(viewer))
          : l10n.inspectorFlowViewerNothingToOpen,
    );
  }

  static String _viewerName(FlowViewer viewer) => switch (viewer) {
    FlowViewer.klayout => 'KLayout',
    FlowViewer.openroadGui => 'OpenROAD',
    FlowViewer.nextpnrGui => 'nextpnr',
  };

  /// Tools > Ingest Run Directory… and Ingest Zipped Artifact…: asks for
  /// the path, adds it to the tab's Flow Runs, records each run it holds in
  /// the trend store with the `ingest` trigger, and says how many it found.
  ///
  /// Read-only: nothing is written inside the run. A zipped artifact is
  /// extracted into SimCrux's own scratch with containment.
  static Future<void> ingest(
    BuildContext? context,
    ProviderContainer? tab,
    FlowRead read, {
    required bool archive,
    Future<String?> Function()? pick,
  }) async {
    if (tab == null || tab.read(activeConfigProvider) == null) {
      _toast(context, (l10n) => l10n.snackNoProjectOpen);
      return;
    }
    final String? picked;
    try {
      picked = await (pick ?? (archive ? _pickArchive : _pickDirectory))();
    } on Object {
      return;
    }
    if (picked == null) return;
    final path = picked;
    // Read everything the rest needs now: the picker is modal and the tab
    // can close behind it.
    final background = read(flowBackgroundRunnerProvider);
    final scratch = read(flowArchiveScratchProvider);
    final telemetry = read(telemetryServiceProvider);
    tab.read(flowIngestedPathsProvider.notifier).add(path);
    revealFlowRuns(read);

    final List<FlowIngestItem> items;
    try {
      items = await background(
        () => FlowRunIngestor(
          archives: FlowArchiveExtractor(scratch: scratch),
        ).ingest(<String>[path], allowedRoots: <String>[_rootOf(path)]),
      );
    } on Object catch (e) {
      if (context == null || !context.mounted) return;
      _toast(context, (l10n) => l10n.flowIngestFailed('$e'), error: true);
      return;
    }
    final readings = <FlowReading>[for (final item in items) ?item.reading];
    if (readings.isEmpty) {
      final reason = items.isEmpty ? '' : (items.first.message ?? '');
      if (context == null || !context.mounted) return;
      _toast(context, (l10n) => l10n.flowIngestFailed(reason), error: true);
      return;
    }
    // The store's own open policy decides what an unopenable file means;
    // only the writes are best-effort, like every trend write: the panel
    // lists the runs whether or not the history records them.
    final store = await tab.read(trendStoreProvider.future);
    try {
      await FlowRunIngestor.persist(store, items);
    } on Object {
      // Best-effort; see above.
    }
    final now = DateTime.now().toUtc();
    final results = <TestResult>[
      for (final reading in readings)
        FlowRunIngestor.resultFor(reading, now: now),
    ];
    for (final result in results) {
      final properties = flowRunCompletedProperties(
        result.metrics,
        source: 'ingest',
      );
      if (properties == null) continue;
      telemetry.record(
        TelemetryEvent('flow.run.completed', properties: properties),
      );
    }
    for (final properties in flowReaderUnsupportedProperties(results)) {
      telemetry.record(
        TelemetryEvent('flow.reader.unsupported', properties: properties),
      );
    }
    if (context == null || !context.mounted) return;
    _toast(context, (l10n) => l10n.flowIngestDone(readings.length));
  }

  static Future<String?> _pickDirectory() => FilePicker.getDirectoryPath();

  static Future<String?> _pickArchive() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  }

  static String _rootOf(String path) =>
      FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path);

  static void _toast(
    BuildContext? context,
    String Function(L10N l10n) message, {
    bool error = false,
  }) {
    if (context == null || !context.mounted) return;
    final text = message(L10N.of(context));
    if (error) {
      showCruxErrorSnack(context, text);
    } else {
      showCruxInfoSnack(context, text);
    }
  }
}
