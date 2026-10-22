// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_license/crux_license.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/flow/widgets/flow_runs_panel.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// Hand-built Flow Runs panel content: three runs of two designs, read the
/// way the readers would read them, with no file behind any of them.
///
/// The numbers mean what they say (a run that misses its clock has the
/// lower slack); nothing here comes from the code under test.
const String kFlowProjectRoot = '/projects/counter';

/// A LibreLane run read best-effort: steps, corner metrics, unverified.
FlowReading librelaneReading() => const FlowReading(
  run: FlowRun(
    ref: FlowRunRef(
      kind: FlowKind.librelane,
      root: '$kFlowProjectRoot/runs/RUN_2',
      tag: 'RUN_2',
      readerVersion: '3.0.16',
      verified: false,
    ),
    verdict: FlowVerdict.violated,
    steps: <FlowStep>[
      FlowStep(
        ordinal: 1,
        id: 'yosys-synthesis',
        tool: 'yosys',
        dir: '$kFlowProjectRoot/runs/RUN_2/01-yosys-synthesis',
        status: FlowStepStatus.completed,
        runtime: Duration(seconds: 12),
      ),
      FlowStep(
        ordinal: 2,
        id: 'openroad-stapostpnr',
        tool: 'openroad',
        dir: '$kFlowProjectRoot/runs/RUN_2/02-openroad-stapostpnr',
        status: FlowStepStatus.completed,
      ),
    ],
    metrics: <String, Object?>{
      'timing__setup__ws': -0.25,
      'timing__setup__ws__corner:nom_tt_025C_1v80': 0.4,
      'timing__setup__ws__corner:max_ss_100C_1v60': -0.25,
      'route__drc_errors': 0,
      'design__instance__count': 412,
    },
    toolVersions: <String, String>{'librelane': '3.0.16'},
  ),
  reader: 'librelane-contract',
  target: 'sky130',
  unsupported: FlowReaderUnsupported.versionUnknown,
  wnsNs: -0.25,
);

/// A nextpnr run of `adder`, verified, with [wns] and [fmax].
FlowReading nextpnrReading(
  String tag, {
  required double wns,
  required double fmax,
}) => FlowReading(
  run: FlowRun(
    ref: FlowRunRef(
      kind: FlowKind.nextpnr,
      root: '$kFlowProjectRoot/runs/adder/$tag',
      tag: tag,
      readerVersion: 'nextpnr-report',
      verified: true,
    ),
    verdict: wns < 0 ? FlowVerdict.violated : FlowVerdict.met,
    metrics: <String, Object?>{
      'timing__setup__wns': wns,
      'fmax__achieved__mhz': fmax,
    },
  ),
  reader: 'nextpnr-report',
  target: 'ice40',
  wnsNs: wns,
  fmaxMhz: fmax,
);

/// The index the panel lists: the LibreLane run, then two nextpnr runs of
/// `adder`, the newer one worse.
FlowRunIndex flowPanelIndex() => FlowRunIndex(
  runs: <FlowRunIndexEntry>[
    FlowRunIndexEntry(
      reading: librelaneReading(),
      origin: FlowRunOrigin.project,
    ),
    FlowRunIndexEntry(
      reading: nextpnrReading('t2', wns: -1.5, fmax: 40),
      origin: FlowRunOrigin.project,
    ),
    FlowRunIndexEntry(
      reading: nextpnrReading('t1', wns: 0.5, fmax: 52),
      origin: FlowRunOrigin.project,
    ),
  ],
);

/// Two worst paths, the first mapped to registers at both ends.
FlowWorstPaths flowPanelPaths() => FlowWorstPaths(
  mapped: true,
  rows: const <FlowPathRow>[
    FlowPathRow(
      path: TimingPath(
        rank: 1,
        clockTo: 'clk',
        startpoint: 'src_a_SB_DFF_Q',
        endpoint: 'sum_q_SB_DFF_Q_3',
        delayPs: 9600,
        delayNs: 9.6,
        segments: <TimingSegment>[
          TimingSegment(
            type: TimingSegmentType.clkToQ,
            rawType: 'clk-to-q',
            fromCell: 'src_a_SB_DFF_Q',
            toCell: 'src_a_SB_DFF_Q',
            delayPs: 540,
            delayNs: 0.54,
          ),
          TimingSegment(
            type: TimingSegmentType.logic,
            rawType: 'logic',
            fromCell: 'sum_SB_LUT4_O',
            toCell: 'sum_q_SB_DFF_Q_3',
            delayPs: 9060,
            delayNs: 9.06,
          ),
        ],
        origin: TimingPathOrigin.nextpnrReport,
      ),
      startpoint: RtlMapping(
        fidelity: MappingFidelity.register,
        register: 'src_a',
      ),
      endpoint: RtlMapping(
        fidelity: MappingFidelity.register,
        register: 'sum_q',
      ),
      segments: <RtlMapping>[
        RtlMapping(fidelity: MappingFidelity.register, register: 'src_a'),
        RtlMapping.unmapped,
      ],
    ),
    FlowPathRow(
      path: TimingPath(
        rank: 2,
        startpoint: 'in_b',
        endpoint: 'sum_q_SB_DFF_Q_2',
        delayPs: 8100,
        delayNs: 8.1,
        segments: <TimingSegment>[],
        origin: TimingPathOrigin.nextpnrReport,
      ),
    ),
  ],
);

/// An `activeConfigProvider` holding [config].
class FixedFlowConfig extends ActiveConfigNotifier {
  /// Creates the notifier.
  FixedFlowConfig(this.config);

  /// The config it holds.
  final RegressionConfig? config;

  @override
  RegressionConfig? build() => config;
}

/// The project the panel reads.
RegressionConfig flowPanelConfig() => RegressionConfig(
  projectFilePath: '$kFlowProjectRoot/simcrux.yaml',
  schemaVersion: '1',
  suites: const <Suite>[],
  simulatorBinaries: const {},
);

/// Records every telemetry event.
class RecordingTelemetry implements TelemetryService {
  /// Every event, oldest first.
  final List<TelemetryEvent> events = <TelemetryEvent>[];

  @override
  void record(TelemetryEvent event) => events.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Pumps the Flow Runs panel at [size] over [index] and [paths], at Open
/// Core with the beta period over, recording dispatched actions in
/// [dispatched].
Future<ProviderContainer> pumpFlowPanel(
  WidgetTester tester, {
  FlowRunIndex? index,
  FlowWorstPaths? paths,
  RegressionConfig? config,
  bool withConfig = true,
  Size size = const Size(1000, 600),
  Locale locale = const Locale('en'),
  List<SimcruxAction>? dispatched,
  TelemetryService? telemetry,
  List<Override> extra = const <Override>[],
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      licenseTierProvider.overrideWithValue(LicenseTier.openCore),
      betaPeriodProvider.overrideWithValue(false),
      activeConfigProvider.overrideWith(
        () =>
            FixedFlowConfig(withConfig ? (config ?? flowPanelConfig()) : null),
      ),
      flowRunIndexProvider.overrideWith(
        (ref, root) async => index ?? flowPanelIndex(),
      ),
      flowWorstPathsProvider.overrideWith(
        (ref, runRef) async => paths ?? flowPanelPaths(),
      ),
      telemetryServiceProvider.overrideWithValue(
        telemetry ?? RecordingTelemetry(),
      ),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(
          body: Actions(
            actions: <Type, Action<Intent>>{
              SimcruxActionIntent: CallbackAction<SimcruxActionIntent>(
                onInvoke: (intent) {
                  dispatched?.add(intent.action);
                  return null;
                },
              ),
            },
            child: const FlowRunsPanel(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
