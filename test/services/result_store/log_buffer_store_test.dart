// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

void main() {
  group('LogBuffer', () {
    test('append accumulates lines in insertion order', () {
      final buffer = LogBuffer()
        ..append(line: 'first', fromStderr: false)
        ..append(line: 'second', fromStderr: true);
      expect(buffer.snapshot.map((e) => e.line), ['first', 'second']);
      expect(buffer.snapshot[1].fromStderr, isTrue);
    });

    test('append truncates head when maxLines is exceeded', () {
      final buffer = LogBuffer(maxLines: 3);
      for (var i = 0; i < 5; i++) {
        buffer.append(line: 'line $i', fromStderr: false);
      }
      expect(buffer.snapshot.length, 3);
      expect(
        buffer.snapshot.map((e) => e.line),
        ['line 2', 'line 3', 'line 4'],
      );
      expect(buffer.droppedCount, 2);
    });

    test('at-capacity appends are O(1), not a full-list shift per line', () {
      // CPU-shaped companion to the memory soak: the soak proves the
      // retained set stays flat, this proves the *cost per append* stays
      // flat once the ring is full. The regression this guards
      // (`removeRange(0, overflow)` on a plain List) shifts every
      // retained pointer on every append — 10k lines × 200k appends ≈
      // 2e9 moves, which blows far past the bound; the ListQueue ring
      // finishes in milliseconds.
      final buffer = LogBuffer(maxLines: 10000);
      for (var i = 0; i < 10000; i++) {
        buffer.append(line: 'fill $i', fromStderr: false);
      }
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 200000; i++) {
        buffer.append(line: 'line $i', fromStderr: false);
      }
      stopwatch.stop();
      expect(buffer.lineCount, 10000);
      expect(buffer.droppedCount, 200000);
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(2000),
        reason:
            '200k at-capacity appends must be linear-time overall; '
            'a per-append head shift makes this take tens of seconds',
      );
    });

    test('snapshot is reused while the buffer is unchanged', () {
      final buffer = LogBuffer()..append(line: 'a', fromStderr: false);
      final first = buffer.snapshot;
      expect(identical(first, buffer.snapshot), isTrue);
      buffer.append(line: 'b', fromStderr: false);
      final second = buffer.snapshot;
      expect(identical(first, second), isFalse);
      expect(second.map((e) => e.line), ['a', 'b']);
      // The pre-append snapshot is immutable history, not a live view.
      expect(first.map((e) => e.line), ['a']);
    });

    test('lineCount tracks the buffered length without copying', () {
      final buffer = LogBuffer(maxLines: 3);
      expect(buffer.lineCount, 0);
      for (var i = 0; i < 5; i++) {
        buffer.append(line: 'line $i', fromStderr: false);
      }
      expect(buffer.lineCount, 3);
    });

    test('stream broadcasts each appended line', () async {
      final buffer = LogBuffer();
      final events = <String>[];
      final sub = buffer.stream.listen((e) => events.add(e.line));
      buffer
        ..append(line: 'a', fromStderr: false)
        ..append(line: 'b', fromStderr: false);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['a', 'b']);
      await sub.cancel();
      await buffer.close();
    });
  });

  group('LogBufferStore', () {
    test('bufferFor creates a new LogBuffer per testId, idempotently', () {
      final store = LogBufferStore();
      final a = store.bufferFor('alpha');
      final b = store.bufferFor('beta');
      final a2 = store.bufferFor('alpha');
      expect(identical(a, a2), isTrue);
      expect(a, isNot(same(b)));
    });

    test('tryGet returns null for unknown ids', () {
      final store = LogBufferStore();
      expect(store.tryGet('nope'), isNull);
    });

    test('totalLineCount sums every per-test buffer', () {
      final store = LogBufferStore();
      store.bufferFor('a')
        ..append(line: 'x', fromStderr: false)
        ..append(line: 'y', fromStderr: false);
      store.bufferFor('b').append(line: 'z', fromStderr: false);
      expect(store.totalLineCount, 3);
    });

    test('the number of buffers is bounded, not just each buffer', () {
      // PRIMARY MUTATION TARGET: raising either store-level bound (e.g.
      // `maxBufferedTests` → 1 << 30) lets the retained set grow with the
      // number of tests again — 2 000 chatty tests retained 10 000 000
      // lines and 1.1 GB of RSS before these bounds existed.
      final store = LogBufferStore(
        maxLinesPerTest: 100,
        maxBufferedTests: 8,
        maxTotalLines: 500,
      );
      for (var t = 0; t < 200; t++) {
        final buffer = store.bufferFor('t$t');
        for (var l = 0; l < 300; l++) {
          buffer.append(line: 'log $l', fromStderr: false);
        }
      }
      expect(store.testIds.length, lessThanOrEqualTo(8));
      // The live set is the bound plus at most the buffer still filling.
      expect(store.totalLineCount, lessThanOrEqualTo(500 + 100));
      expect(store.evictedBufferCount, greaterThan(180));
    });

    test('eviction is least-recently-used, and access promotes', () {
      final store = LogBufferStore(maxBufferedTests: 3, maxLinesPerTest: 10);
      store.bufferFor('a').append(line: 'x', fromStderr: false);
      store.bufferFor('b').append(line: 'x', fromStderr: false);
      store.bufferFor('c').append(line: 'x', fromStderr: false);
      // Touching 'a' through the accessor the log providers use makes 'b'
      // the oldest. (`tryGet` is a plain lookup and does not promote.)
      expect(store.bufferFor('a'), isNotNull);
      store.bufferFor('d').append(line: 'x', fromStderr: false);
      expect(store.testIds, containsAll(<String>['a', 'c', 'd']));
      expect(store.tryGet('b'), isNull);
      expect(store.evictedBufferCount, 1);
    });

    test('a buffer someone is streaming is never evicted', () async {
      final store = LogBufferStore(maxBufferedTests: 2, maxLinesPerTest: 10);
      final watched = store.bufferFor('watched')
        ..append(line: 'x', fromStderr: false);
      final sub = watched.stream.listen((_) {});
      addTearDown(sub.cancel);
      for (var t = 0; t < 20; t++) {
        store.bufferFor('t$t').append(line: 'x', fromStderr: false);
      }
      // The inspector pane's subscription survives the whole run.
      expect(store.tryGet('watched'), same(watched));
      watched.append(line: 'still live', fromStderr: false);
      expect(watched.snapshot.last.line, 'still live');
    });

    test('an evicted test reports its lost lines as elided, not as empty', () {
      final store = LogBufferStore(maxBufferedTests: 2, maxLinesPerTest: 10);
      final first = store.bufferFor('early');
      for (var i = 0; i < 4; i++) {
        first.append(line: 'log $i', fromStderr: false);
      }
      for (var t = 0; t < 10; t++) {
        store.bufferFor('t$t').append(line: 'x', fromStderr: false);
      }
      expect(store.evictedLinesFor('early'), 4);
      // Opening the test later gets a fresh buffer that still tells the
      // truth about what was discarded.
      final reopened = store.bufferFor('early');
      expect(reopened.snapshot, isEmpty);
      expect(reopened.droppedCount, 4);
    });

    group('failures outrank passes', () {
      test('an early failure survives a long tail of passes', () {
        // The headline case: the first red test's log is what the user
        // comes back for twenty minutes later, and pure LRU had discarded it
        // to keep the logs of passes nobody will open.
        final store = LogBufferStore(maxBufferedTests: 3, maxLinesPerTest: 10);
        final early = store.bufferFor('early_failure')
          ..append(line: 'assertion failed', fromStderr: true);
        store.markFailed('early_failure');
        for (var t = 0; t < 50; t++) {
          store.bufferFor('pass$t').append(line: 'ok', fromStderr: false);
        }
        expect(store.tryGet('early_failure'), same(early));
        expect(early.snapshot.single.line, 'assertion failed');
        expect(store.testIds.length, lessThanOrEqualTo(3));
      });

      test('a mark made after the buffer exists still protects it', () {
        // The result lands after the log streamed, which is the real order:
        // TestLog lines first, TestFinished last.
        final store = LogBufferStore(maxBufferedTests: 2, maxLinesPerTest: 10);
        store.bufferFor('a').append(line: 'x', fromStderr: false);
        store.bufferFor('b').append(line: 'x', fromStderr: false);
        store.markFailed('a');
        store.bufferFor('c').append(line: 'x', fromStderr: false);
        expect(store.testIds, containsAll(<String>['a', 'c']));
        expect(store.tryGet('b'), isNull);
      });

      test('a suite that is mostly failures is still bounded, oldest '
          'failure first', () {
        // A broken build fails everything. "Never evict a failure" would
        // reintroduce the unbounded growth the bounds exist for.
        final store = LogBufferStore(maxBufferedTests: 4, maxLinesPerTest: 10);
        for (var t = 0; t < 40; t++) {
          store.bufferFor('f$t').append(line: 'boom', fromStderr: true);
          store.markFailed('f$t');
        }
        expect(store.testIds.length, lessThanOrEqualTo(4));
        expect(store.testIds, containsAll(<String>['f37', 'f38', 'f39']));
        expect(store.tryGet('f0'), isNull);
        expect(store.evictedBufferCount, 36);
      });

      test('the line bound binds on failures too', () {
        final store = LogBufferStore(
          maxBufferedTests: 100,
          maxLinesPerTest: 10,
          maxTotalLines: 30,
        );
        for (var t = 0; t < 20; t++) {
          final b = store.bufferFor('f$t');
          for (var l = 0; l < 10; l++) {
            b.append(line: 'l$l', fromStderr: true);
          }
          store.markFailed('f$t');
        }
        expect(store.totalLineCount, lessThanOrEqualTo(30 + 10));
      });

      test('an evicted failure still reports its lost lines', () {
        final store = LogBufferStore(maxBufferedTests: 1, maxLinesPerTest: 10);
        store.bufferFor('f0').append(line: 'x', fromStderr: true);
        store.markFailed('f0');
        store.bufferFor('f1').append(line: 'x', fromStderr: true);
        store.markFailed('f1');
        store.bufferFor('f2').append(line: 'x', fromStderr: true);
        expect(store.evictedLinesFor('f0'), 1);
        expect(store.isMarkedFailed('f0'), isTrue);
      });

      test(
        'a streamed failure is never evicted, even by another failure',
        () async {
          final store = LogBufferStore(
            maxBufferedTests: 1,
            maxLinesPerTest: 10,
          );
          final watched = store.bufferFor('watched')
            ..append(line: 'x', fromStderr: true);
          store.markFailed('watched');
          final sub = watched.stream.listen((_) {});
          addTearDown(sub.cancel);
          for (var t = 0; t < 5; t++) {
            store.bufferFor('f$t').append(line: 'x', fromStderr: true);
            store.markFailed('f$t');
          }
          expect(store.tryGet('watched'), same(watched));
        },
      );
    });

    test('closeAll closes every per-test buffer', () async {
      final store = LogBufferStore();
      store.bufferFor('a').append(line: 'x', fromStderr: false);
      await store.closeAll();
      // Re-closing the same buffer must not throw.
      await store.bufferFor('a').close();
    });
  });
}
