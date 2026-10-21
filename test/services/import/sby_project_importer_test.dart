// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/sby_project_importer.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

// The general `.sby` importer: one SimCrux test per task, a project file the
// loader accepts with no edits, and the job file named relative to it.

const String _multiTask = '''
[tasks]
prove
prove_bug prove
cover

[options]
prove: mode prove
cover: mode cover
depth 12

[engines]
smtbmc yices

[script]
read -formal handshake.sv
prep -top handshake

[files]
handshake.sv
''';

const String _single = '''
[options]
mode bmc
depth 20

[engines]
smtbmc

[script]
read -formal fifo.sv
prep -top fifo

[files]
fifo.sv
''';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sby_import_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String rel, String text) {
    final file = File(p.join(tmp.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    return file.path;
  }

  group('enumerate', () {
    test('a file with [tasks] becomes one test per task, in order', () {
      final sby = write('handshake.sby', _multiTask);
      final jobs = SbyProjectImporter().enumerate(sby);
      expect(jobs, hasLength(1));
      expect(jobs.single.tasks, ['prove', 'prove_bug', 'cover']);
    });

    test('a file without [tasks] becomes one test for its default task', () {
      final sby = write('fifo.sby', _single);
      expect(SbyProjectImporter().enumerate(sby).single.tasks, [null]);
    });

    test('a directory imports every .sby directly in it, sorted', () {
      write('jobs/b.sby', _single);
      write('jobs/a.sby', _multiTask);
      write('jobs/notes.txt', 'not a job');
      write('jobs/nested/c.sby', _single);
      final jobs = SbyProjectImporter().enumerate(p.join(tmp.path, 'jobs'));
      expect(jobs.map((j) => p.basename(j.path)), ['a.sby', 'b.sby']);
    });

    test('--task keeps only the named tasks, and drops a file without '
        'them', () {
      write('jobs/a.sby', _multiTask);
      write('jobs/b.sby', _single);
      final jobs = SbyProjectImporter().enumerate(
        p.join(tmp.path, 'jobs'),
        tasks: const ['cover', 'prove'],
      );
      expect(jobs, hasLength(1));
      expect(jobs.single.tasks, ['prove', 'cover']);
    });

    test('a task nothing declares is refused, naming what is declared', () {
      final sby = write('handshake.sby', _multiTask);
      expect(
        () => SbyProjectImporter().enumerate(sby, tasks: const ['nope']),
        throwsA(
          isA<FormalImportException>().having(
            (e) => e.message,
            'message',
            allOf(contains('nope'), contains('cover, prove, prove_bug')),
          ),
        ),
      );
    });

    test('a path that is not a job file, or holds none, is refused', () {
      final txt = write('readme.txt', 'hello');
      expect(
        () => SbyProjectImporter().enumerate(txt),
        throwsA(isA<FormalImportException>()),
      );
      Directory(p.join(tmp.path, 'empty')).createSync();
      expect(
        () => SbyProjectImporter().enumerate(p.join(tmp.path, 'empty')),
        throwsA(isA<FormalImportException>()),
      );
      expect(
        () => SbyProjectImporter().enumerate(p.join(tmp.path, 'missing')),
        throwsA(isA<FormalImportException>()),
      );
    });

    test('expandTasks is the one split both importers use', () {
      expect(SbyProjectImporter.expandTasks(const SbyScript()), [null]);
      expect(
        SbyProjectImporter.expandTasks(SbyScript.parse(_multiTask)),
        ['prove', 'prove_bug', 'cover'],
      );
    });
  });

  group('importJobs', () {
    test('the emitted file loads with zero errors and zero warnings, one '
        'sby test per task', () async {
      final sby = write('proj/handshake.sby', _multiTask);
      final result = SbyProjectImporter().importJobs(
        path: sby,
        outputDirectory: p.join(tmp.path, 'proj'),
      );
      expect(result.testCount, 3);
      expect(result.jobs, ['handshake.sby']);
      final out = write('proj/simcrux.yaml', result.simcruxYaml);
      final config = await ConfigLoader().load(out);
      expect(config.loadWarnings, isEmpty);
      final tests = [for (final s in config.suites) ...s.tests];
      expect(tests.map((t) => t.name), ['prove', 'prove_bug', 'cover']);
      for (final t in tests) {
        expect(t.simulatorId, SbyDriver.kId);
        expect(t.formal?.sbyFile, p.normalize(sby));
        expect(t.formal?.task, t.name);
      }
    });

    test('the job file is written relative to the project file below it, '
        'absolute otherwise', () {
      final sby = write('proj/formal/handshake.sby', _multiTask);
      final below = SbyProjectImporter().importJobs(
        path: sby,
        outputDirectory: p.join(tmp.path, 'proj'),
      );
      expect(below.simcruxYaml, contains('sby_file: formal/handshake.sby'));
      final elsewhere = SbyProjectImporter().importJobs(
        path: sby,
        outputDirectory: p.join(tmp.path, 'other'),
      );
      expect(elsewhere.simcruxYaml, contains(p.normalize(sby)));
      expect(
        elsewhere.simcruxYaml,
        isNot(contains('sby_file: formal/handshake.sby')),
      );
    });

    test("the detector keys on the parser's own pass marker", () {
      final sby = write('fifo.sby', _single);
      final yaml = SbyProjectImporter()
          .importJobs(path: sby, outputDirectory: tmp.path)
          .simcruxYaml;
      expect(yaml, contains('type: string_match'));
      expect(yaml, contains("pass_string: '${SbyLogReader.kPassMarker}'"));
      expect(yaml, contains('simulator: sby'));
      // A file without [tasks] runs its default task: no `task:` key.
      expect(RegExp(r'^\s+task:', multiLine: true).hasMatch(yaml), isFalse);
    });

    test('a job file that turns assertions off imports with a warning in '
        'the header', () {
      final sby = write(
        'quiet.sby',
        '[script]\nread -formal -noassert quiet.sv\nprep -top quiet\n',
      );
      final result = SbyProjectImporter().importJobs(
        path: sby,
        outputDirectory: tmp.path,
      );
      expect(result.warnings.single.code, 'assertions_disabled');
      expect(result.simcruxYaml, contains('[assertions_disabled]'));
    });

    test('--sby-binary lands once, under defaults.formal', () {
      final sby = write('fifo.sby', _single);
      final yaml = SbyProjectImporter()
          .importJobs(
            path: sby,
            outputDirectory: tmp.path,
            sbyBinary: '/opt/oss-cad-suite/bin/sby',
          )
          .simcruxYaml;
      expect(
        RegExp('sby_binary:').allMatches(yaml),
        hasLength(1),
      );
    });

    test('two job files with the same safe name get distinct suites', () {
      write('jobs/a.b.sby', _single);
      write('jobs/a_b.sby', _single);
      final yaml = SbyProjectImporter()
          .importJobs(path: p.join(tmp.path, 'jobs'), outputDirectory: tmp.path)
          .simcruxYaml;
      expect(yaml, contains('  a_b:'));
      expect(yaml, contains('  a_b_2:'));
    });

    test('the suggested file name is simcrux.yaml', () {
      expect(FormalImportResult.kSuggestedOutputFilename, 'simcrux.yaml');
    });
  });
}
