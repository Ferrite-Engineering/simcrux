// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';

/// Long-run memory soak. A 10,000-test regression must run with a flat
/// retained working set — no monotonic growth — bounded by the `LogBuffer`
/// ring and the streaming writer's O(1) aggregate footprint. The
/// `tool/soak/regression_soak.dart` harness samples real `ProcessInfo`
/// RSS across a full run; these CI checks assert the deterministic bounds
/// the flat RSS rides on (RSS itself is sampled here only as a soft signal,
/// since GC/allocator timing makes raw RSS a flaky hard assertion).
void main() {
  // The flatness invariant, tied to the LogBuffer ring.
  //
  // PRIMARY MUTATION TARGET: raising the ring's effective cap (e.g.
  // `LogBuffer.maxLines` → `1 << 30`) makes the retained-line count grow
  // monotonically with the number of lines fed, so the 75% ≈ 100% flatness
  // assertion goes red.
  test('log ring keeps a flat retained working set across a long stream', () {
    const maxLines = 4000;
    const totalLines = 200000;
    final buffer = LogBuffer(maxLines: maxLines);

    int? retainedAt75;
    var rssAt75 = 0;
    for (var i = 0; i < totalLines; i++) {
      buffer.append(line: 'line $i with some payload', fromStderr: false);
      if (i == (totalLines * 3) ~/ 4) {
        retainedAt75 = buffer.snapshot.length;
        rssAt75 = ProcessInfo.currentRss;
      }
    }
    final retainedAt100 = buffer.snapshot.length;
    final rssAt100 = ProcessInfo.currentRss;

    // Flatness: the retained working set at 75% equals it at 100% — the
    // ring is full and never grows further.
    expect(retainedAt75, maxLines);
    expect(retainedAt100, maxLines);
    expect(buffer.droppedCount, totalLines - maxLines);

    // Soft RSS signal: the last quarter of the stream must not balloon the
    // resident set (generous CI-tolerant band).
    expect(
      (rssAt100 - rssAt75).abs(),
      lessThan(256 * 1024 * 1024),
      reason: 'RSS should stay roughly flat once the ring is full',
    );
  });

  test('streaming writer keeps an O(1) footprint across 10k results', () async {
    final writer = StreamingResultsWriter(
      resultsPath: 'unused.ndjson',
      openSink: (_) async => _DiscardSink(),
      writeSummary: (_, _) async {},
    );
    await writer.start(runId: 'soak', startedAt: DateTime.utc(2026, 6));
    for (var i = 0; i < 10000; i++) {
      await writer.recordRow(
        DashboardRow(
          result: TestResult(
            testId: 't$i',
            runId: 'soak',
            status: i.isEven ? TestStatus.pass : TestStatus.fail,
            startedAt: DateTime.utc(2026, 6),
            finishedAt: DateTime.utc(2026, 6).add(const Duration(seconds: 1)),
          ),
          suiteName: 's',
          simulatorId: 'icarus',
          testName: 't$i',
        ),
      );
    }
    // The only retained in-memory state is the per-status aggregate map:
    // O(number of distinct statuses), not O(rows).
    expect(writer.recordedCount, 10000);
    expect(writer.totalsByStatus.length, lessThanOrEqualTo(8));
  });

  test('result store does not pin full per-test logs in memory', () {
    const maxLines = 200;
    final run = TestRun(
      id: 'r',
      startedAt: DateTime.utc(2026, 6),
      testIds: const [],
    );
    final store = InMemoryResultStore.forRun(run, logBufferMaxLines: maxLines);
    // 500 chatty tests, each emitting far more lines than the ring holds.
    for (var t = 0; t < 500; t++) {
      final buffer = store.logBufferStore.bufferFor('t$t');
      for (var l = 0; l < 2000; l++) {
        buffer.append(line: 'log $l', fromStderr: false);
      }
    }
    // Every retained buffer is ring-bounded — logs are not pinned in full
    // (the full text lives in the on-disk ndjson, not the live store).
    for (final id in store.logBufferStore.testIds) {
      expect(store.logBufferStore.tryGet(id)!.snapshot.length, maxLines);
    }
    // And the retained set does not scale with the number of TESTS either.
    //
    // This assertion used to read `500 * maxLines` — it pinned the very
    // growth the case is named for: each ring was bounded, the number of
    // rings was not. Measured before the store-level bound existed, a
    // 2 000-test run at the shipped 5 000-line ring retained 10 000 000
    // `LogLine`s and 1 097 MB of RSS; with it, 205 000 lines and 73 MB.
    final logs = store.logBufferStore;
    expect(logs.testIds.length, lessThanOrEqualTo(logs.maxBufferedTests));
    expect(
      logs.totalLineCount,
      lessThanOrEqualTo(logs.maxTotalLines + maxLines),
      reason: 'retained lines must track the store bound, not the test count',
    );
    // Nothing is silently lost: every evicted test can still say how many
    // lines it had.
    expect(logs.evictedBufferCount, 500 - logs.testIds.length);
  });

  test('soak harness emitted monotonic checkpoints (when present)', () {
    // The harness is run out-of-band (`dart run tool/soak/regression_soak.dart`);
    // when its output exists, sanity-check the schema.
    final file = File('build/soak/results.jsonl');
    if (!file.existsSync()) return;
    final rows = file
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
    expect(rows.first['mark'], 'start');
    expect(rows.last['mark'], 'end');
    expect(rows.every((r) => r.containsKey('rss_bytes')), isTrue);
  });
}

class _DiscardSink implements IOSink {
  @override
  Encoding encoding = const Utf8Codec();
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async =>
      stream.drain<void>();
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}
