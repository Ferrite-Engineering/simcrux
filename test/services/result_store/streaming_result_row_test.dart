// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The typed projection of an archive's `result` line.
//
// This is now the only place in the product that knows the wire key names, so
// it is the only place that can get them wrong. The assertions are therefore
// about the KEYS as much as the values: a row written by
// `StreamingResultsWriter` must come back out with every field on it, and a
// row from an older build must come back with the missing fields reading as
// unknown rather than as a default that looks like data.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/services/result_store/streaming_result_row.dart';

Map<String, Object?> row(String json) =>
    jsonDecode(json) as Map<String, Object?>;

void main() {
  group('a fully-populated row', () {
    test('carries every field the writer emits', () {
      final parsed = StreamingResultRow.parse(
        row('''
{"type":"result","id":"unit/alu","name":"ALU","suite":"unit",
 "simulator":"verilator","status":"fail","runtime_ms":1234,
 "started_at":"2026-03-01T12:00:00.000Z","finished_at":"2026-03-01T12:00:01.234Z",
 "exit_code":3,"waveform_path":"/w/alu.fst","stdout_path":"/l/out.log",
 "stderr_path":"/l/err.log","failure_message":"Expected 0x42, got 0x41",
 "kill_signal":"SIGKILL","did_execute":true,"metrics":{"cycles":"90210"}}'''),
      )!;

      expect(parsed.testId, 'unit/alu');
      expect(parsed.testName, 'ALU');
      expect(parsed.suiteName, 'unit');
      expect(parsed.simulatorId, 'verilator');
      expect(parsed.status, TestStatus.fail);
      expect(parsed.runtime, const Duration(milliseconds: 1234));
      expect(parsed.startedAt, DateTime.utc(2026, 3, 1, 12));
      expect(parsed.startedAt.isUtc, isTrue);
      expect(parsed.finishedAt, DateTime.utc(2026, 3, 1, 12, 0, 1, 234));
      expect(parsed.exitCode, 3);
      expect(parsed.waveformPath, '/w/alu.fst');
      expect(parsed.stdoutPath, '/l/out.log');
      expect(parsed.stderrPath, '/l/err.log');
      expect(parsed.failureMessage, 'Expected 0x42, got 0x41');
      expect(parsed.killSignal, KillSignal.sigkill);
      expect(parsed.didExecute, isTrue);
      expect(parsed.metrics, {'cycles': '90210'});
    });
  });

  group('a row that cannot describe a test is rejected', () {
    test('no id', () {
      expect(
        StreamingResultRow.parse(
          row('{"status":"pass","started_at":"2026-03-01T12:00:00.000Z"}'),
        ),
        isNull,
      );
    });

    test('empty id', () {
      expect(
        StreamingResultRow.parse(
          row('{"id":"","started_at":"2026-03-01T12:00:00.000Z"}'),
        ),
        isNull,
      );
    });

    test('no parseable start time', () {
      expect(StreamingResultRow.parse(row('{"id":"t"}')), isNull);
      expect(
        StreamingResultRow.parse(row('{"id":"t","started_at":"not a date"}')),
        isNull,
      );
    });
  });

  group('an older archive reads as unknown, not as data', () {
    final sparse = StreamingResultRow.parse(
      row('{"id":"t","status":"pass","started_at":"2026-03-01T12:00:00.000Z"}'),
    )!;

    test('absent optional fields are null rather than empty strings', () {
      expect(sparse.testName, isNull);
      expect(sparse.suiteName, isNull);
      expect(sparse.simulatorId, isNull);
      expect(sparse.finishedAt, isNull);
      expect(sparse.exitCode, isNull);
      expect(sparse.waveformPath, isNull);
      expect(sparse.failureMessage, isNull);
      expect(sparse.killSignal, isNull);
      expect(sparse.metrics, isEmpty);
    });

    test('an empty string is absent too, not a value', () {
      final blank = StreamingResultRow.parse(
        row(
          '{"id":"t","suite":"","simulator":"","waveform_path":"",'
          '"started_at":"2026-03-01T12:00:00.000Z"}',
        ),
      )!;
      expect(blank.suiteName, isNull);
      expect(blank.simulatorId, isNull);
      expect(
        blank.waveformPath,
        isNull,
        reason:
            'an empty path would be written into a pooled row as a location '
            'that resolves to nothing',
      );
    });

    test('a missing did_execute means the run executed', () {
      expect(
        sparse.didExecute,
        isTrue,
        reason:
            'archives from before the flag shipped recorded only tests that '
            'ran, so true is what their rows actually meant — defaulting to '
            'false would silently drop every row in them',
      );
      expect(
        StreamingResultRow.parse(
          row(
            '{"id":"t","did_execute":false,'
            '"started_at":"2026-03-01T12:00:00.000Z"}',
          ),
        )!.didExecute,
        isFalse,
      );
    });

    test('an unknown status reads as unknown rather than throwing', () {
      expect(
        StreamingResultRow.parse(
          row(
            '{"id":"t","status":"from-a-newer-build",'
            '"started_at":"2026-03-01T12:00:00.000Z"}',
          ),
        )!.status,
        TestStatus.unknown,
      );
    });

    test('a missing runtime is zero, which is what the store recorded', () {
      expect(sparse.runtime, Duration.zero);
    });
  });

  test('metrics survive non-string values by stringifying them', () {
    final parsed = StreamingResultRow.parse(
      row(
        '{"id":"t","started_at":"2026-03-01T12:00:00.000Z",'
        '"metrics":{"cycles":90210,"ok":true}}',
      ),
    )!;
    expect(parsed.metrics, {'cycles': '90210', 'ok': 'true'});
  });
}
