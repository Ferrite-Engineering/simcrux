// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The committed LibreLane fixtures: present, trimmed, scrubbed, documented,
// and consistent with their hand-written expectations.
//
// A missing fixture directory fails here. It is never skipped: a deleted
// corpus must not read as a corpus with nothing to check. The facts are
// extracted by flow_librelane_facts.dart, which shares no code with the
// product's readers; the regenerator captures output only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'flow_librelane_facts.dart';

const _root = 'verification/fixtures/flow/librelane';

/// Version directory to its cases. The current release line and the one
/// before it; a new release adds a directory and never edits an old one.
const _cases = <String, List<String>>{
  '3.0.16': [
    'sky130A_met',
    'gf180mcuD_met',
    'ihp-sg13g2_met',
    'sky130A_stopped',
    'sky130A_timing',
    'sky130A_drc',
    'sky130A_antenna',
  ],
  '3.0.15': ['sky130A_met'],
};

const int _maxFixtureBytes = 5 * 1024 * 1024;

final RegExp _machinePath = RegExp(
  '/Users/|/home/|/private/|/var/folders|/runner/',
);

Directory _dir(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) fail('missing fixture directory: $path');
  return dir;
}

File _file(String path) {
  final file = File(path);
  if (!file.existsSync()) fail('missing fixture file: $path');
  return file;
}

Iterable<File> _filesUnder(String path) =>
    _dir(path).listSync(recursive: true).whereType<File>();

