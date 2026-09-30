// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/config/project_output_path.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';

DashboardRow _row(
  String id,
  TestStatus status, {
  String suite = 'axi',
  String simulator = 'icarus',
  int ms = 1500,
  Map<String, String>? metrics,
}) {
  final started = DateTime.utc(2026, 5, 23, 12);
  return DashboardRow(
    result: TestResult(
      testId: id,
      runId: 'run-1',
      status: status,
      startedAt: started,
      finishedAt: started.add(Duration(milliseconds: ms)),
      exitCode: status == TestStatus.pass ? 0 : 1,
      metrics: metrics,
    ),
    suiteName: suite,
    simulatorId: simulator,
    testName: id.split('/').last,
  );
}

class _InMemorySink implements IOSink {
  final StringBuffer buffer = StringBuffer();
  bool closed = false;

  @override
  Encoding encoding = const Utf8Codec();

  @override
  void add(List<int> data) => buffer.write(String.fromCharCodes(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.forEach(add);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) =>
      buffer.write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
}

void main() {
  group('StreamingResultsWriter', () {
    test(
      'emits meta + result + summary lines and writes summary file',
      () async {
        final sink = _InMemorySink();
        var summaryCapture = '';
        final writer = StreamingResultsWriter(
          resultsPath: '/tmp/results.ndjson',
          summaryPath: '/tmp/results.summary.json',
          openSink: (_) async => sink,
          writeSummary: (path, contents) async {
            summaryCapture = contents;
          },
        );
        await writer.start(
          runId: 'run-1',
          startedAt: DateTime.utc(2026),
          configPath: '/proj/simcrux.yaml',
        );
        await writer.recordRow(_row('axi/burst', TestStatus.pass));
        await writer.recordRow(_row('axi/wrap', TestStatus.fail));
        await writer.recordRunCompletion(finishedAt: DateTime.utc(2026, 1, 2));

        final lines = sink.buffer.toString().split('\n')
          ..removeWhere((l) => l.isEmpty);
        expect(lines, hasLength(4));
        expect(lines.first, contains('"type":"meta"'));
        expect(lines.first, contains('"version":1'));
        expect(lines[1], contains('"type":"result"'));
        expect(lines[1], contains('"id":"axi/burst"'));
        expect(lines[1], contains('"status":"pass"'));
        expect(lines.last, contains('"type":"summary"'));
        expect(lines.last, contains('"pass":1'));
        expect(lines.last, contains('"fail":1'));
        expect(summaryCapture, contains('"total": 2'));
        expect(writer.isClosed, isTrue);
        expect(writer.recordedCount, 2);
        expect(writer.totalsByStatus[TestStatus.pass], 1);
        expect(writer.totalsByStatus[TestStatus.fail], 1);
      },
    );

    test('recordRow before start() throws', () async {
      final writer = StreamingResultsWriter(
        resultsPath: '/tmp/x.ndjson',
        openSink: (_) async => _InMemorySink(),
        writeSummary: (_, _) async {},
      );
      expect(
        () => writer.recordRow(_row('a', TestStatus.pass)),
        throwsStateError,
      );
    });

    test('recordRow after recordRunCompletion throws', () async {
      final writer = StreamingResultsWriter(
        resultsPath: '/tmp/x.ndjson',
        openSink: (_) async => _InMemorySink(),
        writeSummary: (_, _) async {},
      );
      await writer.start(runId: 'r', startedAt: DateTime.now());
      await writer.recordRunCompletion(finishedAt: DateTime.now());
      expect(
        () => writer.recordRow(_row('a', TestStatus.pass)),
        throwsStateError,
      );
    });

    test('summary file derived from results filename when not given', () async {
      final writer = StreamingResultsWriter(
        resultsPath: '/tmp/foo.ndjson',
        openSink: (_) async => _InMemorySink(),
        writeSummary: (_, _) async {},
      );
      expect(writer.summaryPath, '/tmp/foo.summary.json');
    });
  });

  group('StreamingResultsReader', () {
    test('round-trips a complete document', () {
      const reader = StreamingResultsReader();
      final lines = [
        '{"type":"meta","version":1,"run_id":"run-1","started_at":"2026-01-01T00:00:00.000Z","config_path":"/p.yaml"}',
        '{"type":"result","id":"a","name":"a","suite":"s","simulator":"icarus","status":"pass","runtime_ms":10,"started_at":"2026-01-01T00:00:00.000Z","finished_at":"2026-01-01T00:00:00.010Z","exit_code":0,"waveform_path":null,"stdout_path":null,"stderr_path":null,"failure_message":null}',
        '{"type":"summary","version":1,"finished_at":"2026-01-01T00:00:00.020Z","total":1,"totals":{"pass":1}}',
      ];
      final doc = reader.decode(lines);
      expect(doc.isComplete, isTrue);
      expect(doc.meta?.runId, 'run-1');
      expect(doc.meta?.configPath, '/p.yaml');
      expect(doc.rows, hasLength(1));
      expect(doc.summary?.total, 1);
      expect(doc.summary?.totals[TestStatus.pass], 1);
    });

    test('tolerates corrupt and unknown lines', () {
      const reader = StreamingResultsReader();
      final lines = [
        '{"type":"meta","run_id":"r1","started_at":"2026-01-01T00:00:00Z"}',
        'not json',
        '{"type":"future","blah":42}',
        '{"type":"result","id":"a","status":"pass"}',
        '',
      ];
      final doc = reader.decode(lines);
      expect(doc.meta?.runId, 'r1');
      expect(doc.rows, hasLength(1));
      expect(doc.summary, isNull);
      expect(doc.isComplete, isFalse);
    });
  });

  group('StreamingResultsHydrator', () {
    test('produces a TestRun and DashboardRows', () {
      const reader = StreamingResultsReader();
      const hydrator = StreamingResultsHydrator();
      final lines = [
        '{"type":"meta","version":1,"run_id":"run-1","started_at":"2026-01-01T00:00:00.000Z"}',
        '{"type":"result","id":"axi/burst","name":"burst","suite":"axi","simulator":"icarus","status":"pass","runtime_ms":10,"started_at":"2026-01-01T00:00:00.000Z","finished_at":"2026-01-01T00:00:00.010Z","exit_code":0,"metrics":{"cycles":"42"}}',
        '{"type":"summary","finished_at":"2026-01-01T00:00:00.020Z","total":1,"totals":{"pass":1}}',
      ];
      final doc = reader.decode(lines);
      final hydrated = hydrator.hydrate(doc);
      expect(hydrated.run.id, 'run-1');
      expect(hydrated.run.results, hasLength(1));
      expect(hydrated.run.results.single.status, TestStatus.pass);
      expect(hydrated.run.results.single.metrics, {'cycles': '42'});
      expect(hydrated.rows.single.suiteName, 'axi');
      expect(hydrated.rows.single.testName, 'burst');
    });
  });

  group('bounded memory', () {
    test('100K rows complete without retaining row JSON in memory', () async {
      final sink = _InMemorySink();
      final writer = StreamingResultsWriter(
        resultsPath: '/tmp/big.ndjson',
        openSink: (_) async => sink,
        writeSummary: (_, _) async {},
      );
      await writer.start(runId: 'big', startedAt: DateTime.utc(2026));
      const totalRows = 100000;
      for (var i = 0; i < totalRows; i++) {
        final status = i.isEven ? TestStatus.pass : TestStatus.fail;
        await writer.recordRow(_row('t/$i', status));
      }
      await writer.recordRunCompletion(finishedAt: DateTime.utc(2026, 1, 2));
      // The writer's in-memory state is the counts map only.
      expect(writer.totalsByStatus[TestStatus.pass], 50000);
      expect(writer.totalsByStatus[TestStatus.fail], 50000);
      expect(writer.recordedCount, totalRows);
      // Sanity: every row produced exactly one line.
      final lineCount = sink.buffer
          .toString()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .length;
      // meta + N rows + summary.
      expect(lineCount, totalRows + 2);
    });
  });

  group('project containment', () {
    // The writer's half of the output-path rule; the loader's half is in
    // `config_loader_output_paths_test.dart`. These run on the real disk,
    // because what they prove is that nothing outside the project was
    // created or truncated.
    late Directory tmp;
    late String project;
    late File victim;

    setUp(() {
      tmp = Directory(
        Directory.systemTemp
            .createTempSync('simcrux_writer_contain_')
            .resolveSymbolicLinksSync(),
      );
      project = p.join(tmp.path, 'project');
      Directory(project).createSync();
      victim = File(p.join(tmp.path, 'victim.txt'))
        ..writeAsStringSync('keep me');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> runOnce(StreamingResultsWriter writer) async {
      await writer.start(runId: 'r', startedAt: DateTime.utc(2026));
      await writer.recordRow(_row('axi/burst', TestStatus.pass));
      await writer.recordRunCompletion(finishedAt: DateTime.utc(2026, 1, 2));
    }

    test('a results path outside is refused before anything is opened', () {
      final writer = StreamingResultsWriter(
        resultsPath: victim.path,
        summaryPath: p.join(project, 'results.summary.json'),
        containWithin: project,
      );
      expect(
        () => writer.start(runId: 'r', startedAt: DateTime.utc(2026)),
        throwsA(isA<ProjectOutputPathException>()),
      );
      expect(victim.readAsStringSync(), 'keep me');
    });

    test('a summary path outside is refused at start, before the results '
        'file is created', () {
      final results = p.join(project, 'results.ndjson');
      final writer = StreamingResultsWriter(
        resultsPath: results,
        summaryPath: victim.path,
        containWithin: project,
      );
      expect(
        () => writer.start(runId: 'r', startedAt: DateTime.utc(2026)),
        throwsA(isA<ProjectOutputPathException>()),
      );
      expect(File(results).existsSync(), isFalse);
      expect(victim.readAsStringSync(), 'keep me');
    });

    test(
      'a file link to outside is refused, so its target is not truncated',
      () {
        final results = p.join(project, 'results.ndjson');
        Link(results).createSync(victim.path);
        final writer = StreamingResultsWriter(
          resultsPath: results,
          containWithin: project,
        );
        expect(
          () => writer.start(runId: 'r', startedAt: DateTime.utc(2026)),
          throwsA(isA<ProjectOutputPathException>()),
        );
        expect(victim.readAsStringSync(), 'keep me');
      },
      skip: Platform.isWindows ? 'creating links needs a privilege' : false,
    );

    test(
      'a link that appears during the run is refused before the summary is '
      'written',
      () async {
        final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
        final writer = StreamingResultsWriter(
          resultsPath: p.join(project, 'results.ndjson'),
          summaryPath: p.join(project, 'build', 'results.summary.json'),
          containWithin: project,
        );
        await writer.start(runId: 'r', startedAt: DateTime.utc(2026));
        Link(p.join(project, 'build')).createSync(outside.path);
        await expectLater(
          writer.recordRunCompletion(finishedAt: DateTime.utc(2026, 1, 2)),
          throwsA(isA<ProjectOutputPathException>()),
        );
        expect(outside.listSync(), isEmpty);
      },
      skip: Platform.isWindows ? 'creating links needs a privilege' : false,
    );

    test('inside the project the run is written as before', () async {
      final writer = StreamingResultsWriter(
        resultsPath: p.join(project, 'build', 'results.ndjson'),
        summaryPath: p.join(project, 'build', 'results.summary.json'),
        containWithin: project,
      );
      await runOnce(writer);
      expect(
        File(p.join(project, 'build', 'results.ndjson')).readAsLinesSync(),
        hasLength(3),
      );
      expect(
        File(p.join(project, 'build', 'results.summary.json')).existsSync(),
        isTrue,
      );
    });

    test('without containWithin the writer writes where it is told', () async {
      final elsewhere = p.join(tmp.path, 'artifacts', 'results.ndjson');
      await runOnce(StreamingResultsWriter(resultsPath: elsewhere));
      expect(File(elsewhere).existsSync(), isTrue);
    });
  });
}
