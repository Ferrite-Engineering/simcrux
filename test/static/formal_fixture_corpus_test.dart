// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The formal fixture corpus (verification/fixtures/formal/): every case is
// present, every capture has a provenance line naming the tool build it
// came from, and every committed capture agrees with the expectation
// written by hand from the property's meaning.
//
// The captures are produced by tool/regenerate_formal_fixtures.sh; the
// expectations never are. When a regenerated capture disagrees with an
// expectation, the fix is to work out from the property which one is
// wrong and record why in PROVENANCE.md, never to copy the tool's answer
// into the expectation.
//
// MUTATION: delete any case directory, any captured/ directory, or a
// schemas/<build>/versions.txt, and this fails by name. Change a hand
// expectation's verdict or step and the agreement group fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/formal_fixture_checks.dart';

String _fx(String relative) => p.join(kFormalFixtureRoot, relative);

/// Fails, never skips, when [relative] is missing.
Directory _requireDir(String relative) {
  final dir = Directory(_fx(relative));
  if (!dir.existsSync()) {
    fail(
      'formal fixture directory $relative is missing (cwd must be the '
      'package root). A missing corpus directory is a failure, not a skip.',
    );
  }
  return dir;
}

File _requireFile(String relative) {
  final file = File(_fx(relative));
  if (!file.existsSync()) fail('formal fixture file $relative is missing');
  return file;
}

String? _read(String relative) {
  final file = File(_fx(relative));
  return file.existsSync() ? file.readAsStringSync() : null;
}