void main() {
  group('corpus', () {
    test('every case directory exists with its captures', () {
      _dir(_root);
      _file('$_root/PROVENANCE.md');
      _file('$_root/MAPPING-GATE.md');
      _file('$_root/mapping.expected.json');
      _file('$_root/designs/path_adder/path_adder.v');
      _file('$_root/designs/picorv32/picorv32.v');
      _file('$_root/designs/picorv32/config.yaml');
      for (final entry in _cases.entries) {
        for (final name in entry.value) {
          final dir = '$_root/${entry.key}/$name';
          _dir('$dir/run');
          for (final f in [
            'exit_code.txt',
            'console.tail.txt',
            'case.expected.json',
            'run/TRIMMED.json',
            'run/resolved.json',
            'run/flow.log',
            'run/error.log',
            'run/warning.log',
          ]) {
            _file('$dir/$f');
          }
        }
      }
      _file('$_root/3.0.16/g1.expected.json');
    });

    test('every fixture file is under 5 MB', () {
      final over = [
        for (final f in _filesUnder(_root))
          if (f.lengthSync() >= _maxFixtureBytes) f.path,
      ];
      expect(over, isEmpty);
    });

    test('no capture names a machine path', () {
      final hits = <String>[];
      for (final f in _filesUnder(_root)) {
        if (f.path.endsWith('.md')) continue;
        final text = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
        if (_machinePath.hasMatch(text)) hits.add(f.path);
      }
      expect(hits, isEmpty, reason: 'unscrubbed paths: $hits');
    });

    test('PROVENANCE.md names versions, PDK hashes, command and date', () {
      final text = _file('$_root/PROVENANCE.md').readAsStringSync();
      for (final word in [
        'LibreLane',
        '3.0.16',
        '3.0.15',
        'ciel',
        'Command',
        'trim_run_fixture.py',
      ]) {
        expect(text, contains(word));
      }
      expect(text, matches(RegExp(r'[\s\S]*\b\d{4}-\d{2}-\d{2}\b[\s\S]*')));
      expect(text, matches(RegExp(r'[\s\S]*\b[0-9a-f]{40}\b[\s\S]*')));
    });

    test('the regenerator captures output and never names an expectation', () {
      final text = _file(
        'tool/flow/regen_librelane_fixtures.sh',
      ).readAsStringSync();
      expect(text, isNot(contains('expected')));
    });

    test('the small design is the nextpnr designed-path adder, unchanged', () {
      expect(
        _file('$_root/designs/path_adder/path_adder.v').readAsStringSync(),
        _file(
          'verification/fixtures/flow/nextpnr/rtl/path_adder.v',
        ).readAsStringSync(),
      );
    });
  });

  group('trimming', () {
    for (final entry in _cases.entries) {
      for (final name in entry.value) {
        final run = '$_root/${entry.key}/$name/run';
        test('${entry.key}/$name: placeholders are empty, drops are gone', () {
          final manifest = readJson('$run/TRIMMED.json');
          final removed = (manifest['removed'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          expect(removed, isNotEmpty);
          for (final r in removed) {
            final f = File('$run/${r['path']}');
            if (r['action'] == 'placeholder') {
              expect(f.existsSync(), isTrue, reason: r['path'] as String);
              expect(f.lengthSync(), 0, reason: r['path'] as String);
              expect(r['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
            } else {
              expect(r['action'], 'dropped');
              expect(f.existsSync(), isFalse, reason: r['path'] as String);
            }
          }
          expect(Directory('$run/tmp').existsSync(), isFalse);
        });

        test('${entry.key}/$name: no binary view kept', () {
          final kept = _filesUnder(run).where((f) => f.lengthSync() > 0);
          final views = [
            for (final f in kept)
              if (RegExp(r'\.(gds|odb|def|spef|mag|png)$').hasMatch(f.path))
                f.path,
          ];
          expect(views, isEmpty);
        });
      }
    }
  });

  group('facts match the hand-written expectations', () {
    final mapping = readJson('$_root/mapping.expected.json');
    for (final entry in _cases.entries) {
      for (final name in entry.value) {
        test('${entry.key}/$name', () {
          final dir = Directory('$_root/${entry.key}/$name');
          final expected = readJson('${dir.path}/case.expected.json');
          final diffs = caseDifferences(
            dir,
            expected,
            exactMetrics: true,
            mapping: mapping,
          );
          expect(diffs, isEmpty);
        });
      }
    }

    test('the mapping expectation matches the RTL', () {
      final rtl = _file(
        '$_root/designs/path_adder/path_adder.v',
      ).readAsLinesSync();
      final line = mapping['path_statement_line'] as int;
      expect(rtl[line - 1], contains(mapping['end_register'] as String));
      for (final r in (mapping['start_registers'] as List<dynamic>)) {
        expect(rtl[line - 1], contains(r as String));
      }
      for (final r in (mapping['registers'] as List<dynamic>)) {
        expect(
          rtl.where((l) => l.contains('reg ') && l.contains(r as String)),
          isNotEmpty,
          reason: '$r is declared',
        );
      }
    });
  });

  group('run layout', () {
    test('the synthesis sidecar keeps its name and joins to the netlist', () {
      for (final entry in _cases.entries) {
        for (final name in entry.value) {
          final run = Directory('$_root/${entry.key}/$name/run');
          final synth = stepDir(run, 'yosys-synthesis');
          expect(synth, isNotNull, reason: name);
          final json = File('${synth!.path}/path_adder.nl.v.json');
          final netlist = File('${synth.path}/path_adder.nl.v');
          expect(json.lengthSync(), greaterThan(0), reason: name);
          final sidecar = Sidecar(readJson(json.path), 'path_adder');
          final instances = RegExp(
            r'^\s*\S+\s+(_\d+_)\s*\(',
            multiLine: true,
          ).allMatches(netlist.readAsStringSync()).map((m) => m[1]!).toSet();
          final rebuilt = sidecar.names.entries
              .where(
                (e) => (sidecar.module['cells'] as Map).containsKey(e.value),
              )
              .map((e) => e.key)
              .toSet();
          expect(rebuilt, isNotEmpty, reason: name);
          expect(rebuilt.difference(instances), isEmpty, reason: name);
        }
      }
    });

    test('3.0.15 and 3.0.16 write the same step sequence', () {
      List<String> slugs(String version) => [
        for (final d in stepDirs(
          Directory('$_root/$version/sky130A_met/run'),
        ))
          dirName(d),
      ];
      expect(slugs('3.0.15'), slugs('3.0.16'));
    });

    test('every kept STA path listing parses and its arithmetic closes', () {
      var parsed = 0;
      for (final entry in _cases.entries) {
        for (final name in entry.value) {
          final run = Directory('$_root/${entry.key}/$name/run');
          final sta = stepDir(run, 'openroad-stapostpnr');
          if (sta == null) continue;
          for (final f in sta.listSync(recursive: true).whereType<File>()) {
            if (!RegExp(r'/(max|min)\.rpt$').hasMatch(f.path)) continue;
            if (f.lengthSync() == 0) continue;
            for (final p in parseStaReport(f.readAsStringSync())) {
              final want = p.type == 'max'
                  ? p.required - p.arrival
                  : p.arrival - p.required;
              expect(
                (want - p.slack).abs(),
                lessThan(5e-6),
                reason: '${f.path} path ${p.rank}',
              );
              expect(p.segments, isNotEmpty, reason: '${f.path} ${p.rank}');
              expect(p.pins.last.time, closeTo(p.arrival, 5e-6));
              parsed++;
            }
          }
        }
      }
      expect(parsed, greaterThan(100));
    });
  });

  group('G1 expectation', () {
    test('records the design, the threshold rule and the outcome', () {
      final g1 = readJson('$_root/3.0.16/g1.expected.json');
      expect(g1['design'], 'picorv32');
      expect(g1['min_flip_flops'], 500);
      expect(g1['endpoints'], 100);
      expect(g1['outcome'], isIn(['>=90', '60-90', '<60']));
      final gate = _file('$_root/MAPPING-GATE.md').readAsStringSync();
      expect(gate, contains(g1['outcome'] as String));
    });
  });
}
