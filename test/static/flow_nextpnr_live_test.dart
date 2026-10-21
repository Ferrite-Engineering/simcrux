// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live assertions: re-run the real tools through the regenerators and check the
// hand-written expectations against what they print now.
//
// Gated on tool presence. Set OSS_CAD_SUITE to a suite directory (the one that
// holds bin/), or put yosys and the nextpnr binaries on PATH. Without either
// the group is skipped, unless FLOW_LIVE_REQUIRED=1, which turns a missing tool
// into a failure; the weekly workflow sets it so a dead install cannot pass as
// a skip. The FuseSoC group also needs network and FLOW_LIVE_FUSESOC=1.
//
// Facts are compared, not bytes: exit status, nextpnr's own PASS or FAIL line,
// the designed endpoints, and the report schema. Frequencies and placement move
// with every nextpnr build and are not pinned.

@Timeout(Duration(minutes: 25))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'flow_nextpnr_facts.dart';

const _root = 'verification/fixtures/flow/nextpnr';
const _fusesocRoot = 'verification/fixtures/flow/fusesoc';

const _mappingCases = <String>[
  'path_ice40_met',
  'path_ecp5_met',
  'path_gowin_met',
  'path_gatemate_met',
];

String? get _suite {
  final value = Platform.environment['OSS_CAD_SUITE'];
  return (value == null || value.isEmpty) ? null : value;
}

bool get _required => Platform.environment['FLOW_LIVE_REQUIRED'] == '1';

bool _onPath(String tool) {
  final result = Process.runSync('which', [tool]);
  return result.exitCode == 0;
}

/// Why the nextpnr group cannot run, or null when it can.
String? _nextpnrBlocker() {
  final suite = _suite;
  if (suite != null) {
    final yosys = File('$suite/bin/yosys');
    return yosys.existsSync() ? null : 'no bin/yosys under OSS_CAD_SUITE';
  }
  for (final tool in [
    'yosys',
    'nextpnr-ice40',
    'nextpnr-ecp5',
    'nextpnr-himbaechel',
  ]) {
    if (!_onPath(tool)) {
      return '$tool is not on PATH and OSS_CAD_SUITE is unset';
    }
  }
  return null;
}

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  final blocker = _nextpnrBlocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () {
      fail('FLOW_LIVE_REQUIRED=1 and $blocker');
    });
  }

  group(
    'nextpnr live',
    () {
      late Directory out;

      setUpAll(() {
        out = Directory.systemTemp.createTempSync('flow_nextpnr_live_');
        final suite = _suite;
        final result = Process.runSync('bash', [
          'tool/flow/regen_nextpnr_fixtures.sh',
          if (suite != null) ...['--suite', suite],
          '--out',
          out.path,
        ]);
        if (result.exitCode != 0) {
          fail(
            'regenerator exited ${result.exitCode}\n'
            '${result.stdout}\n${result.stderr}',
          );
        }
      });

      tearDownAll(() {
        if (out.existsSync()) out.deleteSync(recursive: true);
      });

      for (final name in const [
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
      ]) {
        test('$name: verdict and exit status', () {
          final log = File('${out.path}/$name/pnr.log').readAsStringSync();
          final exit = int.parse(
            File('${out.path}/$name/exit_code.txt').readAsStringSync().trim(),
          );
          final actual = verdictFromLog(log, exitCode: exit);
          final expected = verdictFromExpectation(
            File('$_root/$name/verdict.expected.json'),
          );
          expect(actual.toString(), expected.toString());
        });
      }

      final mapping = _json('$_root/mapping.expected.json');
      for (final name in _mappingCases) {
        test('$name: designed endpoints', () {
          final facts = mappingFromReport(
            _json('${out.path}/$name/report.json'),
            sourceFile: 'path_adder.v',
            startRegisters: (mapping['start_registers'] as List<dynamic>)
                .cast<String>(),
            endRegister: mapping['end_register'] as String,
          );
          expect(mapping['start_registers'], contains(facts.startRegister));
          expect(
            facts.statementLines,
            contains(mapping['path_statement_line']),
          );
          final cases = mapping['cases'] as Map<String, dynamic>;
          expect(
            facts.cellNamesCarryRegisters,
            (cases[name] as Map<String, dynamic>)['cell_names_carry_register'],
          );
        });
      }

      test('every family still writes one report schema', () {
        final reference = schemaSignature(
          _json('${out.path}/path_ice40_met/report.json'),
        );
        for (final name in _mappingCases) {
          expect(
            schemaSignature(_json('${out.path}/$name/report.json')),
            reference,
            reason: name,
          );
        }
      });
    },
    skip: blocker,
  );

  final fusesocOn = Platform.environment['FLOW_LIVE_FUSESOC'] == '1';
  group(
    'FuseSoC live',
    () {
      test('servant on icebreaker: met at 16 MHz with no report file', () {
        final out = Directory.systemTemp.createTempSync('flow_fusesoc_live_');
        addTearDown(() => out.deleteSync(recursive: true));
        final suite = _suite;
        final yosysDir = Platform.environment['FLOW_LIVE_YOSYS_DIR'];
        final result = Process.runSync('bash', [
          'tool/flow/regen_fusesoc_fixture.sh',
          if (suite != null) ...['--suite', suite],
          if (yosysDir != null && yosysDir.isNotEmpty) ...[
            '--yosys-dir',
            yosysDir,
          ],
          '--out',
          out.path,
        ]);
        if (result.exitCode != 0) {
          fail(
            'regenerator exited ${result.exitCode}\n'
            '${result.stdout}\n${result.stderr}',
          );
        }
        final actual = verdictFromLog(
          File('${out.path}/build/next.log').readAsStringSync(),
        );
        final expected = _json('$_fusesocRoot/verdict.expected.json');
        expect(actual.verdict, expected['verdict']);
        expect(actual.marker, expected['marker']);
        expect(actual.constraintMhz, expected['constraint_mhz']);
        final reports = out
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('report.json'));
        expect(reports, isEmpty);
      });
    },
    skip: fusesocOn ? blocker : 'FLOW_LIVE_FUSESOC is not 1',
  );
}
