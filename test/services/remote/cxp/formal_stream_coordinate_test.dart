// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/remote/cxp/formal_stream_coordinate.dart';

import '../../../support/formal_fixture_checks.dart';

// The producer half of CXP §9.9.3 `formal.trace_step`: the step a formal row
// can state for the trace it hands WaveCrux, and the registered `formal.`
// keys beside it. Expectations come from the corpus's hand-written
// expectations (written from the RTL before any capture existed) and from
// each trace's own `smt_step` counter, read from the file's text, never
// from the code under test.
//
// MUTATION: fall back to `formal.depth_reached` when no property states a
// step, and the "no step, no coordinate" case fails (a prove task's depth
// is the induction step, 5, not the failing step); drop the multiclock
// check and its case fails; send the partition step without `sub_id` and
// the EQY case fails.

TestResult _row(
  Map<String, String> metrics, {
  String? waveform,
  TestStatus status = TestStatus.fail,
}) => TestResult(
  testId: 'proofs/handshake',
  runId: 'r',
  status: status,
  startedAt: DateTime.utc(2026, 10),
  finishedAt: DateTime.utc(2026, 10),
  waveformPath: waveform,
  metrics: metrics,
);

/// The time each `smt_step` value sits at in [vcd]'s text, the oracle
/// WaveCrux's receiver tests read too.
Map<int, int> _smtSteps(String vcd) {
  final declaration = RegExp(
    r'\$var\s+integer\s+\d+\s+(\S+)\s+smt_step\s+\$end',
  ).firstMatch(vcd);
  if (declaration == null) return const {};
  final id = declaration.group(1)!;
  final steps = <int, int>{};
  var time = 0;
  for (final line in vcd.split('\n')) {
    final text = line.trim();
    if (text.startsWith('#')) {
      time = int.parse(text.substring(1));
    } else if (text.startsWith('b') && text.endsWith(' $id')) {
      steps[int.parse(
            text.substring(1, text.length - id.length - 1),
            radix: 2,
          )] =
          time;
    }
  }
  return steps;
}