void main() {
  group('corpus layout', () {
    test('the corpus root exists', () => _requireDir('.'));

    for (final name in kFormalSbyCases) {
      test('sby/$name has its inputs, hand expectation and captures', () {
        _requireDir('sby/$name');
        _requireFile('sby/$name/$name.sby');
        _requireFile('sby/$name/$name.expected.json');
        _requireDir('sby/$name/captured');
      });
    }

    test('sva_matrix holds all 51 probes and their captures', () {
      final probes = _requireDir('sva_matrix/probes')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.sv'))
          .toList();
      expect(probes, hasLength(kFormalSvaProbeCount));
      _requireFile('sva_matrix/sva_matrix.expected.json');
      _requireFile('sva_matrix/captured/results.tsv');
    });

    test('eqy has its designs, oracle, configs and captures', () {
      for (final f in ['alu.v', 'gate.v', 'gate_bad.v', 'eqy.expected.json']) {
        _requireFile('eqy/$f');
      }
      _requireFile('eqy/oracle/tb.v');
      _requireFile('eqy/oracle/compare.py');
      for (final run in kFormalEqyRuns) {
        _requireFile('eqy/$run.eqy');
        _requireDir('eqy/captured/$run');
        // The match points' port directions and each partition's inputs,
        // the evidence a failing partition is explained from.
        _requireFile('eqy/captured/$run/gold.ids');
        _requireFile('eqy/captured/$run/matched.ids');
        final partitions = _requireDir(
          'eqy/captured/$run/partitions',
        ).listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
        expect(partitions, isNotEmpty, reason: run);
      }
    });

    test('a missing directory fails rather than skipping', () {
      // The guard itself: _requireDir must throw on an absent path.
      expect(
        () => _requireDir('no_such_case'),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('provenance', () {
    final provenance = _read('PROVENANCE.md') ?? '';

    test('PROVENANCE.md exists and holds the regenerated block', () {
      _requireFile('PROVENANCE.md');
      expect(provenance, contains('<!-- regenerated:begin -->'));
      expect(provenance, contains('<!-- regenerated:end -->'));
      expect(provenance, contains('tool/regenerate_formal_fixtures.sh'));
    });

    // `build <tag>` lines name a build; each must have a versions file with
    // the yosys, sby and eqy lines.
    final builds = RegExp(
      r'^- build (\d{8}):',
      multiLine: true,
    ).allMatches(provenance).map((m) => m.group(1)!).toSet();

    test('three builds are recorded, each with tool versions', () {
      expect(builds.length, greaterThanOrEqualTo(3));
      for (final build in builds) {
        final versions = _requireFile(
          'schemas/$build/versions.txt',
        ).readAsStringSync();
        for (final tool in ['yosys ', 'sby ', 'eqy ', 'yosys-slang ']) {
          expect(
            versions,
            contains(tool),
            reason: 'schemas/$build/versions.txt lacks a $tool line',
          );
        }
      }
    });

    test('every capture has a provenance line naming its build', () {
      final lines = RegExp(r'^- `([^`]+)` build (\d{8})$', multiLine: true)
          .allMatches(provenance)
          .map((m) => (dir: m.group(1)!, build: m.group(2)!))
          .toList();
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(
          builds,
          contains(line.build),
          reason:
              '${line.dir} names build ${line.build}, which has no versions',
        );
      }
      final root = _requireDir('.');
      final uncovered = <String>[];
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        final rel = p.posix.joinAll(
          p.split(p.relative(entity.path, from: root.path)),
        );
        final isCapture =
            rel.contains('/captured/') || rel.startsWith('schemas/');
        if (!isCapture) continue;
        if (!lines.any((l) => rel.startsWith(l.dir))) uncovered.add(rel);
      }
      expect(
        uncovered,
        isEmpty,
        reason:
            'captures with no provenance line (rerun the regenerator):\n'
            '${uncovered.join('\n')}',
      );
    });

    test('no capture carries a machine path', () {
      final offenders = <String>[];
      for (final entity in _requireDir('.').listSync(recursive: true)) {
        if (entity is! File) continue;
        final bytes = entity.readAsBytesSync();
        if (bytes.contains(0)) continue;
        final text = String.fromCharCodes(bytes);
        if (RegExp(r'/Users/|/home/runner/|C:\\Users\\').hasMatch(text)) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'the regenerator scrubs these');
    });

    test('no sqlite sidecar file was committed', () {
      // sby's status.sqlite is in WAL mode, and opening even a copy of it
      // writes -shm and -wal files beside it. The regenerator commits a
      // VACUUM INTO copy with none; a sidecar here means someone opened a
      // capture in place.
      final sidecars = _requireDir('.')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => RegExp(r'\.sqlite-(shm|wal)$').hasMatch(f.path))
          .map((f) => f.path)
          .toList();
      expect(sidecars, isEmpty);
    });

    test('the regenerator keeps its hands off the expectations', () {
      final script = File('tool/regenerate_formal_fixtures.sh');
      expect(script.existsSync(), isTrue);
      final text = script.readAsStringSync();
      // The hash guard proves at the end of a run that no *.expected.*
      // file changed; removing it removes the proof.
      expect(text, contains('expected_hashes'));
      expect(text, contains(r'"$(expected_hashes)" != "$EXPECTED_BEFORE"'));
    });
  });

  group('committed captures agree with the hand expectations', () {
    for (final name in kFormalSbyCases) {
      test('sby/$name', () {
        _requireDir('sby/$name/captured');
        final expected = readJsonObject(_fx('sby/$name/$name.expected.json'));
        final problems = checkSbyCase(
          expected: expected,
          taskLog: (task) => _read('sby/$name/captured/$task/sby.log'),
          taskFile: (task, rel) => _read('sby/$name/captured/$task/$rel'),
          statusJsonl: _read('sby/$name/captured/status.jsonl') ?? '',
        );
        expect(problems, isEmpty, reason: problems.join('\n'));
      });
    }

    test('eqy', () {
      final expected = readJsonObject(_fx('eqy/eqy.expected.json'));
      final runs = expected['runs']! as Map<String, Object?>;
      expect(runs.keys.toSet(), kFormalEqyRuns.toSet());
      final problems = <String>[];
      for (final run in kFormalEqyRuns) {
        final log = _requireFile(
          'eqy/captured/$run/eqy.log',
        ).readAsStringSync();
        problems.addAll(
          checkEqyRun(
            runs[run]! as Map<String, Object?>,
            log,
          ).map((m) => '$run: $m'),
        );
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('sva_matrix', () {
      final expected = readJsonObject(
        _fx('sva_matrix/sva_matrix.expected.json'),
      );
      final probes = objectList(expected['probes']);
      expect(probes, hasLength(kFormalSvaProbeCount));
      final rows = <String, List<String>>{};
      final tsv = _requireFile(
        'sva_matrix/captured/results.tsv',
      ).readAsLinesSync().skip(1).where((l) => l.trim().isNotEmpty);
      for (final line in tsv) {
        final cols = line.split('\t');
        rows['${cols[0]}|${cols[1]}'] = cols;
      }
      final problems = <String>[];
      for (final probe in probes) {
        final name = probe['probe']! as String;
        for (final fe in kFormalSvaFrontends) {
          final row = rows['$name|$fe'];
          if (row == null) {
            problems.add('$name $fe: not captured');
            continue;
          }
          problems.addAll(
            checkSvaProbe(
              probe: probe,
              frontend: fe,
              exitCode: int.parse(row[2]),
              cells: row.length > 3 ? int.tryParse(row[3]) : null,
              log: _read('sva_matrix/captured/$name.$fe.log') ?? '',
            ).map((m) => '$name $fe: $m'),
          );
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });
}
