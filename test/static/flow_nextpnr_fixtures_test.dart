// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The committed nextpnr and FuseSoC fixtures: present, scrubbed, small,
// documented, and consistent with their hand-written expectations.
//
// A missing fixture directory fails here. It is never skipped: a deleted
// corpus must not read as a corpus with nothing to check. The expectations are
// extracted independently of the product's readers (see flow_nextpnr_facts),
// and the regenerators capture output only: neither names an expectation file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'flow_nextpnr_facts.dart';

const _root = 'verification/fixtures/flow/nextpnr';
const _fusesocRoot = 'verification/fixtures/flow/fusesoc';

const _verdictCases = <String>[
  'rescreen_ice40',
  'rescreen_ice40_dsp',
  'rescreen_ecp5',
  'path_ice40_met',
  'path_ice40_violated',
  'path_ecp5_met',
  'path_ecp5_violated',
  'path_gowin_met',
  'path_gowin_violated',
  'path_gatemate_met',
  'path_gatemate_violated',
];

const _mappingCases = <String>[
  'path_ice40_met',
  'path_ecp5_met',
  'path_gowin_met',
  'path_gatemate_met',
];

const int _maxFixtureBytes = 5 * 1024 * 1024;

final RegExp _machinePath = RegExp(
  '/Users/|/home/|/private/|/var/folders|/runner/',
);

Directory _dir(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    fail('missing fixture directory: $path');
  }
  return dir;
}

File _file(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('missing fixture file: $path');
  }
  return file;
}

Iterable<File> _filesUnder(String path) =>
    _dir(path).listSync(recursive: true).whereType<File>();