/// FNV-1a/32 over [files] in sorted relative-path order, each as its posix
/// path under [root], a newline, then its bytes with carriage returns
/// dropped: WaveCrux's recipe for its copy of this corpus.
String _corpusDigest(String root, List<File> files) {
  final entries = [
    for (final f in files)
      (p.posix.joinAll(p.split(p.relative(f.path, from: root))), f),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  var hash = 0x811C9DC5;
  void feed(Iterable<int> units) {
    for (final unit in units) {
      if (unit == 0x0D) continue;
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
  }

  for (final (rel, file) in entries) {
    feed(rel.codeUnits);
    feed(const [0x0A]);
    feed(file.readAsBytesSync());
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The digest WaveCrux pins for its byte-identical copy of these 27 traces
/// (its `formal_stream_coordinate_resolver_test.dart`). Equal digests are
/// the proof that the producer and the receiver are tested on one corpus.
const String kFormalCorpusDigest = '0fab99c0';

Map<String, String> _sbyMetrics({
  String verdict = 'FAIL',
  String mode = 'prove',
  String kind = 'ASSERT',
  String status = 'counterexample',
  String? step = '6',
  String trace = 'engine_0/trace.vcd',
  String? label,
}) => <String, String>{
  'formal.tool': 'sby',
  'formal.verdict': verdict,
  'formal.mode': mode,
  'formal.run_mode': 'normal',
  'formal.depth_configured': '20',
  'formal.depth_reached': '5',
  'formal.property.0.kind': 'ASSERT',
  'formal.property.0.location': 'handshake_imm.sv:43.15-43.30',
  'formal.property.0.status': 'proved',
  'formal.property.1.kind': kind,
  'formal.property.1.location': 'handshake_imm.sv:45.15-45.38',
  'formal.property.1.status': status,
  'formal.property.1.step': ?step,
  'formal.property.1.trace': trace,
  'formal.property.1.label': ?label,
};

void main() {
  const corpus = kFormalFixtureRoot;

  group('the corpus is the one WaveCrux tests its receiver on', () {
    test('27 witness traces, digest $kFormalCorpusDigest', () {
      final dir = Directory(corpus);
      expect(dir.existsSync(), isTrue, reason: '$corpus is missing');
      final files =
          dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.vcd'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(files, hasLength(27));
      expect(_corpusDigest(corpus, files), kFormalCorpusDigest);
    });
  });

  group('sby rows: formal.trace_step at the step the solver reported', () {
    final expected = readJsonObject(
      p.join(corpus, 'sby/handshake_imm/handshake_imm.expected.json'),
    );
    final tasks = expected['tasks']! as Map<String, Object?>;
    Map<String, Object?> property(String task, String kind) => objectList(
      (tasks[task]! as Map<String, Object?>)['properties'],
    ).firstWhere((x) => x['kind'] == kind);

    test('prove_bug: the failing assertion at its hand-expected step, which '
        'the trace states', () {
      final want = property('prove_bug', 'ASSERT')['step']! as int;
      final trace = p.join(
        corpus,
        'sby/handshake_imm/captured/prove_bug/engine_0/trace.vcd',
      );
      final coordinate = formalStreamCoordinateFor(
        _row(_sbyMetrics(step: '$want'), waveform: trace),
      )!;
      expect(coordinate.streamId, 'formal.trace_step');
      expect(coordinate.sequenceIndex, want);
      expect(coordinate.subId, isNull);
      expect(coordinate.attributes['formal.verdict'], 'FAIL');
      expect(coordinate.attributes['formal.property_kind'], 'assert');
      expect(coordinate.attributes['formal.depth_configured'], '20');
      expect(coordinate.attributes.containsKey('formal.mode'), isFalse);
      // The step is one the trace itself counts to.
      expect(
        _smtSteps(File(trace).readAsStringSync()).keys,
        contains(coordinate.sequenceIndex),
      );
    });

    test('cover: the reached cover at its hand-expected step', () {
      final want = property('cover', 'COVER')['step']! as int;
      final trace = p.join(
        corpus,
        'sby/handshake_imm/captured/cover/engine_0/trace0.vcd',
      );
      final coordinate = formalStreamCoordinateFor(
        _row(
          _sbyMetrics(
            verdict: 'PASS',
            mode: 'cover',
            kind: 'COVER',
            status: 'reached',
            step: '$want',
            trace: 'engine_0/trace0.vcd',
          ),
          waveform: trace,
          status: TestStatus.pass,
        ),
      )!;
      expect(coordinate.sequenceIndex, want);
      expect(coordinate.attributes['formal.property_kind'], 'cover');
      expect(
        _smtSteps(File(trace).readAsStringSync()).keys,
        contains(coordinate.sequenceIndex),
      );
    });

    test('no stated step: no coordinate, never the depth reached', () {
      expect(
        formalStreamCoordinateFor(
          _row(_sbyMetrics(step: null), waveform: '/w/engine_0/trace.vcd'),
        ),
        isNull,
      );
    });

    test('a trace no fired property names: no coordinate', () {
      expect(
        formalStreamCoordinateFor(
          _row(_sbyMetrics(), waveform: '/w/engine_0/trace_induct.vcd'),
        ),
        isNull,
      );
    });

    test('a multiclock task: no coordinate (its grid was not measured)', () {
      expect(
        formalStreamCoordinateFor(
          _row(
            <String, String>{..._sbyMetrics(), 'formal.multiclock': '1'},
            waveform: '/w/engine_0/trace.vcd',
          ),
        ),
        isNull,
      );
    });

    test('a demo row says so in formal.mode', () {
      final coordinate = formalStreamCoordinateFor(
        _row(
          <String, String>{..._sbyMetrics(), 'formal.run_mode': 'demo'},
          waveform: '/w/engine_0/trace.vcd',
        ),
      )!;
      expect(coordinate.attributes['formal.mode'], 'demo');
    });

    test('a simulation row: nothing', () {
      expect(
        formalStreamCoordinateFor(_row(const {}, waveform: '/w/dump.vcd')),
        isNull,
      );
      expect(formalHandoffMetadata(_row(const {})), isEmpty);
    });

    test('metadata: the property role, and the label when the frontend kept '
        'one', () {
      expect(
        formalHandoffMetadata(
          _row(_sbyMetrics(label: 'a_wait'), waveform: '/w/engine_0/trace.vcd'),
        ),
        <String, Object?>{
          'formal.property_kind': 'assert',
          'formal.property_label': 'a_wait',
        },
      );
      expect(
        formalHandoffMetadata(
          _row(_sbyMetrics(), waveform: '/w/engine_0/trace.vcd'),
        ),
        <String, Object?>{'formal.property_kind': 'assert'},
      );
    });
  });

  group('EQY rows: one coordinate per failing partition', () {
    Map<String, String> eqy({String? zStep = '1'}) => <String, String>{
      'formal.tool': 'eqy',
      'formal.verdict': 'FAIL',
      'formal.mode': 'equiv',
      'formal.property.0.kind': 'partition',
      'formal.property.0.label': 'alu.r',
      'formal.property.0.location': 'alu.r',
      'formal.property.0.status': 'counterexample',
      'formal.property.0.trace':
          'strategies/alu.r/sby/alu.r/engine_0/trace.vcd',
      'formal.property.1.kind': 'partition',
      'formal.property.1.label': 'alu.z',
      'formal.property.1.location': 'alu.z',
      'formal.property.1.status': 'counterexample',
      'formal.property.1.trace':
          'strategies/alu.z/sby/alu.z/engine_0/trace.vcd',
      'formal.property.1.step': ?zStep,
      'formal.property.2.kind': 'partition',
      'formal.property.2.label': 'alu.y',
      'formal.property.2.location': 'alu.y',
      'formal.property.2.status': 'proved',
    };
    const work = '/w/alu_fail';
    const firstTrace = '$work/strategies/alu.r/sby/alu.r/engine_0/trace.vcd';

    test('the partition is the sub_id, at the step its summary stated', () {
      final result = _row(eqy(), waveform: firstTrace);
      final z = failingEqyPartitions(result.metrics).last;
      expect(z.name, 'alu.z');
      final coordinate = formalStreamCoordinateFor(result, partition: z)!;
      expect(coordinate.streamId, 'formal.trace_step');
      expect(coordinate.sequenceIndex, 1);
      expect(coordinate.subId, 'alu.z');
    });

    test('a partition whose summary stated no step: no coordinate', () {
      // The row's own hand-off is alu.r, whose sby summary names no step.
      expect(
        formalStreamCoordinateFor(_row(eqy(), waveform: firstTrace)),
        isNull,
      );
    });

    test("each partition's trace sits under the run's work directory", () {
      final result = _row(eqy(), waveform: firstTrace);
      final z = failingEqyPartitions(result.metrics).last;
      expect(
        eqyPartitionTracePath(result, z),
        p.normalize('$work/strategies/alu.z/sby/alu.z/engine_0/trace.vcd'),
      );
    });

    test('gold and gate scopes ride every EQY hand-off', () {
      expect(formalHandoffMetadata(_row(eqy(), waveform: firstTrace)), {
        'formal.eqy.gold_scope': 'gold',
        'formal.eqy.gate_scope': 'gate',
      });
    });

    test('only partitions with a counterexample trace are offered', () {
      final rows = FormalResultSummary.partitionsOf(eqy());
      expect(
        rows.where((r) => r.status == FormalPropertyStatus.proved),
        hasLength(1),
      );
      expect(failingEqyPartitions(eqy()).map((x) => x.name), [
        'alu.r',
        'alu.z',
      ]);
    });
  });

  group('which properties read a signal', () {
    final metrics = <String, String>{
      'formal.tool': 'sby',
      'formal.verdict': 'FAIL',
      'formal.property.0.kind': 'ASSERT',
      'formal.property.0.location': 'fifo.sv:38.1-38.9',
      'formal.property.0.status': 'proved',
      'formal.property.0.reads': 'fifo.count,fifo.rst',
    };

    test('rooted, unrooted and bit-selected names all match', () {
      expect(formalRowReads(metrics, 'fifo.count'), isTrue);
      expect(formalRowReads(metrics, 'count'), isTrue);
      expect(formalRowReads(metrics, 'fifo.count[2:0]'), isTrue);
      expect(formalRowReads(metrics, 'top.fifo.count'), isTrue);
      expect(formalRowReads(metrics, 'fifo.wdata'), isFalse);
      expect(formalRowReads(metrics, 'ount'), isFalse);
    });
  });

  group('a property reads back its identity and its pre-trace depth', () {
    test('both when recorded, neither when not', () {
      final properties = formalPropertiesOf(<String, String>{
        'formal.property.0.kind': 'ASSERT',
        'formal.property.0.location': 'fifo.sv:38',
        'formal.property.0.status': 'counterexample',
        'formal.property.0.id': 'no_overflow',
        'formal.property.0.pretrace': '2',
        'formal.property.1.kind': 'COVER',
        'formal.property.1.location': 'fifo.sv:52',
        'formal.property.1.status': 'reached',
      });
      expect(properties.first.id, 'no_overflow');
      expect(properties.first.pretraceDepth, 2);
      expect(properties.last.id, isNull);
      expect(properties.last.pretraceDepth, isNull);
    });

    test('a never-enabled assertion reads back the assumption behind it', () {
      final properties = formalPropertiesOf(<String, String>{
        'formal.property.0.kind': 'ASSERT',
        'formal.property.0.location': 'vacuity.sv:11',
        'formal.property.0.status': 'proved',
        'formal.property.0.vacuous': 'vacuity.sv:10',
        'formal.property.1.kind': 'ASSERT',
        'formal.property.1.location': 'vacuity.sv:12',
        'formal.property.1.status': 'proved',
      });
      expect(properties.first.vacuousBy, 'vacuity.sv:10');
      expect(properties.last.vacuousBy, isNull);
    });
  });
}
