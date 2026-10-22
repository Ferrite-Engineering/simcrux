// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';

import '../../flow/flow_panel_harness.dart';

// The receive side of Formal and Flow (free on every tier): a signal a peer
// names with its design's `crux.design_id` filters the formal rows to the
// properties that read it and the worst paths to the paths through that
// register; `request_open_artifact{kind: flow_run}` shows the run SimCrux
// holds for the design; the kinds SimCrux does not open are answered by the
// runtime's own "unsupported"; and no reason repeats what the sender sent.
//
// MUTATION: apply the filters to a signal sent without a design and the
// legacy test-name case fails; answer flow_run from a tab of another design
// and the "another design" case fails; echo the design id in the flow_run
// refusal and its reason check fails.

const PeerIdentity _peer = PeerIdentity(
  peerId: 'netcrux-1-1',
  productName: 'netcrux',
  productVersion: '1.2.0',
);

final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

RegressionConfig _config(
  String projectFile, {
  bool formal = false,
  bool flow = false,
}) => RegressionConfig(
  projectFilePath: projectFile,
  schemaVersion: '1',
  suites: <Suite>[
    Suite(
      name: 'proofs',
      tests: <TestSpec>[
        TestSpec(
          id: 'proofs/fifo',
          name: 'fifo',
          suiteName: 'proofs',
          simulatorId: formal ? 'sby' : 'icarus',
          top: 'fifo',
        ),
      ],
    ),
  ],
  simulatorBinaries: const {},
  flow: flow ? FlowConfig() : null,
);

class _Harness {
  _Harness(this.container, this.managers);

  final ProviderContainer container;
  final List<WorkspaceContainerManagers> managers;

  SimcruxCxpRequestHandler get handler =>
      SimcruxCxpRequestHandler(container.read(_refProvider));

  /// Opens a tab for [projectFile] holding [config], with [index] as its
  /// Flow Runs, and returns its container.
  Future<ProviderContainer> openTab(
    String projectFile,
    RegressionConfig config, {
    FlowRunIndex? index,
  }) async {
    await container.read(workspaceProvider.future);
    final id = await container
        .read(workspaceProvider.notifier)
        .openTab(
          displayName: p.basename(projectFile),
          payload: SimcruxTabPayload(configPath: projectFile),
        );
    final tab = container
        .read(workspaceContainerManagersProvider)
        .tabs
        .containerFor(id);
    tab.read(activeConfigProvider.notifier).replace(config);
    _indexes[id] = index ?? FlowRunIndex.empty;
    return tab;
  }

  final Map<crux.TabId, FlowRunIndex> _indexes = <crux.TabId, FlowRunIndex>{};
}