Map<String, dynamic> _json(String path) =>
    jsonDecode(_file(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('corpus', () {
    test('every case directory exists with its captures', () {
      _dir(_root);
      _dir('$_root/rtl');
      for (final name in _verdictCases) {
        _dir('$_root/$name');
        for (final f in [
          'report.json',
          'pnr.log',
          'exit_code.txt',
          'max_frequency.txt',
          'verdict.expected.json',
        ]) {
          _file('$_root/$name/$f');
        }
        if (!name.endsWith('_violated')) {
          _file('$_root/$name/netlist.json');
        }
      }
      _file('$_root/versions.txt');
      _file('$_root/mapping.expected.json');
      _file('$_root/PROVENANCE.md');
    });

    test('every fixture is under 5 MB', () {
      final over = [
        for (final root in [_root, _fusesocRoot])
          for (final f in _filesUnder(root))
            if (f.lengthSync() >= _maxFixtureBytes) f.path,
      ];
      expect(over, isEmpty);
    });

    test('no capture names a machine path', () {
      final hits = <String>[];
      for (final root in [_root, _fusesocRoot]) {
        for (final f in _filesUnder(root)) {
          if (f.path.endsWith('PROVENANCE.md')) continue;
          final text = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
          if (_machinePath.hasMatch(text)) hits.add(f.path);
        }
      }
      expect(hits, isEmpty, reason: 'unscrubbed paths: $hits');
    });

    test('each set has a PROVENANCE.md naming versions, command and date', () {
      for (final root in [_root, _fusesocRoot]) {
        final text = _file('$root/PROVENANCE.md').readAsStringSync();
        expect(text, contains('nextpnr'), reason: root);
        expect(text, contains('Yosys'), reason: root);
        expect(text, contains('Command'), reason: root);
        expect(text, matches(RegExp(r'[\s\S]*\b\d{4}-\d{2}-\d{2}\b[\s\S]*')));
      }
    });

    test('the regenerators capture output and never name an expectation', () {
      for (final script in [
        'tool/flow/regen_nextpnr_fixtures.sh',
        'tool/flow/regen_fusesoc_fixture.sh',
      ]) {
        final text = _file(script).readAsStringSync();
        expect(text, isNot(contains('expected')), reason: script);
      }
    });
  });

  group('verdicts come from nextpnr own log line', () {
    for (final name in _verdictCases) {
      test(name, () {
        final log = _file('$_root/$name/pnr.log').readAsStringSync();
        final exit = int.parse(
          _file('$_root/$name/exit_code.txt').readAsStringSync().trim(),
        );
        final actual = verdictFromLog(log, exitCode: exit);
        final expected = verdictFromExpectation(
          _file('$_root/$name/verdict.expected.json'),
        );
        expect(actual.toString(), expected.toString());
      });

      test('$name: max_frequency.txt is the grep of pnr.log', () {
        final log = _file('$_root/$name/pnr.log').readAsLinesSync();
        final grepped = log.where((l) => l.contains('Max frequency')).toList();
        expect(
          _file('$_root/$name/max_frequency.txt').readAsLinesSync(),
          grepped,
        );
      });
    }

    test('a met case exits 0 and a violated case exits 1', () {
      for (final name in _verdictCases) {
        final exit = _file('$_root/$name/exit_code.txt').readAsStringSync();
        final met = verdictFromExpectation(
          _file('$_root/$name/verdict.expected.json'),
        ).verdict;
        expect(exit.trim(), met == 'met' ? '0' : '1', reason: name);
      }
    });

    test('the FuseSoC run, which has no report, is met at 16 MHz', () {
      _dir(_fusesocRoot);
      final log = _file('$_fusesocRoot/build/next.log').readAsStringSync();
      final actual = verdictFromLog(log);
      final expected = _json('$_fusesocRoot/verdict.expected.json');
      expect(actual.verdict, expected['verdict']);
      expect(actual.marker, expected['marker']);
      expect(actual.constraintMhz, expected['constraint_mhz'] as num);
      expect(expected['report_json_present'], isFalse);
      final reports = _filesUnder(
        _fusesocRoot,
      ).where((f) => f.path.endsWith('report.json'));
      expect(reports, isEmpty);
      final makefile = _file('$_fusesocRoot/build/Makefile').readAsStringSync();
      expect(makefile, isNot(contains('--report')));
    });
  });

  group('designed path: endpoints known by construction', () {
    final expected = _json('$_root/mapping.expected.json');
    final startRegisters = (expected['start_registers'] as List<dynamic>)
        .cast<String>();
    final endRegister = expected['end_register'] as String;
    final endLine = expected['path_statement_line'] as int;
    final declarations = (expected['declaration_lines'] as Map<String, dynamic>)
        .cast<String, int>();

    test('the expectation matches the RTL', () {
      final rtl = _file('$_root/${expected['design']}').readAsLinesSync();
      for (final entry in declarations.entries) {
        expect(
          rtl[entry.value - 1],
          contains('reg '),
          reason: '${entry.key} declaration line',
        );
        expect(rtl[entry.value - 1], contains(entry.key));
      }
      final statement = rtl[endLine - 1];
      expect(statement, contains(endRegister));
      for (final r in startRegisters) {
        expect(statement, contains(r));
      }
    });

    for (final name in _mappingCases) {
      test(name, () {
        final facts = mappingFromReport(
          _json('$_root/$name/report.json'),
          sourceFile: 'path_adder.v',
          startRegisters: startRegisters,
          endRegister: endRegister,
        );
        expect(startRegisters, contains(facts.startRegister));
        expect(facts.statementLines, contains(endLine));
        final cases = expected['cases'] as Map<String, dynamic>;
        expect(
          facts.cellNamesCarryRegisters,
          (cases[name] as Map<String, dynamic>)['cell_names_carry_register'],
        );
      });
    }
  });

  group('himbaechel reports share the iCE40 and ECP5 schema', () {
    final signatures = {
      for (final name in _mappingCases)
        name: schemaSignature(_json('$_root/$name/report.json')),
    };

    test('every family has the same key shapes', () {
      final reference = signatures['path_ice40_met'];
      for (final entry in signatures.entries) {
        expect(entry.value, reference, reason: entry.key);
      }
    });

    test('the four top-level sections are present', () {
      for (final entry in signatures.entries) {
        expect(entry.value['top'], [
          'critical_paths',
          'detailed_net_timings',
          'fmax',
          'utilization',
        ], reason: entry.key);
      }
    });

    test('the step vocabulary differs by family and is not a fixed list', () {
      final vocabularies = {
        for (final name in _mappingCases)
          name: stepTypes(_json('$_root/$name/report.json')),
      };
      expect(vocabularies['path_gowin_met'], isNot(contains('source')));
      expect(vocabularies['path_gatemate_met'], contains('clk-skew'));
      expect(vocabularies['path_ice40_met'], isNot(contains('clk-skew')));
    });
  });
}
