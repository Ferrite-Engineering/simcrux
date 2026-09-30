// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/waveform_archive.dart';

/// The archive relocates a passing test's waveform out of its (about-to-be-
/// deleted) work dir into a durable, separately-bounded pool, so a later
/// "Debug in WaveCrux" hand-off resolves a file that still exists.
void main() {
  late Directory poolRoot;
  late Directory workRoot;
  late WaveformArchive archive;

  setUp(() {
    poolRoot = Directory.systemTemp.createTempSync('simcrux_wf_pool_');
    workRoot = Directory.systemTemp.createTempSync('simcrux_wf_work_');
    archive = WaveformArchive(resolveRoot: () async => poolRoot.path);
  });
  tearDown(() {
    for (final d in <Directory>[poolRoot, workRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  /// Writes a dump file with [content] into a fake work dir and returns its
  /// path.
  String makeDump(String name, String content) {
    final f = File(p.join(workRoot.path, name))..writeAsStringSync(content);
    return f.path;
  }

  group('retain', () {
    test(
      'moves the dump into <root>/<runId>/<testId>/ and returns it',
      () async {
        final src = makeDump('dump.vcd', 'VCD-BODY');

        final archived = await archive.retain(
          waveformPath: src,
          runId: 'run-1',
          testId: 'uart_tx.frame',
        );

        expect(archived, isNotNull);
        expect(
          archived,
          p.join(poolRoot.path, 'run-1', 'uart_tx.frame', 'dump.vcd'),
        );
        // Durable copy exists with the original content...
        expect(File(archived!).existsSync(), isTrue);
        expect(File(archived).readAsStringSync(), 'VCD-BODY');
        // ...and the source has been moved out (work dir is about to be swept).
        expect(File(src).existsSync(), isFalse);
      },
    );

    test('sanitises testId into a filesystem-safe directory segment', () async {
      final src = makeDump('wave.fst', 'x');

      final archived = await archive.retain(
        waveformPath: src,
        runId: 'run-1',
        testId: 'suite/case[0]',
      );

      expect(archived, isNotNull);
      expect(p.basename(p.dirname(archived!)), 'suite_case_0_');
      expect(File(archived).existsSync(), isTrue);
    });

    test('returns null when the source dump no longer exists', () async {
      final archived = await archive.retain(
        waveformPath: p.join(workRoot.path, 'gone.vcd'),
        runId: 'run-1',
        testId: 't',
      );

      expect(archived, isNull);
    });
  });

  group('prune', () {
    test('bounds the pool by its own policy, newest-first', () async {
      // Three archived entries across runs, aged so run-old is oldest.
      final base = DateTime.now();
      for (final e in <({String run, int ageSec})>[
        (run: 'run-new', ageSec: 0),
        (run: 'run-mid', ageSec: 100),
        (run: 'run-old', ageSec: 200),
      ]) {
        final dir = Directory(p.join(poolRoot.path, e.run, 'case'))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'dump.vcd'))
          ..writeAsStringSync('body')
          ..setLastModifiedSync(base.subtract(Duration(seconds: e.ageSec)));
      }

      final deleted = await archive.prune(
        const DumpRetentionPolicy(keepLastNFailures: 2),
      );

      expect(deleted, 1);
      expect(Directory(p.join(poolRoot.path, 'run-new')).existsSync(), isTrue);
      expect(Directory(p.join(poolRoot.path, 'run-mid')).existsSync(), isTrue);
      // Oldest entry pruned; its now-empty run dir swept too.
      expect(Directory(p.join(poolRoot.path, 'run-old')).existsSync(), isFalse);
    });

    test('an unbounded policy prunes nothing', () async {
      final dir = Directory(p.join(poolRoot.path, 'run', 'case'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'dump.vcd')).writeAsStringSync('body');

      final deleted = await archive.prune(DumpRetentionPolicy.unbounded);

      expect(deleted, 0);
      expect(dir.existsSync(), isTrue);
    });
  });
}
