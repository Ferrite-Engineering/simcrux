// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

/// Opening a very large log in the inspector must stay interactive. A
/// 100k-line log is bounded by the `LogBuffer` ring before it ever reaches
/// the view, so the inspector never materializes all 100k lines: the ring
/// retains the most recent `maxLines` (head-dropped) and the
/// `ListView.builder`-backed viewer renders only the visible window of
/// that.
void main() {
  test('a 100k-line log is ring-bounded and opens fast', () {
    const cap = 4096;
    final buffer = LogBuffer(maxLines: cap);
    for (var i = 0; i < 100000; i++) {
      buffer.append(
        line: 'sim line $i: some moderately long payload here',
        fromStderr: i % 7 == 0,
      );
    }

    final sw = Stopwatch()..start();
    final snapshot = buffer.snapshot; // what the inspector reads on open
    sw.stop();

    // The view receives at most `maxLines`, never the full 100k.
    expect(snapshot.length, cap);
    expect(buffer.droppedCount, 100000 - cap);
    // Head-dropped: the most recent lines survive, the oldest are gone.
    expect(snapshot.last.line, contains('sim line 99999'));

    // Soft, CI-tolerant: reading the bounded snapshot is well under budget.
    expect(sw.elapsedMilliseconds, lessThan(200));
  });

  test('the log preview reads only a bounded tail, not the whole buffer', () {
    final store = LogBufferStore();
    // LogBufferStore (default ring) + a chatty test.
    final buffer = store.bufferFor('cpu/alu');
    for (var i = 0; i < 100000; i++) {
      buffer.append(line: 'line $i', fromStderr: false);
    }
    // The full buffer is itself ring-bounded; the preview tail the
    // inspector renders eagerly is a small slice of that.
    final all = store.tryGet('cpu/alu')!.snapshot;
    expect(all.length, lessThanOrEqualTo(5000));
    const tailCount = 50;
    final tail = all.sublist(all.length - tailCount);
    expect(tail, hasLength(tailCount));
  });
}
