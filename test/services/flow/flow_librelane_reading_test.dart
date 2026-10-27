// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// SimCrux reads the captured LibreLane runs (verification/fixtures/flow/
// librelane/, LibreLane 3.0.15 and 3.0.16 on open PDKs): verdict, ingest,
// worst paths, SARIF and the hand-off, each against the case's hand-written
// case.expected.json and the RTL's mapping.expected.json, never against what
// a reader produced. LibreLane results are findings, not signoff.

import 'dart:convert';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/services/flow/flow_export.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

const _root = 'verification/fixtures/flow/librelane';

String _abs(String path) => p.normalize(Directory(path).absolute.path);

Map<String, Object?> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

/// Every committed case: `<version>/<case>` holding `case.expected.json`.
List<String> _cases() => <String>[
  for (final version in Directory(_root).listSync().whereType<Directory>())
    for (final c in version.listSync().whereType<Directory>())
      if (File(p.join(c.path, 'case.expected.json')).existsSync())
        p.relative(c.path, from: _root),
]..sort();

void main() {
  final mapping = _json(p.join(_root, 'mapping.expected.json'));

  test('the fixture set exists and covers both verified releases', () {
    expect(Directory(_root).existsSync(), isTrue, reason: '$_root missing');
    final cases = _cases();
    expect(cases.where((c) => c.startsWith('3.0.16/')), isNotEmpty);
    expect(cases.where((c) => c.startsWith('3.0.15/')), isNotEmpty);
  });

  group('verdict and ingest', () {
    for (final name in _cases()) {
      test(name, () async {
        final dir = p.join(_root, name);
        final want = _json(p.join(dir, 'case.expected.json'));
        final run = _abs(p.join(dir, 'run'));

        final reading = await const LibreLaneVersionedReader().read(run);
        expect(reading.verdict.wireName, want['verdict']);
        expect(reading.reader, FlowReaderIds.librelane);
        expect(reading.run.ref.verified, isTrue);
        expect(reading.unsupported, isNull);
        final metrics = reading.toMetrics(exitCode: 2);
        expect(metrics[FlowMetricKeys.readerVerified], 'true');
        expect(metrics.containsKey(FlowMetricKeys.readerUnsupported), isFalse);
        // The exit status is recorded and never the verdict.
        expect(metrics[FlowMetricKeys.processExitCode], '2');
        expect(
          <String>[
            for (final s in reading.run.steps)
              if (s.status == FlowStepStatus.failed) s.dir,
          ],
          want['steps_without_state_out'],
        );
        if (want['verdict'] == 'stopped') {
          final ids = want['step_ids']! as Map<String, Object?>;
          final last = (want['steps_without_state_out']! as List).last;
          expect(reading.stoppedStep, ids[last]);
          expect(metrics[FlowMetricKeys.stoppedStep], ids[last]);
        }

        final items = await const FlowRunIngestor().ingest(
          <String>[
            run,
          ],
          allowedRoots: <String>[_abs(_root)],
        );
        expect(items, hasLength(1));
        final ingested = items.single.reading!;
        expect(ingested.verdict, reading.verdict);
        final result = FlowRunIngestor.resultFor(
          ingested,
          now: DateTime.utc(2026, 10, 22),
        );
        expect(
          result.status,
          want['verdict'] == 'met' ? TestStatus.pass : TestStatus.fail,
        );
        expect(result.didExecute, isFalse);
        final record = FlowRunIngestor.recordFor(
          ingested,
          runId: result.runId,
          testId: result.testId,
        );
        expect(record.steps, hasLength(reading.run.steps.length));
      });
    }
  });

  test('readForResult re-reads a launched result through the seam', () async {
    final run = _abs(p.join(_root, '3.0.16', 'sky130A_timing', 'run'));
    var seen = '';
    final reading = await FlowRunIngestor.readForResult(
      <String, String>{
        FlowMetricKeys.runDir: run,
        FlowMetricKeys.kind: FlowKind.librelane.wireName,
        FlowMetricKeys.tag: p.basename(p.dirname(run)),
      },
      librelane: (root, {tag}) {
        seen = root;
        return const LibreLaneVersionedReader().read(root, tag: tag);
      },
    );
    expect(seen, run);
    expect(reading!.verdict, FlowVerdict.violated);
  });

  group('worst paths', () {
    test('the timing case maps its worst register path to the RTL', () async {
      final run = _abs(p.join(_root, '3.0.16', 'sky130A_timing', 'run'));
      final reading = await const LibreLaneVersionedReader().read(run);
      final paths = await readFlowWorstPaths(reading.run.ref);
      expect(paths.mapped, isTrue);
      expect(paths.rows, isNotEmpty);
      expect(paths.rows.first.path.slackPs, lessThan(0));
      final regToReg = paths.rows.firstWhere(
        (r) =>
            r.endpoint.fidelity == MappingFidelity.register &&
            r.startpoint.fidelity == MappingFidelity.register,
      );
      expect(regToReg.endpoint.register, mapping['end_register']);
      expect(
        mapping['start_registers'],
        contains(regToReg.startpoint.register),
      );
    });

    test('every PDK lists met paths at its nominal corner', () async {
      for (final name in ['sky130A_met', 'gf180mcuD_met', 'ihp-sg13g2_met']) {
        final run = _abs(p.join(_root, '3.0.16', name, 'run'));
        final reading = await const LibreLaneVersionedReader().read(run);
        expect(reading.librelane!.timingCorner, startsWith('nom_'));
        final paths = await readFlowWorstPaths(reading.run.ref);
        expect(paths.rows, isNotEmpty, reason: name);
        expect(paths.rows.first.path.slackPs, greaterThanOrEqualTo(0));
      }
    });

    test('a run without a setup listing says it has none', () async {
      final tmp = Directory.systemTemp.createTempSync('flow_ll_nolisting_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final run = Directory(p.join(tmp.path, 'runs', 'RUN'))
        ..createSync(recursive: true);
      Directory(p.join(run.path, '01-yosys-synthesis')).createSync();
      final paths = await readFlowWorstPaths(
        FlowRunRef(
          kind: FlowKind.librelane,
          root: run.resolveSymbolicLinksSync(),
          tag: 'RUN',
          readerVersion: '3.0',
          verified: false,
        ),
      );
      expect(paths.rows, isEmpty);
      expect(paths.gap, FlowWorstPathsGap.librelaneNotRead);
    });
  });

  group('SARIF', () {
    Future<List<Map<String, Object?>>> results(String name) async {
      final run = _abs(p.join(_root, '3.0.16', name, 'run'));
      final reading = await const LibreLaneVersionedReader().read(run);
      final log =
          jsonDecode(await flowSarifWithPaths(reading)) as Map<String, Object?>;
      return <Map<String, Object?>>[
        for (final r
            in ((log['runs']! as List).single as Map)['results']! as List)
          r! as Map<String, Object?>,
      ];
    }

    test('the timing case anchors setup at the endpoint register', () async {
      final all = await results('sky130A_timing');
      final timing = all.singleWhere((r) => r['ruleId'] == 'flow/timing-path');
      expect(timing['level'], 'warning');
      expect(
        (timing['message']! as Map)['text'],
        contains(mapping['end_register']! as String),
      );
    });

    test('the DRC case reports its checks, a waived one as a note', () async {
      final all = await results('sky130A_drc');
      final rules = all.map((r) => r['ruleId']).toSet();
      expect(rules, containsAll(<String>['flow/drc', 'flow/lvs']));
      final route = all.singleWhere(
        (r) => (r['properties']! as Map)['metric'] == 'route__drc_errors',
      );
      expect(route['level'], 'note');
    });

    test('a met case has no warnings', () async {
      final all = await results('sky130A_met');
      expect(all.where((r) => r['level'] == 'warning'), isEmpty);
    });
  });

  group('hand-off', () {
    late Directory tmp;
    setUp(
      () => tmp = Directory(
        Directory.systemTemp
            .createTempSync('flow_ll_handoff_')
            .resolveSymbolicLinksSync(),
      ),
    );
    tearDown(() => tmp.deleteSync(recursive: true));

    /// A design directory with `config.yaml` and a run under `runs/` whose
    /// steps carry output state, copied from a fixture.
    (FlowEntry, String) project(String fixture) {
      File(p.join(tmp.path, 'config.yaml')).writeAsStringSync('{}');
      final run = Directory(p.join(tmp.path, 'runs', 'RUN_A'))
        ..createSync(recursive: true);
      final source = Directory(p.join(_root, '3.0.16', fixture, 'run'));
      for (final step in source.listSync().whereType<Directory>()) {
        final name = p.basename(step.path);
        if (!kLibreLaneStepDirectory.hasMatch(name)) continue;
        final target = Directory(p.join(run.path, name))..createSync();
        final state = File(p.join(step.path, 'state_out.json'));
        if (state.existsSync()) {
          File(p.join(target.path, 'state_out.json')).writeAsStringSync('{}');
        }
      }
      return (
        FlowEntry(
          name: 'adder',
          kind: FlowKind.librelane,
          config: 'config.yaml',
          pdk: 'sky130A',
          projectRoot: tmp.path,
        ),
        run.path,
      );
    }

    test("KLayout through LibreLane's own flow, from the newest state, "
        'under a fresh tag', () {
      final (entry, run) = project('sky130A_met');
      final argv = FlowHandoffLauncher().librelaneOwnFlow(
        FlowViewer.klayout,
        runRoot: run,
        entry: entry,
        now: DateTime.utc(2026, 10, 22, 12),
      )!;
      expect(argv.first, 'librelane');
      expect(argv, containsAllInOrder(<String>['--flow', 'OpenInKLayout']));
      final state = argv[argv.indexOf('--with-initial-state') + 1];
      expect(state, endsWith('76-misc-reportmanufacturability/state_out.json'));
      expect(p.isWithin(run, state), isTrue);
      final tag = argv[argv.indexOf('--run-tag') + 1];
      expect(tag, 'simcrux-view-20261022T120000Z');
      expect(argv.last, p.join(tmp.path, 'config.yaml'));
      expect(argv, isNot(contains('--overwrite')));
      expect(argv, isNot(contains('--last-run')));
    });

    test('OpenROAD through the nix launcher needs a checkout', () {
      final (entry, run) = project('sky130A_met');
      const nix = FlowToolSettings(launcher: FlowLauncher.nix);
      expect(
        FlowHandoffLauncher().librelaneOwnFlow(
          FlowViewer.openroadGui,
          runRoot: run,
          entry: entry,
          settings: nix,
          now: DateTime.utc(2026, 10, 22),
        ),
        isNull,
      );
      final argv = FlowHandoffLauncher().librelaneOwnFlow(
        FlowViewer.openroadGui,
        runRoot: run,
        entry: entry,
        settings: nix,
        librelanePath: tmp.path,
        now: DateTime.utc(2026, 10, 22),
      )!;
      expect(argv.take(5), <String>[
        'nix',
        'develop',
        tmp.path,
        '--command',
        'librelane',
      ]);
      expect(argv, containsAllInOrder(<String>['--flow', 'OpenInOpenROAD']));
    });

    test('docker, a stranger run or no entry fall back to the viewer', () {
      final (entry, run) = project('sky130A_met');
      const docker = FlowToolSettings(launcher: FlowLauncher.docker);
      final launcher = FlowHandoffLauncher();
      expect(
        launcher.librelaneOwnFlow(
          FlowViewer.klayout,
          runRoot: run,
          entry: entry,
          settings: docker,
          now: DateTime.utc(2026, 10, 22),
        ),
        isNull,
      );
      expect(
        launcher.librelaneOwnFlow(
          FlowViewer.klayout,
          runRoot: _abs(p.join(_root, '3.0.16', 'sky130A_met', 'run')),
          entry: entry,
          now: DateTime.utc(2026, 10, 22),
        ),
        isNull,
      );
      // No entry: KLayout on the final GDS, with the run's DRC markers.
      final drc = _abs(p.join(_root, '3.0.16', 'sky130A_drc', 'run'));
      final planned = launcher.plan(
        FlowViewer.klayout,
        kind: FlowKind.librelane,
        runRoot: drc,
      );
      expect(planned.argv!.first, 'klayout');
      expect(planned.argv![1], endsWith('.gds'));
      expect(planned.argv![2], '-m');
      expect(planned.argv![3], endsWith('drc.klayout.lyrdb'));
    });

    test('the OpenROAD read script gets a fresh directory of its own, made '
        'directly in the system temporary directory', () {
      final launcher = FlowHandoffLauncher();
      final first = launcher.writeReadScript('/run/final/odb/top.odb')!;
      final second = launcher.writeReadScript('/run/final/odb/top.odb')!;
      for (final script in <String>[first, second]) {
        addTearDown(() => File(script).parent.deleteSync(recursive: true));
      }
      final dir = File(first).parent;
      expect(p.basename(dir.path), startsWith('simcrux_handoff_'));
      // Never under a fixed name another user of a shared /tmp could own.
      expect(
        dir.parent.resolveSymbolicLinksSync(),
        Directory.systemTemp.resolveSymbolicLinksSync(),
      );
      expect(File(second).parent.path, isNot(dir.path));
      expect(
        File(first).readAsStringSync(),
        'read_db {/run/final/odb/top.odb}\n',
      );
    });
  });
}
