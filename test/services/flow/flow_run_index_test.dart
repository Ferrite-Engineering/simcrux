// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

import 'librelane_run_builder.dart';

/// The Flow Runs panel's index: the project's own runs, its `ingest:` paths
/// and what the user ingested, newest first, read-only; the last-run delta;
/// the worst paths mapped to the RTL; and the bounded log tail.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory tmp;

  // Resolved: run roots are read with their links resolved (macOS's
  // temporary directory is under the /var link).
  setUp(
    () => tmp = Directory(
      Directory.systemTemp
          .createTempSync('flow_index_')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A nextpnr run of entry [entry] with tag [tag] holding fixture [name]'s
  /// report (and its synthesised netlist as `synth.json` when it has one),
  /// last modified at [modified].
  String nextpnrRun(
    String entry,
    String tag,
    String name, {
    required DateTime modified,
  }) {
    final dir = Directory(p.join(tmp.path, 'runs', entry, tag))
      ..createSync(recursive: true);
    File(
      '$fixtures/$name/report.json',
    ).copySync(p.join(dir.path, 'report.json')).setLastModifiedSync(modified);
    final netlist = File('$fixtures/$name/netlist.json');
    if (netlist.existsSync()) netlist.copySync(p.join(dir.path, 'synth.json'));
    return dir.path;
  }

  FlowEntry adder() => FlowEntry(name: 'adder', kind: FlowKind.nextpnr);

  test('the project runs are listed newest first, with the delta against '
      'the run before', () async {
    final older = nextpnrRun(
      'adder',
      'r1',
      'path_ice40_met',
      modified: DateTime.utc(2026, 10, 2),
    );
    final newer = nextpnrRun(
      'adder',
      'r2',
      'path_ice40_violated',
      modified: DateTime.utc(2026, 10, 3),
    );
    final index = await buildFlowRunIndex(
      FlowRunIndexRequest(projectRoot: tmp.path, entries: <FlowEntry>[adder()]),
    );
    expect(index.runs.map((r) => r.root), <String>[newer, older]);
    expect(index.runs.first.design, 'adder');
    expect(index.runs.first.origin, FlowRunOrigin.project);
    expect(index.previousOf(index.runs.first)?.root, older);
    expect(index.previousOf(index.runs.last), isNull);

    final delta = flowRunDelta(
      index.runs.first.reading,
      index.runs.last.reading,
    );
    expect(delta, isNotNull);
    expect(delta!.kind, FlowDeltaKind.worstSlack);
    // The violated run misses its clock where the met one made it: its
    // slack is lower, so it is worse.
    expect(delta.improved, isFalse);
  });

  test('ingest paths: the project list within the project, a user path '
      'within itself, and a path naming no run is a problem', () async {
    final elsewhere = Directory.systemTemp.createTempSync('flow_elsewhere_');
    addTearDown(() => elsewhere.deleteSync(recursive: true));
    File('$fixtures/path_ecp5_met/report.json').copySync(
      p.join(elsewhere.path, 'report.json'),
    );
    LibreLaneRunBuilder(tmp.path, tag: 'RUN_A')
      ..step('yosys-synthesis')
      ..finalMetrics(cleanMetrics);
    final index = await buildFlowRunIndex(
      FlowRunIndexRequest(
        projectRoot: tmp.path,
        configIngest: const <String>['runs/RUN_A', 'nothing_here'],
        userIngest: <String>[elsewhere.path],
      ),
    );
    expect(index.runs.map((r) => r.reading.run.ref.kind).toSet(), {
      FlowKind.librelane,
      FlowKind.nextpnr,
    });
    expect(index.runs.every((r) => r.origin == FlowRunOrigin.ingested), isTrue);
    expect(index.problems, hasLength(1));
    expect(index.problems.single, contains('nothing_here'));
  });

  test('a project ingest path outside the project is refused', () async {
    final elsewhere = Directory.systemTemp.createTempSync('flow_outside_');
    addTearDown(() => elsewhere.deleteSync(recursive: true));
    File('$fixtures/path_ecp5_met/report.json').copySync(
      p.join(elsewhere.path, 'report.json'),
    );
    final index = await buildFlowRunIndex(
      FlowRunIndexRequest(
        projectRoot: tmp.path,
        configIngest: <String>[elsewhere.path],
      ),
    );
    expect(index.runs, isEmpty);
    expect(index.problems, hasLength(1));
  });

  test('entries whose run directories do not exist yet are no news', () async {
    final index = await buildFlowRunIndex(
      FlowRunIndexRequest(projectRoot: tmp.path, entries: <FlowEntry>[adder()]),
    );
    expect(index.runs, isEmpty);
    expect(index.problems, isEmpty);
  });

  group('worst paths', () {
    test('an iCE40 run maps its worst path to the RTL register', () async {
      final root = nextpnrRun(
        'adder',
        'r1',
        'path_ice40_met',
        modified: DateTime.utc(2026, 10, 2),
      );
      final paths = await readFlowWorstPaths(
        FlowRunRef(
          kind: FlowKind.nextpnr,
          root: root,
          tag: 'r1',
          readerVersion: 'nextpnr-report',
          verified: true,
        ),
      );
      expect(paths.mapped, isTrue);
      expect(paths.rows, isNotEmpty);
      // From the RTL's meaning (mapping.expected.json): the adder's path
      // ends at the register sum_q, and iCE40 cell names carry it.
      final end = paths.rows.first.endpoint;
      expect(end.fidelity, MappingFidelity.register);
      expect(end.register, startsWith('sum_q'));
    });

    test('a report without its netlists lists its paths unmapped', () async {
      final dir = Directory(p.join(tmp.path, 'bare'))..createSync();
      File('$fixtures/path_ecp5_violated/report.json').copySync(
        p.join(dir.path, 'report.json'),
      );
      final paths = await readFlowWorstPaths(
        FlowRunRef(
          kind: FlowKind.nextpnr,
          root: dir.path,
          tag: 'bare',
          readerVersion: 'nextpnr-report',
          verified: true,
        ),
      );
      expect(paths.mapped, isFalse);
      expect(paths.rows, isNotEmpty);
      expect(
        paths.rows.every((r) => r.fidelity == MappingFidelity.unmapped),
        isTrue,
      );
    });

    test('a LibreLane run says its paths are not read yet', () async {
      final paths = await readFlowWorstPaths(
        FlowRunRef(
          kind: FlowKind.librelane,
          root: tmp.path,
          tag: 't',
          readerVersion: 'unknown',
          verified: false,
        ),
      );
      expect(paths.rows, isEmpty);
      expect(paths.gap, FlowWorstPathsGap.librelaneNotRead);
    });

    test("a path's fidelity is its weaker end", () {
      const path = TimingPath(
        rank: 1,
        startpoint: 'a',
        endpoint: 'b',
        delayPs: 1,
        delayNs: 0.001,
        segments: <TimingSegment>[],
        origin: TimingPathOrigin.nextpnrReport,
      );
      const row = FlowPathRow(
        path: path,
        startpoint: RtlMapping(fidelity: MappingFidelity.register),
        endpoint: RtlMapping(fidelity: MappingFidelity.span),
      );
      expect(row.fidelity, MappingFidelity.span);
    });
  });

  group('log tail', () {
    test('only the tail is read, the first partial line dropped', () async {
      final log = File(p.join(tmp.path, 'step.log'))
        ..writeAsStringSync(
          List<String>.generate(5000, (i) => 'line $i').join('\n'),
        );
      final tail = await readFlowLogTail(log.path, maxBytes: 1000);
      expect(tail.truncated, isTrue);
      expect(tail.lines.last, 'line 4999');
      expect(tail.lines.first, startsWith('line '));
      expect(tail.lines.join('\n').length, lessThan(1000));
    });

    test('a short log is read whole', () async {
      final log = File(p.join(tmp.path, 'short.log'))
        ..writeAsStringSync('a\nb\n');
      final tail = await readFlowLogTail(log.path);
      expect(tail.lines, ['a', 'b']);
      expect(tail.truncated, isFalse);
    });

    test(
      "a step's log is the largest log in its directory, inside the run",
      () {
        final run = LibreLaneRunBuilder(tmp.path)..step('openroad-stapostpnr');
        final stepDir = Directory(run.root)
            .listSync()
            .whereType<Directory>()
            .firstWhere((d) => p.basename(d.path).endsWith('stapostpnr'));
        File(p.join(stepDir.path, 'small.log')).writeAsStringSync('x');
        File(p.join(stepDir.path, 'sta.log')).writeAsStringSync('x' * 100);
        final flowRun = FlowRun(
          ref: FlowRunRef(
            kind: FlowKind.librelane,
            root: run.root,
            tag: 't',
            readerVersion: 'unknown',
            verified: false,
          ),
          verdict: FlowVerdict.stopped,
        );
        final step = FlowStep(
          ordinal: 1,
          id: 'openroad-stapostpnr',
          tool: 'openroad',
          dir: stepDir.path,
          status: FlowStepStatus.completed,
        );
        expect(p.basename(flowStepLogPath(flowRun, step)!), 'sta.log');
      },
    );
  });
}
