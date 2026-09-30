// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/config/config_loader.dart';

void main() {
  late ConfigLoader loader;

  setUp(() {
    loader = ConfigLoader();
  });

  group('ConfigLoader.parse — happy paths', () {
    test('parses a minimal project example', () {
      const yaml = '''
version: "1"

defaults:
  simulator: icarus
  timeout: 300s
  pass_fail:
    type: exit_code
  waveform:
    capture: on_failure
    format: fst

suites:
  unit:
    sources:
      - rtl/cpu.v
      - tb/unit/alu_tb.v
    tests:
      - name: alu_basic
        top: alu_tb
      - name: alu_signed
        top: alu_tb
        defines:
          SIGNED_MODE: "1"
''';
      final config = loader.parse(yaml, '/proj/simcrux.yaml');

      expect(config.schemaVersion, equals('1'));
      expect(config.defaultSimulatorId, equals('icarus'));
      expect(config.defaultWaveform?.format, equals(WaveformFormat.fst));
      expect(
        config.defaultWaveform?.capture,
        equals(WaveformCapturePolicy.onFailure),
      );
      expect(config.defaultPassFail, isA<ExitCodePassFailConfig>());

      expect(config.suites, hasLength(1));
      final suite = config.suites.single;
      expect(suite.name, equals('unit'));
      expect(suite.tests, hasLength(2));

      final alu = suite.tests.first;
      expect(alu.name, equals('alu_basic'));
      expect(alu.top, equals('alu_tb'));
      expect(alu.simulatorId, equals('icarus'));
      expect(alu.sources, equals(<String>['rtl/cpu.v', 'tb/unit/alu_tb.v']));
      expect(alu.timeout, equals(const Duration(seconds: 300)));

      final signed = suite.tests.last;
      expect(signed.defines, equals(<String, String>{'SIGNED_MODE': '1'}));
    });

    test('test-level overrides win over suite and project defaults', () {
      const yaml = '''
version: "1"
defaults:
  simulator: verilator
  timeout: 600s

suites:
  cpu_unit:
    simulator: icarus
    timeout: 120s
    tests:
      - name: alu
        top: tb_alu
      - name: long_running
        top: tb_long
        timeout: 1800s
        simulator: ghdl
''';
      final config = loader.parse(yaml, '/p.yaml');
      final tests = config.suites.single.tests;

      expect(tests[0].simulatorId, equals('icarus'));
      expect(tests[0].timeout, equals(const Duration(seconds: 120)));
      expect(tests[1].simulatorId, equals('ghdl'));
      expect(tests[1].timeout, equals(const Duration(seconds: 1800)));
    });

    test('parses string_match / regex / composite pass_fail', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s1:
    pass_fail:
      type: string_match
      pass_string: "TEST PASSED"
      fail_string: "FATAL"
    tests:
      - name: t1
        top: tb1
      - name: t2
        top: tb2
        pass_fail:
          type: regex
          pass_pattern: "^OK"
      - name: t3
        top: tb3
        pass_fail:
          type: composite
          all_of:
            - { type: exit_code }
            - { type: string_match, pass_string: "PASSED" }
''';
      final config = loader.parse(yaml, '/p.yaml');
      final tests = config.suites.single.tests;

      final t1 = tests[0].passFail as StringMatchPassFailConfig;
      expect(t1.passString, equals('TEST PASSED'));
      expect(t1.failString, equals('FATAL'));

      final t2 = tests[1].passFail as RegexPassFailConfig;
      expect(t2.passPattern, equals('^OK'));

      final t3 = tests[2].passFail as CompositePassFailConfig;
      expect(t3.allOf, hasLength(2));
      expect(t3.allOf.first, isA<ExitCodePassFailConfig>());
      expect(t3.allOf.last, isA<StringMatchPassFailConfig>());
    });

    test('parses uvm_report pass_fail with default thresholds', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s1:
    pass_fail:
      type: uvm_report
    tests:
      - name: t1
        top: tb1
''';
      final config = loader.parse(yaml, '/p.yaml');
      final pf =
          config.suites.single.tests.single.passFail as UvmReportPassFailConfig;
      expect(pf.fatalThreshold, 1);
      expect(pf.errorThreshold, 1);
      expect(pf.warningThreshold, isNull);
    });

    test('parses simulators.ghdl.options.backend into options map', () {
      const yaml = '''
version: "1"
defaults:
  simulator: ghdl
simulators:
  ghdl:
    source: system
    options:
      backend: llvm
  cocotb:
    source: system
    options:
      sim: verilator
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = loader.parse(yaml, '/p.yaml');
      expect(config.simulatorBinaries['ghdl']?.options['backend'], 'llvm');
      expect(config.simulatorBinaries['cocotb']?.options['sim'], 'verilator');
    });

    test('parses uvm_report pass_fail with explicit thresholds', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s1:
    tests:
      - name: t1
        top: tb1
        pass_fail:
          type: uvm_report
          fatal_threshold: 0
          error_threshold: 5
          warning_threshold: 100
''';
      final config = loader.parse(yaml, '/p.yaml');
      final pf =
          config.suites.single.tests.single.passFail as UvmReportPassFailConfig;
      expect(pf.fatalThreshold, 0);
      expect(pf.errorThreshold, 5);
      expect(pf.warningThreshold, 100);
    });

    test('parameter sweeps build deterministic test ids', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  cpu:
    tests:
      - name: alu
        top: tb_alu
        parameters:
          MEM_SIZE: "1024"
          MODE: "fast"
''';
      final config = loader.parse(yaml, '/p.yaml');
      final test = config.suites.single.tests.single;
      // Map keys are sorted alphabetically in the id.
      expect(test.id, equals('cpu/alu+MEM_SIZE=1024+MODE=fast'));
    });

    test('suite sources and defines merge into test sources and defines', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  cpu:
    sources:
      - rtl/cpu.sv
    include_dirs:
      - rtl/include
    defines:
      SIM: "1"
    tests:
      - name: t1
        top: tb1
        sources:
          - tb/t1.sv
        defines:
          ENABLE_X: "1"
''';
      final config = loader.parse(yaml, '/p.yaml');
      final test = config.suites.single.tests.single;
      expect(test.sources, equals(<String>['rtl/cpu.sv', 'tb/t1.sv']));
      expect(test.includeDirs, equals(<String>['rtl/include']));
      expect(
        test.defines,
        equals(<String, String>{'SIM': '1', 'ENABLE_X': '1'}),
      );
    });

    test('reads simulators section', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus

simulators:
  icarus:
    source: bundled
  verilator:
    source: system
  custom_sim:
    source: custom
    path: /opt/custom/sim
    env:
      LIC_FILE: "/etc/lic"

suites:
  s:
    tests:
      - name: t
        top: tb
''';
      // `path:` / `env:` are project-defined tooling, refused by the
      // default loader — this case is about the PARSER, so it uses a
      // loader the user has trusted. The gate itself is
      // `config_loader_project_tooling_test.dart`.
      final config = ConfigLoader(
        allowProjectDefinedTooling: true,
      ).parse(yaml, '/p.yaml');
      expect(
        config.simulatorBinaries['icarus']?.source,
        equals(SimulatorBinarySource.bundled),
      );
      expect(
        config.simulatorBinaries['verilator']?.source,
        equals(SimulatorBinarySource.system),
      );
      final custom = config.simulatorBinaries['custom_sim'];
      expect(custom?.source, equals(SimulatorBinarySource.custom));
      expect(custom?.customPath, equals('/opt/custom/sim'));
      expect(
        custom?.extraEnv,
        equals(<String, String>{'LIC_FILE': '/etc/lic'}),
      );
    });

    test('resources lock list parses', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  hil:
    resources: ['fpga_board_0']
    tests:
      - name: t
        top: tb
        resources: ['xilinx_license']
''';
      final config = loader.parse(yaml, '/p.yaml');
      final test = config.suites.single.tests.single;
      final names = test.resources.map((r) => r.name).toList();
      expect(names, containsAll(<String>['fpga_board_0', 'xilinx_license']));
    });
  });

  group('ConfigLoader.parse — error reporting', () {
    test('reports missing version with span', () {
      const yaml = '''
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(ex.errors, hasLength(1));
      expect(ex.errors.single.message, contains('version'));
    });

    test('reports unsupported schema version with span', () {
      const yaml = '''
version: "2"
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      final err = ex.errors.firstWhere(
        (e) => e.message.contains('Unsupported schema version'),
      );
      expect(err.line, equals(1));
      // Column is 1-based and points at the `version:` line.
      expect(err.column, isNotNull);
    });

    test('reports YAML syntax error with span', () {
      // Mismatched quote / unterminated string is an unambiguous lexer
      // failure that the yaml package surfaces via YamlException.
      const yaml = 'version: "1\nsuites: {}';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(ex.errors, hasLength(1));
      expect(ex.errors.single.message, contains('YAML parse error'));
    });

    test('reports missing tests list', () {
      const yaml = '''
version: "1"
suites:
  s:
    sources: ['x.v']
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('Suite `s` must declare a `tests` list')),
      );
    });

    test('reports each missing required test field', () {
      const yaml = '''
version: "1"
suites:
  s:
    tests:
      - name: only_name
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      // Missing `top` should be flagged.
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('Missing required field `top`')),
      );
    });

    test('reports unknown pass_fail.type with span', () {
      const yaml = '''
version: "1"
suites:
  s:
    pass_fail:
      type: bogus_type
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      final err = ex.errors.firstWhere((e) => e.message.contains('bogus_type'));
      expect(err.line, isNotNull);
    });

    test('reports unknown waveform.capture value', () {
      const yaml = '''
version: "1"
defaults:
  waveform:
    capture: sometimes
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('sometimes')),
      );
    });

    test('reports test without any resolvable simulator', () {
      const yaml = '''
version: "1"
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      // No defaults.simulator and no suite/test simulator either —
      // the test should be rejected.
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('has no simulator')),
      );
    });

    test('reports invalid duration', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  timeout: "tenseconds"
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('invalid duration')),
      );
    });

    test('accepts integer seconds as duration', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  timeout: 42
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = loader.parse(yaml, '/p.yaml');
      expect(
        config.suites.single.tests.single.timeout,
        equals(const Duration(seconds: 42)),
      );
    });

    test('rejects custom-sourced simulator without path', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus

simulators:
  weird:
    source: custom

suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('requires a `path`')),
      );
    });

    test('parse accepts empty suites (validated by load() after merging)', () {
      // The "at least one suite" rule lives in load(), not parse(),
      // so include-only
      // files can declare just `defaults:` or `simulators:` without
      // forcing the user to invent a stub suite.
      const yaml = '''
version: "1"
suites: {}
''';
      final config = loader.parse(yaml, '/p.yaml');
      expect(config.suites, isEmpty);
    });

    test('rejects non-map root', () {
      const yaml = '"just a string"';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      expect(ex.errors.single.message, contains('root must be a YAML map'));
    });

    test('all parse errors accumulated, not fail-fast', () {
      const yaml = '''
version: "2"
suites:
  s:
    pass_fail:
      type: bogus
    tests:
      - name: t
''';
      final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
      // We expect at least three errors: bad version, bad pass_fail
      // type, and missing `top` on the test.
      expect(ex.errors.length, greaterThanOrEqualTo(3));
    });

    // An unquoted number is an int to YAML. These four fields were read
    // with `as String?`, so `pass_string: 200` threw a TypeError out of
    // the loader: no file, no line, and on the CLI an uncaught exception
    // instead of a diagnostic.
    group('a detector string field given a non-string', () {
      String detector(String type, String key, String value) =>
          '''
version: "1"
defaults:
  simulator: icarus
  pass_fail:
    type: $type
    $key: $value
suites:
  s:
    tests:
      - name: t
        top: tb
''';

      for (final (type, key) in const <(String, String)>[
        ('string_match', 'pass_string'),
        ('string_match', 'fail_string'),
        ('regex', 'pass_pattern'),
        ('regex', 'fail_pattern'),
      ]) {
        test('$type.$key: 200 is a load error at the value, not a crash', () {
          final ex = _captureException(
            () => loader.parse(detector(type, key, '200'), '/p.yaml'),
          );
          // One diagnostic: the "requires at least one of" follow-on would
          // only repeat the problem without its line.
          expect(ex.errors, hasLength(1));
          final err = ex.errors.single;
          expect(err.path, '/p.yaml');
          expect(
            err.message,
            contains('`defaults.pass_fail.$key` must be a string, got int'),
          );
          // The fix, quoting what the user typed.
          expect(err.message, contains("`$key: '200'`"));
          // Line 6 is `    $key: 200`; the span starts at the value, after
          // four spaces of indent, the key, and `: `.
          expect(err.line, 6);
          expect(err.column, 4 + key.length + 2 + 1);
        });
      }

      test('a list is reported with its type and no quoting hint', () {
        final ex = _captureException(
          () => loader.parse(
            detector('string_match', 'pass_string', '[a, b]'),
            '/p.yaml',
          ),
        );
        expect(
          ex.errors.single.message,
          '`defaults.pass_fail.pass_string` must be a string, got list.',
        );
      });

      test('the hint quotes the source text, not the parsed number', () {
        final ex = _captureException(
          () => loader.parse(
            detector('string_match', 'pass_string', '0x10'),
            '/p.yaml',
          ),
        );
        expect(ex.errors.single.message, contains("`pass_string: '0x10'`"));
      });

      test('inside a composite child the label is `pass_fail`', () {
        const yaml = '''
version: "1"
defaults:
  simulator: icarus
  pass_fail:
    type: composite
    all_of:
      - type: regex
        fail_pattern: 404
suites:
  s:
    tests:
      - name: t
        top: tb
''';
        final ex = _captureException(() => loader.parse(yaml, '/p.yaml'));
        expect(
          ex.errors.map((e) => e.message),
          anyElement(
            contains('`pass_fail.fail_pattern` must be a string, got int'),
          ),
        );
        expect(ex.errors.first.line, 8);
      });

      test('a quoted number still loads as text', () {
        final config = loader.parse(
          detector('string_match', 'pass_string', "'200'"),
          '/p.yaml',
        );
        final passFail = config.defaultPassFail! as StringMatchPassFailConfig;
        expect(passFail.passString, '200');
      });
    });
  });

  group('ConfigLoader.load — file I/O', () {
    test('reads via injected readFile and forwards to parse', () async {
      final injected = ConfigLoader(
        readFile: (_) async => '''
version: "1"
suites:
  s:
    simulator: icarus
    tests:
      - name: t
        top: tb
''',
      );
      final config = await injected.load('/anywhere/simcrux.yaml');
      expect(config.suites.single.tests.single.simulatorId, equals('icarus'));
    });

    test('load() normalizes path to absolute', () async {
      late String capturedPath;
      final injected = ConfigLoader(
        readFile: (filePath) async {
          capturedPath = filePath;
          return '''
version: "1"
suites:
  s:
    simulator: icarus
    tests:
      - name: t
        top: tb
''';
        },
      );
      await injected.load('relative/path.yaml');
      expect(p.isAbsolute(capturedPath), isTrue);
      expect(capturedPath, endsWith(p.join('relative', 'path.yaml')));
    });
  });
}

ConfigLoaderException _captureException(void Function() body) {
  try {
    body();
    fail('Expected ConfigLoaderException');
  } on ConfigLoaderException catch (e) {
    return e;
  }
}
