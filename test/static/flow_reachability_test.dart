// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/features/flow/providers/flow_pro_seams.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/widgets/inspector_gls_notes.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_handoff_provider.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';
import 'package:simcrux/services/flow/nextpnr_flow_driver.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Every Flow binding is reached from the app or the binary: a driver
/// nothing registers, an importer nothing calls, a CLI nothing routes to,
/// a panel no dock shows or a Pro seam no action reads would ship green and
/// dead.
void main() {
  String source(String path) => File(path).readAsStringSync();

  test('both drivers are registered in the app registry', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final registry = container.read(simulatorDriverRegistryProvider);
    expect(registry.driverFor('librelane'), isA<LibreLaneFlowDriver>());
    expect(registry.driverFor('nextpnr'), isA<NextpnrFlowDriver>());
  });

  test('both drivers are registered in the headless registry', () {
    final registry = SimcruxCli.defaultDriverRegistry();
    expect(registry.driverFor('librelane'), isA<LibreLaneFlowDriver>());
    expect(registry.driverFor('nextpnr'), isA<NextpnrFlowDriver>());
  });

  test('the loader builds the flow suite through the importer', () {
    final loader = source('lib/services/config/config_loader.dart');
    expect(loader, contains('importer.suiteFor('));
    expect(loader, contains("part 'config_loader_flow.dart';"));
  });

  test('flow is a subcommand of the binary and of the app', () {
    expect(CliArgParser.kSubcommands, contains('flow'));
    expect(
      source('lib/core/cli/simcrux_cli.dart'),
      contains('FlowCli('),
    );
    expect(source('lib/app.dart'), contains('FlowCli('));
  });

  test('the ingestor is reached by the CLI and by the regression runner', () {
    expect(source('lib/core/cli/flow_cli.dart'), contains('ingestor.ingest('));
    expect(
      source('lib/features/dashboard/providers/regression_runner.dart'),
      contains('FlowRunIngestor.readForResult('),
    );
  });

  test('the probe is reached by Settings and by the hand-off', () {
    expect(
      source(
        'lib/features/settings/widgets/settings_implementation_flow_section.dart',
      ),
      contains('FlowToolchainProbe()'),
    );
    expect(
      source('lib/services/flow/flow_handoff_launcher.dart'),
      contains('_probe.guidanceFor('),
    );
  });

  test('the inspector hands a flow result to the hand-off actions', () {
    expect(
      source('lib/features/inspector/widgets/inspector_actions.dart'),
      contains('flowHandoffButtons('),
    );
    final buttons = source(
      'lib/features/inspector/widgets/flow_handoff_buttons.dart',
    );
    expect(buttons, contains('Actions.maybeInvoke<SimcruxActionIntent>'));
    for (final action in const [
      'SimcruxAction.openInKlayout',
      'SimcruxAction.openInOpenroad',
      'SimcruxAction.openInNextpnrGui',
    ]) {
      expect(buttons, contains(action));
    }
    expect(
      source('lib/features/flow/flow_actions.dart'),
      contains('flowHandoffLauncherProvider'),
    );
  });

  test('every Flow action reaches its feature from the one handler map', () {
    final handlers = source('lib/core/shortcuts/simcrux_action_handlers.dart');
    for (final call in const [
      'FlowActions.toggleFlowRuns(',
      'FlowActions.runFlowEntry(',
      'FlowViewer.klayout',
      'FlowViewer.openroadGui',
      'FlowViewer.nextpnrGui',
      'archive: false',
      'archive: true',
    ]) {
      expect(handlers, contains(call));
    }
    // The five Pro seams, each read by its action.
    for (final seam in const [
      'flowTrendsOpenerProvider',
      'flowCompareOpenerProvider',
      'flowPpaOpenerProvider',
      'flowSweepOpenerProvider',
      'flowBaselineWriterProvider',
    ]) {
      expect(handlers, contains('ref.read($seam)'), reason: seam);
    }
  });

  test('the five Pro seams are null in open core', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(flowTrendsOpenerProvider), isNull);
    expect(container.read(flowCompareOpenerProvider), isNull);
    expect(container.read(flowPpaOpenerProvider), isNull);
    expect(container.read(flowSweepOpenerProvider), isNull);
    expect(container.read(flowBaselineWriterProvider), isNull);
  });

  test('gate level: the runner, the comparator and the models are reached '
      'from the CLI and from the app', () {
    final cli = source('lib/core/cli/flow_cli.dart');
    final actions = source('lib/features/flow/flow_actions.dart');
    for (final text in [cli, actions]) {
      expect(text, contains('GlsRunInfo.read('));
      expect(text, contains('GlsPlanner.select('));
      expect(text, contains('GlsPlanner.plan('));
      expect(text, contains('GlsScheduler('));
    }
    expect(cli, contains('glsJunit('));
    expect(cli, contains('glsJson('));
    expect(
      source('lib/services/flow/gate_level/gls_run_info.dart'),
      contains('PdkCellModels.resolve('),
    );
    final runner = source('lib/services/flow/gate_level/gls_runner.dart');
    expect(runner, contains('GlsTraceComparator.compareFiles('));
    expect(runner, contains('GlsNetlistPorts.read('));
    expect(runner, contains('GlsDutScope.find('));
    expect(runner, contains('PdkCellModels.definesFor('));
    expect(
      source('lib/services/flow/flow_run_reading.dart'),
      contains('String librelaneTargetToken('),
    );
  });

  test('gate level: the wrapper reaches the regression runner, which '
      'records the result row and the telemetry', () {
    final runner = source(
      'lib/features/dashboard/providers/regression_runner.dart',
    );
    expect(runner, contains('wrapScheduler'));
    expect(runner, contains('GlsResultView.of('));
    expect(runner, contains('recordFlowGls('));
    expect(runner, contains('flowGlsCompletedEvent('));
    expect(
      source('lib/services/telemetry/flow_telemetry.dart'),
      contains("'flow.gls.completed'"),
    );
    expect(
      source('lib/services/trend_store/sql_trend_store_io.dart'),
      contains('INSERT INTO flow_gls_results'),
    );
    expect(
      source('lib/features/flow/flow_actions.dart'),
      contains('trigger: RegressionTrigger.gls'),
    );
  });

  test('gate level: the results table, the inspector and the Flow Runs '
      'context menu show it', () {
    expect(
      source('lib/features/dashboard/widgets/dashboard_results_table.dart'),
      contains('GlsResultView.of('),
    );
    expect(
      source('lib/features/dashboard/widgets/dashboard_status_icon.dart'),
      contains('GlsLabels.icon('),
    );
    expect(
      source('lib/features/inspector/widgets/inspector_pane.dart'),
      contains('InspectorGlsNotes('),
    );
    expect(
      source('lib/features/inspector/widgets/inspector_actions.dart'),
      contains('SimcruxAction.openGateLevelWaveform'),
    );
    expect(
      source('lib/features/flow/widgets/flow_runs_panel.dart'),
      allOf(
        contains('SimcruxAction.runGateLevelSimulation'),
        contains('contextMenuEntries:'),
      ),
    );
    expect(
      source('lib/features/workspace/widgets/regression_tab_content.dart'),
      contains('GlsLabels.completion('),
    );
  });

  test('gate level: every action reaches its feature from the one handler '
      'map, and the triage reads its Pro seam', () {
    final handlers = source('lib/core/shortcuts/simcrux_action_handlers.dart');
    for (final call in const [
      'FlowActions.runGateLevel(',
      'FlowActions.openGateLevelWaveform(',
      'FlowActions.glsTriageTarget(',
      'ref.read(flowGlsTriageOpenerProvider)',
    ]) {
      expect(handlers, contains(call));
    }
    expect(
      source('lib/features/flow/flow_actions.dart'),
      contains('debugInWaveCruxDispatcherProvider'),
    );
  });

  test('the gate-level Pro seams are null in open core', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(flowGlsTriageOpenerProvider), isNull);
    expect(container.read(flowSdfGlsRunnerProvider), isNull);
    expect(container.read(glsAnnotatedNoteProvider), isNull);
  });

  test('the delay-annotated seams are read where the open core offers and '
      'shows them: the Flow Runs panel hands the runner the shared request, '
      'the inspector leads with the note, and the CLI calls the extension', () {
    final panel = source('lib/features/flow/widgets/flow_runs_panel.dart');
    expect(panel, contains('ref.read(flowSdfGlsRunnerProvider)'));
    expect(panel, contains('ref.watch(flowSdfGlsRunnerProvider)'));
    expect(panel, contains('FlowActions.runGateLevelWithDelays('));
    final actions = source('lib/features/flow/flow_actions.dart');
    expect(actions, contains('read(flowSdfGlsRunnerProvider)'));
    expect(actions, contains('runner.run(context, prepared.request)'));
    expect(
      source('lib/features/inspector/widgets/inspector_gls_notes.dart'),
      contains('ref.watch(glsAnnotatedNoteProvider)'),
    );
    final cli = source('lib/core/cli/flow_cli.dart');
    for (final call in const [
      'glsExtension?.addOptions(',
      'extension.admit(',
      'extension.prepare(',
      'extension?.wrapInner(',
      'extension.report(',
    ]) {
      expect(cli, contains(call));
    }
  });

  test('the Flow Runs panel is a movable tab of both docks, and keeps its '
      'watcher alive', () {
    final docks = source('lib/features/workspace/widgets/simcrux_docks.dart');
    expect(docks, contains('const FlowRunsPanel()'));
    expect(docks, contains('kDockTabFlowRuns'));
    expect(
      source('lib/features/flow/widgets/flow_runs_panel.dart'),
      contains('ref.watch(flowRunWatcherProvider)'),
    );
  });

  test('the Flow providers are per tab, in open core and in the overlay', () {
    final overrides = source(
      'lib/features/workspace/providers/simcrux_tab_overrides.dart',
    );
    expect(overrides, contains('...flowTabOverrides()'));
    final names = source('lib/features/flow/providers/flow_providers.dart');
    for (final provider in const [
      'flowIngestedPathsProvider.overrideWith(',
      'flowSelectedRunProvider.overrideWith(',
      'flowRunWatcherProvider.overrideWith(',
      'flowRunIndexProvider.overrideWith(',
      'flowWorstPathsProvider.overrideWith(',
      'flowFocusedPathProvider.overrideWith(',
      'flowPathRegisterFilterProvider.overrideWith(',
    ]) {
      expect(names, contains(provider));
    }
    expect(flowTabOverrides(), hasLength(7));
  });

  test('the path rows cross-probe through the shared layer, and a peer '
      'reaches the receive filter and the flow_run answer', () {
    final panel = source('lib/features/flow/widgets/flow_runs_panel.dart');
    expect(panel, contains('contextMenuEntries:'));
    expect(panel, contains('focusFlowPath('));
    final actions = source('lib/features/flow/widgets/flow_path_actions.dart');
    expect(actions, contains('crossProbeMenuEntry('));
    expect(actions, contains('broadcastCruxCxpSelection('));
    expect(actions, contains('editorLauncherProvider'));
    final handlers = source('lib/core/shortcuts/simcrux_action_handlers.dart');
    expect(handlers, contains('tabCrossProbeSelection('));
    final inbound = source(
      'lib/features/remote/providers/inbound_request_handler.dart',
    );
    expect(inbound, contains('flowPathRegisterFilterProvider.notifier'));
    expect(inbound, contains('case kCxpFlowRunArtifactKind:'));
    expect(inbound, contains('setFormalReads('));
  });

  test('the panel reads the index and the worst paths, and records '
      'flow.path.opened', () {
    final panel = source('lib/features/flow/widgets/flow_runs_panel.dart');
    expect(panel, contains('flowRunIndexProvider('));
    expect(panel, contains('flowWorstPathsProvider('));
    expect(panel, contains("'flow.path.opened'"));
    expect(
      source('lib/features/flow/providers/flow_providers.dart'),
      allOf(contains('buildFlowRunIndex('), contains('readFlowWorstPaths(')),
    );
  });

  test('ingest opens a zipped artifact through the extractor', () {
    expect(
      source('lib/services/flow/flow_run_ingestor.dart'),
      contains('archives.extract('),
    );
  });

  test('tab diagnostics carry the Flow section', () {
    expect(
      source('lib/features/diagnostics/widgets/tab_diagnostics_drawer.dart'),
      contains('diagnosticsTabFlowSection'),
    );
  });

  test('the hand-off launcher is bound to the consented telemetry', () {
    const service = NoopTelemetryService();
    final container = ProviderContainer(
      overrides: [telemetryServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final launcher = container.read(flowHandoffLauncherProvider);
    expect(launcher, isA<FlowHandoffLauncher>());
    expect(launcher.telemetry, same(service));
  });
}
