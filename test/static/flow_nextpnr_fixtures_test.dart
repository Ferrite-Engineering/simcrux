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

  group('captured netlists keep the user source spans', () {
    // Yosys joins the spans of one cell with '|'. A scrub that rewrites the
    // library path must start after that bar, or it swallows the user span in
    // front of it and leaves 'file.v:<yosys-share>/lib.v:..' behind.
    final span = RegExp(r'^[^:|]+:\d+\.\d+-\d+\.\d+$');
    final netlists = <String, String>{
      for (final name in _verdictCases)
        if (!name.endsWith('_violated')) name: '$_root/$name/netlist.json',
      'fusesoc': '$_fusesocRoot/build/award-winning_serv_servant_1.4.0.json',
    };

    Map<String, List<String>> srcsOf(String path) {
      final out = <String, List<String>>{};
      void walk(Object? node) {
        if (node is Map<String, dynamic>) {
          for (final e in node.entries) {
            final v = e.value;
            if (e.key == 'src' && v is String) {
              (out[v] ??= []).add(v);
            } else {
              walk(v);
            }
          }
        } else if (node is List<dynamic>) {
          node.forEach(walk);
        }
      }

      walk(jsonDecode(_file(path).readAsStringSync()));
      return out;
    }

    for (final entry in netlists.entries) {
      test(
        '${entry.key}: every src is a bar-joined list of file:line spans',
        () {
          final srcs = srcsOf(entry.value).keys;
          expect(srcs, isNotEmpty);
          final bad = [
            for (final src in srcs)
              if (src.contains(':<') ||
                  src.split('|').any((s) => !span.hasMatch(s)))
                src,
          ];
          expect(bad, isEmpty, reason: 'malformed src values: $bad');
        },
      );

      test('${entry.key}: no src names a machine path', () {
        final bad = [
          for (final src in srcsOf(entry.value).keys)
            if (_machinePath.hasMatch(src)) src,
        ];
        expect(bad, isEmpty);
      });
    }

    test('a user span survives in front of a library span', () {
      for (final entry in netlists.entries) {
        final kept = srcsOf(entry.value).keys.where((src) {
          final spans = src.split('|');
          return spans.length > 1 &&
              !spans.first.startsWith('<') &&
              spans.skip(1).any((s) => s.startsWith('<yosys-share>/'));
        });
        expect(kept, isNotEmpty, reason: '${entry.key} lost its user spans');
      }
    });

    test(
      'the designed adder statement (line 16) has a user span per family',
      () {
        final expected = _json('$_root/mapping.expected.json');
        final line = expected['path_statement_line'] as int;
        final design = (expected['design'] as String).split('/').last;
        final lines = RegExp(
          '(?:^|\\|)${RegExp.escape(design)}:(\\d+)\\.\\d+-(\\d+)\\.\\d+',
        );
        for (final name in _mappingCases) {
          final covering = srcsOf('$_root/$name/netlist.json').keys.where(
            (src) => lines
                .allMatches(src)
                .any(
                  (m) => int.parse(m[1]!) <= line && line <= int.parse(m[2]!),
                ),
          );
          expect(
            covering,
            isNotEmpty,
            reason: '$name has no span on line $line',
          );
        }
      },
    );

    test('the regenerators exclude the span separator from the path match', () {
      for (final script in [
        'tool/flow/regen_nextpnr_fixtures.sh',
        'tool/flow/regen_fusesoc_fixture.sh',
      ]) {
        final text = _file(script).readAsStringSync();
        final rules = RegExp(
          r"-e 's#\[\^([^\]]*)\]\*/(?:share/yosys|libexec)",
        ).allMatches(text).toList();
        expect(rules, isNotEmpty, reason: script);
        for (final rule in rules) {
          expect(rule[1], contains('|'), reason: '$script: ${rule[0]}');
        }
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
