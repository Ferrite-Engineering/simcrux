// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/services/trend_store/waveform_retention_sweeper.dart';

/// A store that answers with a fixed list and records what it was told to
/// forget.
class _FakeStore extends TrendStore {
  _FakeStore(this._stale, {this.throwOnQuery = false});

  final List<String> _stale;
  final bool throwOnQuery;
  List<String>? forgotten;
  int? askedKeep;

  @override
  Future<List<String>> waveformPathsBeforeRecentRuns(int keepRuns) async {
    askedKeep = keepRuns;
    if (throwOnQuery) throw StateError('store unavailable');
    return _stale;
  }

  @override
  Future<void> forgetWaveformPaths(Iterable<String> paths) async {
    forgotten = paths.toList();
  }

  @override
  Future<void> recordTrendPoint(TrendPoint point) async {}

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) =>
      const Stream<TrendPoint>.empty();

  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) =>
      const Stream<TrendDelta>.empty();
}

/// An in-memory filesystem: a path is present iff it has a size here.
class _FakeFs implements FileSystemDelegate {
  _FakeFs(this.sizes, {this.undeletable = const <String>{}});

  final Map<String, int> sizes;
  final Set<String> undeletable;
  final List<String> deleted = <String>[];

  @override
  Future<int?> sizeOf(String path) async => sizes[path];

  @override
  Future<void> delete(String path) async {
    if (undeletable.contains(path)) {
      throw const FileSystemExceptionStub('permission denied');
    }
    deleted.add(path);
    sizes.remove(path);
  }
}

/// Stand-in for a filesystem error; the sweeper catches Object, so the exact
/// type does not matter and using a real FileSystemException would drag
/// dart:io into a pure test.
class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub(this.message);
  final String message;
  @override
  String toString() => 'FileSystemExceptionStub: $message';
}

void main() {
  group('WaveformRetentionSweeper', () {
    test('a null waveform limit sweeps nothing — the store is not even '
        'asked', () async {
      final store = _FakeStore(['/tmp/a.fst']);
      final result = await const WaveformRetentionSweeper().sweep(
        store,
        const RetentionPolicy(maxAgeDays: 30),
      );

      expect(result, WaveformSweepResult.none);
      expect(store.askedKeep, isNull);
    });

    test('deletes stale dumps and reports the bytes reclaimed', () async {
      final fs = _FakeFs({'/w/a.fst': 1000, '/w/b.fst': 2500});
      final store = _FakeStore(['/w/a.fst', '/w/b.fst']);

      final result = await WaveformRetentionSweeper(fileSystem: fs).sweep(
        store,
        const RetentionPolicy(maxWaveformRuns: 10),
      );

      expect(store.askedKeep, 10);
      expect(fs.deleted, ['/w/a.fst', '/w/b.fst']);
      expect(result.deletedFiles, 2);
      expect(result.reclaimedBytes, 3500);
      expect(result.missingFiles, 0);
    });

    test('forgets the paths so the inspector stops offering a deleted '
        'waveform', () async {
      final fs = _FakeFs({'/w/a.fst': 10});
      final store = _FakeStore(['/w/a.fst']);

      await WaveformRetentionSweeper(fileSystem: fs).sweep(
        store,
        const RetentionPolicy(maxWaveformRuns: 5),
      );

      expect(store.forgotten, ['/w/a.fst']);
    });

    test('an already-missing file is counted, not an error, and its row is '
        'still forgotten', () async {
      // The user cleaned up by hand, or a working directory was wiped.
      final fs = _FakeFs(<String, int>{});
      final store = _FakeStore(['/w/gone.fst']);

      final result = await WaveformRetentionSweeper(fileSystem: fs).sweep(
        store,
        const RetentionPolicy(maxWaveformRuns: 5),
      );

      expect(result.deletedFiles, 0);
      expect(result.missingFiles, 1);
      expect(result.reclaimedBytes, 0);
      expect(store.forgotten, ['/w/gone.fst']);
    });

    test('one undeletable file does not abort the sweep, and its row keeps '
        'pointing at the file that is still there', () async {
      final fs = _FakeFs(
        {'/w/locked.fst': 100, '/w/ok.fst': 200},
        undeletable: {'/w/locked.fst'},
      );
      final store = _FakeStore(['/w/locked.fst', '/w/ok.fst']);

      final result = await WaveformRetentionSweeper(fileSystem: fs).sweep(
        store,
        const RetentionPolicy(maxWaveformRuns: 5),
      );

      expect(fs.deleted, ['/w/ok.fst']);
      expect(result.deletedFiles, 1);
      expect(
        store.forgotten,
        ['/w/ok.fst'],
        reason:
            'a dangling "Open waveform" is worse than a retained one — the '
            'locked file may still be openable',
      );
    });

    test('a store that cannot answer yields a no-op rather than throwing '
        'into the run that triggered the sweep', () async {
      final store = _FakeStore(const [], throwOnQuery: true);

      final result = await const WaveformRetentionSweeper().sweep(
        store,
        const RetentionPolicy(maxWaveformRuns: 5),
      );

      expect(result, WaveformSweepResult.none);
    });

    test('keeping zero runs is legal and sweeps everything — distinct from '
        'null, which keeps everything', () async {
      final fs = _FakeFs({'/w/a.fst': 1});
      final store = _FakeStore(['/w/a.fst']);

      final result = await WaveformRetentionSweeper(fileSystem: fs).sweep(
        store,
        const RetentionPolicy(maxWaveformRuns: 0),
      );

      expect(store.askedKeep, 0);
      expect(result.deletedFiles, 1);
    });
  });

  group('RetentionPolicy waveform field', () {
    test('the default keeps ten runs of waveforms', () {
      expect(RetentionPolicy.defaultPolicy.maxWaveformRuns, 10);
    });

    test('unlimited means unlimited on all three axes', () {
      expect(RetentionPolicy.unlimited.maxWaveformRuns, isNull);
      expect(RetentionPolicy.unlimited.isUnlimited, isTrue);
    });

    test('a policy that only bounds waveforms is not unlimited — otherwise '
        'the runner would skip the sweep it was configured for', () {
      const policy = RetentionPolicy(maxWaveformRuns: 3);
      expect(policy.isUnlimited, isFalse);
    });

    test('round-trips through JSON', () {
      const policy = RetentionPolicy(
        maxAgeDays: 7,
        maxDataPoints: 100,
        maxWaveformRuns: 3,
        pruneStrategy: RetentionPruneStrategy.lowestValueFirst,
      );
      expect(RetentionPolicy.fromJson(policy.toJson()), policy);
    });

    test('settings written before the field existed still load', () {
      // Forward-compatibility: an old persisted blob has no
      // maxWaveformRuns key at all.
      final legacy = <String, Object?>{
        'maxAgeDays': 30,
        'maxDataPoints': 50000,
        'pruneStrategy': 'oldestFirst',
      };
      final policy = RetentionPolicy.fromJson(legacy);
      expect(policy.maxAgeDays, 30);
      expect(
        policy.maxWaveformRuns,
        isNull,
        reason:
            'absent means unlimited, not the default — a user upgrading '
            'must not have dumps deleted by a policy they never set',
      );
    });

    test('clearMaxWaveformRuns clears it', () {
      const policy = RetentionPolicy(maxWaveformRuns: 5);
      expect(
        policy.copyWith(clearMaxWaveformRuns: true).maxWaveformRuns,
        isNull,
      );
    });
  });
}
