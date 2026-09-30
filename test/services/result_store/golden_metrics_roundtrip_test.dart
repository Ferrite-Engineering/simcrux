// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';

// Regression guard for a persistence decision: the mismatch offset rides
// `TestResult.metrics`, NOT a new typed field on `TestResult`.
//
// The NDJSON layer tolerates unknown keys at *line* level, which makes a
// new typed field look like it works — it survives `_encodeRow` and
// `decode`. It dies at `hydrate`, which projects a fixed key list; four
// existing fields already leak that way. `metrics` is the one channel
// that survives all three stages with zero edits, so this test walks the
// whole path — writer → reader → hydrator — and asserts the `golden.*`
// keys arrive intact and unabridged.
//
// MUTATION: drop `metrics` from `_encodeRow` or from `hydrate`'s
// TestResult construction and this file fails, while an in-memory-only
// test of the same data would still pass.
class _CaptureSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding encoding = const Utf8Codec();

  @override
  void add(List<int> data) => buffer.write(String.fromCharCodes(data));

  @override
  void write(Object? obj) => buffer.write(obj);

  @override
  void writeln([Object? obj = '']) => buffer.writeln(obj);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<void> flush() async {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
}

void main() {
  test('golden.* metrics survive encode → decode → hydrate', () async {
    // The metrics a driver would emit for a mid-file divergence.
    final comparison = GoldenComparator.compare(
      dut: 'deadbeef\n0000000f\naaaaaaaa\n',
      reference: 'deadbeef\n0000000f\n12345678\ncafebabe\n',
    );
    final metrics = comparison.toMetrics();
    expect(metrics, hasLength(5), reason: 'all five keys are in play');

    final sink = _CaptureSink();
    final writer = StreamingResultsWriter(
      resultsPath: '/tmp/golden.ndjson',
      openSink: (_) async => sink,
      writeSummary: (_, _) async {},
    );
    final started = DateTime.utc(2026, 8, 1, 9);
    await writer.start(runId: 'run-1', startedAt: started);
    await writer.recordRow(
      DashboardRow(
        result: TestResult(
          testId: 'arch/rv32i-add',
          runId: 'run-1',
          status: TestStatus.fail,
          startedAt: started,
          finishedAt: started.add(const Duration(milliseconds: 120)),
          exitCode: 0,
          metrics: metrics,
        ),
        suiteName: 'arch',
        simulatorId: 'riscv_arch',
        testName: 'rv32i-add',
      ),
    );
    await writer.recordRunCompletion(
      finishedAt: started.add(const Duration(seconds: 1)),
    );

    const reader = StreamingResultsReader();
    const hydrator = StreamingResultsHydrator();
    final doc = reader.decode(
      const LineSplitter().convert(sink.buffer.toString()),
    );
    final hydrated = hydrator.hydrate(doc);

    final result = hydrated.run.results.single;
    expect(result.metrics, metrics);
    expect(result.metrics['golden.mismatch_offset'], '2');
    expect(result.metrics['golden.dut_value'], 'aaaaaaaa');
    expect(result.metrics['golden.ref_value'], '12345678');
    expect(result.metrics['golden.dut_words'], '3');
    expect(result.metrics['golden.ref_words'], '4');
    // Every reserved key that was emitted came back.
    for (final key in metrics.keys) {
      expect(GoldenComparator.kMetricKeys, contains(key));
      expect(result.metrics.containsKey(key), isTrue, reason: key);
    }
    // The status rode along too — the offset is useless without it.
    expect(result.status, TestStatus.fail);
  });

  test('a length-divergence metric set round-trips with the key omitted', () {
    // The absent side must stay absent rather than round-tripping as an
    // empty string, which a consumer would render as a real value.
    final metrics = GoldenComparator.compare(
      dut: 'aa\n',
      reference: 'aa\nbb\n',
    ).toMetrics();
    const reader = StreamingResultsReader();
    const hydrator = StreamingResultsHydrator();
    final started = DateTime.utc(2026, 8, 1, 9).toIso8601String();
    final doc = reader.decode([
      '{"type":"meta","version":1,"run_id":"r","started_at":"$started"}',
      jsonEncode({
        'type': 'result',
        'id': 'a',
        'status': 'fail',
        'started_at': started,
        'finished_at': started,
        'metrics': metrics,
      }),
    ]);
    final result = hydrator.hydrate(doc).run.results.single;
    expect(result.metrics.containsKey('golden.dut_value'), isFalse);
    expect(result.metrics['golden.ref_value'], 'bb');
    expect(result.metrics['golden.dut_words'], '1');
    expect(result.metrics['golden.ref_words'], '2');
  });
}
