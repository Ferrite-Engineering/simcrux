// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
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
    revealFlowRuns(read);
    unawaited(
      tab
          .read(regressionRunnerProvider.notifier)
          .submitSpecs(specs, concurrency: specs.length.clamp(1, 4)),
    );
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
    final readings = <FlowReading>[
      for (final item in items) ?item.reading,
    ];
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