void main() {
  late Directory workspaceDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    workspaceDir = Directory.systemTemp.createTempSync('simcrux_receive_');
  });

  Future<_Harness> boot() async {
    final managers = <WorkspaceContainerManagers>[];
    late final _Harness harness;
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: <Override>[
        telemetryServiceProvider.overrideWithValue(RecordingTelemetry()),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => workspaceDir,
          ),
        ),
        workspaceContainerManagersProvider.overrideWith((ref) {
          final m = WorkspaceContainerManagers(
            tabs: crux.TabContainerManager(
              rootContainer: container,
              overridesFactory: (tabId) => <Override>[
                activeConfigProvider.overrideWith(ActiveConfigNotifier.new),
                dashboardFilterProvider.overrideWith(
                  DashboardFilterNotifier.new,
                ),
                flowSelectedRunProvider.overrideWith(
                  FlowSelectedRunNotifier.new,
                ),
                flowPathRegisterFilterProvider.overrideWith(
                  FlowPathRegisterFilterNotifier.new,
                ),
                flowRunIndexProvider.overrideWith(
                  (ref, root) async =>
                      harness._indexes[tabId] ?? FlowRunIndex.empty,
                ),
              ],
            ),
            panes: crux.PaneContainerManager(rootContainer: container),
          );
          managers.add(m);
          return m;
        }),
      ],
    );
    harness = _Harness(container, managers);
    addTearDown(() async {
      await container.read(workspaceProvider.notifier).flushPendingSave();
      for (final m in managers) {
        m.dispose();
      }
      container.dispose();
      if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
    });
    return harness;
  }

  String project(String name) =>
      p.join(workspaceDir.path, name, 'simcrux.yaml');

  RequestHighlight signal(String path, {String? designId}) => RequestHighlight(
    element: ElementId(kind: ElementKind.signal, path: path),
    metadata: <String, Object?>{cxpDesignIdMetadataKey: ?designId},
  );

  group('a signal with its design', () {
    test('filters the formal rows to the properties that read it', () async {
      final h = await boot();
      final file = project('fifo');
      final tab = await h.openTab(file, _config(file, formal: true));
      final result = await h.handler.highlight(
        signal('fifo.full', designId: cxpDesignIdForPath(file)),
        _peer,
      );
      expect(result.honored, isTrue, reason: result.reason);
      final filter = tab.read(dashboardFilterProvider);
      expect(filter.formalReads, 'fifo.full');
      expect(filter.testNameSubstring, isEmpty);
    });

    test('filters the worst paths to the paths through the register, and '
        'shows Flow Runs', () async {
      final h = await boot();
      final file = project('counter');
      final tab = await h.openTab(file, _config(file, flow: true));
      final result = await h.handler.highlight(
        signal('top.u_div.cnt_q', designId: cxpDesignIdForPath(file)),
        _peer,
      );
      expect(result.honored, isTrue, reason: result.reason);
      expect(tab.read(flowPathRegisterFilterProvider), 'top.u_div.cnt_q');
      expect(h.container.read(flowRunsVisibleProvider), isTrue);
    });

    test('without a design, a simulation project keeps the test-name '
        'filter', () async {
      final h = await boot();
      final file = project('fifo');
      final tab = await h.openTab(file, _config(file, formal: true));
      final result = await h.handler.highlight(signal('fifo.full'), _peer);
      expect(result.honored, isTrue);
      expect(tab.read(dashboardFilterProvider).testNameSubstring, 'full');
      expect(tab.read(dashboardFilterProvider).formalReads, isEmpty);
    });
  });

  group('request_open_artifact', () {
    RequestOpenArtifact ask(String designId, String kind, {String? path}) =>
        RequestOpenArtifact(designId: designId, artifactKind: kind, path: path);

    test('flow_run selects the run held for the design and shows Flow '
        'Runs', () async {
      final h = await boot();
      final file = p.join(kFlowProjectRoot, 'simcrux.yaml');
      final tab = await h.openTab(
        file,
        _config(file, flow: true),
        index: flowPanelIndex(),
      );
      // The hint names the older nextpnr run, one this project holds.
      final older = flowPanelIndex().runs.last;
      final result = await h.handler.openArtifact(
        ask(
          cxpDesignIdForPath(file),
          kCxpFlowRunArtifactKind,
          path: older.root,
        ),
        _peer,
      );
      expect(result.honored, isTrue, reason: result.reason);
      expect(tab.read(flowSelectedRunProvider)?.root, older.root);
      expect(h.container.read(flowRunsVisibleProvider), isTrue);
    });

    test('flow_run ignores a hint it does not hold: the newest run', () async {
      final h = await boot();
      final file = p.join(kFlowProjectRoot, 'simcrux.yaml');
      final tab = await h.openTab(
        file,
        _config(file, flow: true),
        index: flowPanelIndex(),
      );
      final result = await h.handler.openArtifact(
        ask(cxpDesignIdForPath(file), kCxpFlowRunArtifactKind, path: '/etc'),
        _peer,
      );
      expect(result.honored, isTrue, reason: result.reason);
      expect(
        tab.read(flowSelectedRunProvider)?.root,
        flowPanelIndex().runs.first.root,
      );
    });

    test('flow_run for another design, or none held: refused without '
        'repeating the design', () async {
      final h = await boot();
      final file = p.join(kFlowProjectRoot, 'simcrux.yaml');
      await h.openTab(file, _config(file, flow: true), index: flowPanelIndex());
      const other = 'feedfacecafebeef';
      final result = await h.handler.openArtifact(
        ask(other, kCxpFlowRunArtifactKind, path: '/w/runs/RUN_1'),
        _peer,
      );
      expect(result.honored, isFalse);
      expect(result.reason, isNot(contains(other)));
      expect(result.reason, isNot(contains('/w/runs')));
    });

    for (final kind in <String>['timing_report', 'waveform', 'netlist', 'x']) {
      test('$kind: the runtime\'s own "unsupported", never the kind', () async {
        final h = await boot();
        final result = await h.handler.openArtifact(
          ask('d', kind, path: '/w/report.json'),
          _peer,
        );
        expect(result.honored, isFalse);
        expect(result.reason, 'unsupported');
      });
    }
  });
}
