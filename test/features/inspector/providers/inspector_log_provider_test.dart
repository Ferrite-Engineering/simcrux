// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// The log providers coalesce invalidation onto a one-shot
/// [kLogInvalidationCoalesceWindow] timer, so every case that asserts on a
/// *post-window* re-evaluation has to get past that timer.
///
/// **Those cases run under [fakeAsync].** They used to sleep
/// `window + 40 ms` on the wall clock and then assert — the same shape that
/// made `trend_tick_coalescing_test.dart` flaky, and unfixable by polling for
/// the same reason (checking a condition faster than a real `Timer` does not
/// make the timer fire). Advancing a fake clock by exactly one window turns
/// "the window has closed" from a guess into a fact, and lets the burst case
/// assert that the window is still *open* one millisecond early — something a
/// wall-clock test cannot check at all.
void main() {
  late InMemoryResultStore store;

  setUp(() {
    store = InMemoryResultStore.forRun(
      TestRun(
        id: 'run-1',
        startedAt: DateTime.utc(2026),
        testIds: const ['smoke/t1'],
      ),
    );
  });

  /// A container forcing the provider to materialize with our hand-built
  /// store so we can drive log-buffer appends from the test.
  ///
  /// Built inside each test body rather than in `setUp` so that containers
  /// used by a [fakeAsync] case are created in the fake zone, and every timer
  /// and microtask Riverpod schedules for them is under that clock's control.
  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      resultStoreProvider.overrideWith(() => _StubResultStoreNotifier(store)),
    ],
  );

  group('fullInspectorLogProvider', () {
    test('emits the empty list on initial subscribe', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      expect(container.read(fullInspectorLogProvider('smoke/t1')), isEmpty);
    });

    test(
      're-evaluates when a new line is appended to the underlying buffer',
      () {
        fakeAsync((async) {
          final container = makeContainer();
          // Prime the provider so the subscription on buffer.stream is
          // active before we append.
          final emitted = <int>[];
          final sub = container.listen<List<LogLine>>(
            fullInspectorLogProvider('smoke/t1'),
            (_, next) => emitted.add(next.length),
            fireImmediately: true,
          );

          final buffer = store.logBufferStore.bufferFor('smoke/t1')
            ..append(line: 'hello world', fromStderr: false);
          async.elapseCoalesceWindow();
          buffer.append(line: 'TEST PASSED', fromStderr: false);
          async.elapseCoalesceWindow();

          // Initial emission (length 0), then at least one emission of
          // length 1 and one of length 2 — proves the provider saw both
          // appends.
          expect(emitted, contains(0));
          expect(emitted, contains(1));
          expect(emitted, contains(2));

          sub.close();
          container.dispose();
        });
      },
    );

    test('a burst of appends coalesces into a single re-evaluation', () {
      fakeAsync((async) {
        final container = makeContainer();
        final emitted = <int>[];
        final sub = container.listen<List<LogLine>>(
          fullInspectorLogProvider('smoke/t1'),
          (_, next) => emitted.add(next.length),
          fireImmediately: true,
        );

        final buffer = store.logBufferStore.bufferFor('smoke/t1');
        for (var i = 0; i < 50; i++) {
          buffer.append(line: 'line $i', fromStderr: false);
        }

        // One millisecond short of the window, nothing has recomputed yet —
        // the coalescing is what is being tested, so assert both halves.
        async
          ..elapse(kLogInvalidationCoalesceWindow - _oneMs)
          ..flushMicrotasks();
        expect(emitted, [0], reason: 'the window has not closed yet');

        async
          ..elapse(_oneMs)
          ..flushMicrotasks();

        // One initial emission (empty), then exactly one recompute for
        // the whole burst — not one per appended line. Reverting to
        // per-line `invalidateSelf` makes this fail with ~50 emissions.
        expect(emitted, [0, 50]);

        sub.close();
        container.dispose();
      });
    });
  });

  group('inspectorLogSnapshotProvider', () {
    const args = InspectorLogArgs(testId: 'smoke/t1', tailLineCount: 50);

    test('emits an empty snapshot on initial subscribe', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final snapshot = container.read(inspectorLogSnapshotProvider(args));
      expect(snapshot.tailLines, isEmpty);
      expect(snapshot.totalLineCount, 0);
      expect(snapshot.droppedCount, 0);
    });

    test(
      're-evaluates when a new line is appended to the underlying buffer',
      () {
        fakeAsync((async) {
          final container = makeContainer();
          final emitted = <int>[];
          final sub = container.listen<InspectorLogSnapshot>(
            inspectorLogSnapshotProvider(args),
            (_, next) => emitted.add(next.totalLineCount),
            fireImmediately: true,
          );

          store.logBufferStore
              .bufferFor('smoke/t1')
              .append(line: 'hello', fromStderr: false);
          async.elapseCoalesceWindow();

          expect(emitted, contains(0));
          expect(emitted, contains(1));

          sub.close();
          container.dispose();
        });
      },
    );
  });
}

const Duration _oneMs = Duration(milliseconds: 1);

extension on FakeAsync {
  /// Advances exactly one [kLogInvalidationCoalesceWindow] and drains the
  /// microtasks the resulting `invalidateSelf` schedules. No slack: on a fake
  /// clock the window either has elapsed or has not.
  void elapseCoalesceWindow() {
    elapse(kLogInvalidationCoalesceWindow);
    flushMicrotasks();
  }
}

/// Test-only [ResultStoreNotifier] subclass that returns a hand-built
/// store on `build()` so consumers materialize against it from the
/// first `ref.watch`.
class _StubResultStoreNotifier extends ResultStoreNotifier {
  _StubResultStoreNotifier(this._store);

  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
