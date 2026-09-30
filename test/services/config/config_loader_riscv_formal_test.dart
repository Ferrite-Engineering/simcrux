// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';

// The `riscv.formal:` sub-block through the real loader
// (VERIFICATION_GUIDE.md §18.3).
//
// `config_loader_riscv_test.dart` pins the four inheritance levels for the
// `riscv:` block itself;
// what is load-bearing here is that a **second** driver shares that block
// without either one's rules leaking onto the other:
//
//  1. `formal:` merges field-by-field like every other sub-block, at all
//     four levels.
//  2. Completeness is scoped by `simulatorId`. A `riscv_arch` test never
//     has to declare `formal.sby_file`, a `riscv_formal` test never has to
//     declare `target.command`, and a block inherited onto some third
//     simulator is inert rather than wrong.
//  3. **Still no tier gate** — including at `LicenseTier.openCore` with
//     `kBetaPeriod = false`, which is what a post-flip unlicensed build
//     runs in.

void main() {
  ConfigLoader loaderWith({
    Map<String, String> files = const <String, String>{},
    LicenseTier tier = LicenseTier.openCore,
    bool betaPeriod = true,
  }) => ConfigLoader(
    readFile: (path) async {
      final match = files.entries.firstWhere(
        (e) => path.endsWith(e.key),
        orElse: () => throw StateError('no fixture for $path'),
      );
      return match.value;
    },
    licenseTier: tier,
    betaPeriod: betaPeriod,
    // `riscv.<stage>.command` is project-defined tooling, refused by
    // the default loader. This file is about the RISC-V block's parsing
    // and completeness rules, so it runs as a user who has trusted
    // project files; the gate itself is
    // `config_loader_project_tooling_test.dart`.
    allowProjectDefinedTooling: true,
  );

  RegressionConfig parse(String yaml, {ConfigLoader? loader}) =>
      (loader ?? loaderWith()).parse(yaml, '/proj/simcrux.yaml');

  TestSpec onlyTest(RegressionConfig config) =>
      config.suites.single.tests.single;

  group('reading the block', () {
    test('every key round-trips', () {
      final riscv = onlyTest(
        parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    isa: rv32imc
    formal:
      checks_dir: cores/democore/checks
      sby_binary: /opt/oss-cad-suite/bin/sby
      demo_outputs: verification/fixtures/riscv_formal
      command: ['sby', '-f', '-d', '{task_dir}', '{sby_file}']
suites:
  formal:
    tests:
      - name: insn_add_ch0
        top: insn_add_ch0
        riscv:
          formal:
            check: insn_add_ch0
            sby_file: insn_add_ch0.sby
            task: basecase
            group: insn
'''),
      ).riscv!;
      final formal = riscv.formal!;
      expect(formal.checksDir, 'cores/democore/checks');
      expect(formal.sbyBinary, '/opt/oss-cad-suite/bin/sby');
      expect(formal.demoOutputs, 'verification/fixtures/riscv_formal');
      expect(formal.command, ['sby', '-f', '-d', '{task_dir}', '{sby_file}']);
      expect(formal.check, 'insn_add_ch0');
      expect(formal.sbyFile, 'insn_add_ch0.sby');
      expect(formal.task, 'basecase');
      expect(formal.group, 'insn');
      expect(riscv.isa, 'rv32imc');
    });

    test('the sub-block merges field-by-field across levels', () {
      // A suite that switches only `checks_dir` keeps the project's
      // `sby_binary` — the same nesting rule every other `riscv:`
      // sub-block follows.
      final riscv = onlyTest(
        parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /a/checks
      sby_binary: /opt/sby
suites:
  formal:
    riscv:
      formal:
        checks_dir: /b/checks
    tests:
      - name: reg_ch0
        top: reg_ch0
        riscv:
          formal:
            check: reg_ch0
            sby_file: reg_ch0.sby
'''),
      ).riscv!;
      expect(riscv.formal!.checksDir, '/b/checks');
      expect(riscv.formal!.sbyBinary, '/opt/sby');
      expect(riscv.formal!.check, 'reg_ch0');
    });

    test('an included file supplies the fourth level', () {
      final loader = loaderWith(
        files: {
          'shared.yaml': '''
version: '1'
defaults:
  riscv:
    formal:
      sby_binary: /opt/oss-cad-suite/bin/sby
''',
        },
      );
      final config = loader.parse('''
version: '1'
include:
  - shared.yaml
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: reg_ch0
        top: reg_ch0
        riscv:
          formal:
            check: reg_ch0
            sby_file: reg_ch0.sby
''', '/proj/simcrux.yaml');
      // The include is resolved asynchronously; the synchronous parse
      // still has to leave the project's own values intact.
      expect(onlyTest(config).riscv!.formal!.checksDir, '/core/checks');
    });

    test('a swept child keeps its formal block', () {
      final config = parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: reg_ch0
        top: reg_ch0
        seeds: [1, 2, 3]
        riscv:
          formal:
            check: reg_ch0
            sby_file: reg_ch0.sby
''');
      final tests = config.suites.single.tests;
      expect(tests.length, greaterThan(1), reason: 'the sweep expanded');
      for (final test in tests) {
        expect(test.riscv!.formal!.sbyFile, 'reg_ch0.sby');
        expect(test.riscv!.formal!.checksDir, '/core/checks');
      }
    });
  });

  group('validation is scoped by driver id', () {
    test('a complete formal test loads clean', () {
      expect(
        () => parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: reg_ch0
        top: reg_ch0
        riscv:
          formal:
            check: reg_ch0
            sby_file: reg_ch0.sby
'''),
        returnsNormally,
      );
    });

    test('completeness is judged on the FLATTENED config', () {
      // Declaring `checks_dir` once in `defaults:` and only the per-test
      // coordinates per test is legitimate; per-level validation would
      // reject it.
      expect(
        () => parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: a
        top: a
        riscv:
          formal: { check: a, sby_file: a.sby }
      - name: b
        top: b
        riscv:
          formal: { check: b, sby_file: b.sby }
'''),
        returnsNormally,
      );
    });

    test('a missing sby_file is an error with a source span', () {
      Object? caught;
      try {
        parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: reg_ch0
        top: reg_ch0
''');
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), contains('riscv.formal.sby_file'));
      expect(caught.toString(), contains('simcrux.yaml'));
    });

    test('riscof_passthrough is refused for a formal test', () {
      Object? caught;
      try {
        parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    mode: riscof_passthrough
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: reg_ch0
        top: reg_ch0
        riscv:
          formal: { check: reg_ch0, sby_file: reg_ch0.sby }
''');
      } on Object catch (e) {
        caught = e;
      }
      expect(caught.toString(), contains('does not apply'));
    });

    test('a formal block on a riscv_arch test is inert, not an error', () {
      // The two drivers share the block; a sub-block the other one owns
      // must never be a load failure.
      expect(
        () => parse('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    formal:
      checks_dir: /core/checks
    target:
      command: ['./mycore', '{elf}', '{signature}']
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
        riscv:
          test: rv32i_m/I/src/add-01.S
'''),
        returnsNormally,
      );
    });

    test('a formal block on some third simulator is inert too', () {
      expect(
        () => parse('''
version: '1'
defaults:
  simulator: icarus
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  rtl:
    tests:
      - name: tb
        top: tb
        sources: [tb.v]
'''),
        returnsNormally,
      );
    });

    test('an arch test is never asked for formal keys', () {
      expect(
        () => parse('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: corpus
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
'''),
        returnsNormally,
      );
    });
  });

  group('malformed input accumulates errors, it does not throw first', () {
    test('`formal:` must be a map', () {
      Object? caught;
      try {
        parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal: nope
suites:
  formal:
    tests:
      - name: a
        top: a
''');
      } on Object catch (e) {
        caught = e;
      }
      expect(caught.toString(), contains('riscv.formal` must be a map'));
    });

    test('`formal.command` must be a list of strings', () {
      Object? caught;
      try {
        parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
      command: sby -f
suites:
  formal:
    tests:
      - name: a
        top: a
        riscv:
          formal: { check: a, sby_file: a.sby }
''');
      } on Object catch (e) {
        caught = e;
      }
      expect(
        caught.toString(),
        contains('riscv.formal.command` must be a list of strings'),
      );
    });
  });

  // `formal.check` names the task directory `sby -f -d` deletes and
  // recreates, joined onto the test's working directory. A value that is
  // not one plain path segment joins to somewhere else — `../..` climbs out,
  // and an absolute path replaces the work dir outright — and SymbiYosys
  // would delete that directory before it ran. None of this is project
  // tooling, so it is refused whatever the tooling gate says.
  group('`formal.check` is one path segment', () {
    // The value is spliced in as written, so each case chooses its own YAML
    // spelling (quoted where the shape needs an escape).
    String withCheck(String scalar) =>
        '''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: t
        top: t
        riscv:
          formal:
            sby_file: t.sby
            check: $scalar
''';

    // Line 15 is `            check: <value>`; the span starts at the
    // value, after 12 spaces of indent and `check: `.
    const checkLine = 15;
    const checkColumn = 12 + 'check: '.length + 1;

    List<ConfigLoaderError> errorsFrom(String yaml) {
      // The default loader: project tooling NOT allowed.
      final loader = ConfigLoader(readFile: (_) async => '');
      try {
        loader.parse(yaml, '/proj/simcrux.yaml');
        return const <ConfigLoaderError>[];
      } on ConfigLoaderException catch (e) {
        return e.errors;
      }
    }

    // Each shape, its YAML spelling, and the reason the message gives.
    const refused = <(String, String, String)>[
      ('parent', '..', 'working directory or its parent'),
      ('grandparent', '../..', 'path separator'),
      ('a climb through a subdirectory', 'sub/../..', 'path separator'),
      ('current directory', '.', 'working directory or its parent'),
      ('absolute POSIX path', '/Users/x/Documents', 'absolute path'),
      ('a forward-slash path', 'insn/add_ch0', 'path separator'),
      ('a backslash path', r'"insn\\add_ch0"', 'path separator'),
      ('absolute Windows path', r'"C:\\Users\\x"', 'absolute path'),
      ('a NUL byte', r'"insn\0add"', 'NUL byte'),
      ('empty', '""', 'non-empty string'),
    ];

    for (final (shape, scalar, reason) in refused) {
      test('$shape is refused at its line and column', () {
        final errors = errorsFrom(withCheck(scalar));
        final error = errors.singleWhere(
          (e) => e.message.contains('riscv.formal.check'),
          orElse: () => fail('loaded clean: `check: $scalar` was accepted'),
        );
        expect(error.line, checkLine, reason: error.message);
        expect(error.column, checkColumn, reason: error.message);
        expect(error.severity, ConfigLoaderErrorSeverity.error);
        expect(error.message, contains(reason));
      });
    }

    test('the message says why, and what to write instead', () {
      final message = errorsFrom(withCheck('../..')).single.message;
      expect(message, contains('`riscv.formal.check`'));
      expect(message, contains('"../.."'));
      expect(message, contains('single'));
      expect(message, contains('sby -f'));
    });

    test('allowing project tooling does not lift it', () {
      Object? caught;
      try {
        parse(withCheck('../..'));
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isA<ConfigLoaderException>());
      expect(caught.toString(), contains('riscv.formal.check'));
    });

    test('the rule applies at the defaults level too', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
      check: ../..
suites:
  formal:
    tests:
      - name: t
        top: t
        riscv:
          formal: { sby_file: t.sby }
''');
      final error = errors.singleWhere(
        (e) => e.message.contains('defaults.riscv.formal.check'),
      );
      expect(error.line, 7);
      expect(error.column, 14);
    });

    for (final name in const <String>[
      'insn_add_ch0',
      'reg_ch0',
      'pc_fwd_ch0',
      'csrw_mcycle_ch0',
      'cover_2',
      'insn_c.addi_ch0',
    ]) {
      test('$name loads unchanged', () {
        final config = ConfigLoader(
          readFile: (_) async => '',
        ).parse(withCheck(name), '/proj/simcrux.yaml');
        final formal = onlyTest(config).riscv!.formal!;
        expect(formal.check, name);
        expect(
          RiscvFormalDriver().taskDirectoryFor(onlyTest(config).riscv!, '/wd'),
          p.join('/wd', name),
        );
      });
    }
  });

  group('NO tier gate — deliberately, and forever', () {
    const yaml = '''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    formal:
      checks_dir: /core/checks
suites:
  formal:
    tests:
      - name: reg_ch0
        top: reg_ch0
        riscv:
          formal: { check: reg_ch0, sby_file: reg_ch0.sby, group: reg }
''';

    test('every tier x kBetaPeriod combination reads the block', () {
      // The loader's `_parameterizationUnlocked` gate covers `seeds:` /
      // `parameters:` and must never grow an analogue here. Sweeps are a
      // productivity feature and are Pro; a formal property's pass/fail
      // is correctness and is free.
      for (final tier in LicenseTier.values) {
        for (final beta in const [true, false]) {
          final config = parse(
            yaml,
            loader: loaderWith(tier: tier, betaPeriod: beta),
          );
          final formal = onlyTest(config).riscv!.formal!;
          expect(formal.check, 'reg_ch0', reason: '$tier / beta=$beta');
          expect(formal.group, 'reg', reason: '$tier / beta=$beta');
          expect(formal.checksDir, '/core/checks');
        }
      }
    });

    test('demo mode is equally ungated post-flip', () {
      final config = parse('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    mode: demo
    formal:
      demo_outputs: verification/fixtures/riscv_formal
suites:
  formal:
    tests:
      - name: insn_add_pass
        top: insn_add_pass
        riscv:
          demo_case: insn_add_pass
''', loader: loaderWith(betaPeriod: false));
      expect(onlyTest(config).riscv!.effectiveMode, RiscvRunMode.demo);
      expect(onlyTest(config).riscv!.demoCase, 'insn_add_pass');
    });
  });

  group('the mixed-language validator skips both RISC-V ids', () {
    test('riscv_formal is absent from the language catalog on purpose', () {
      // The catalog maps a simulator to the HDL it compiles. `sby` reads
      // HDL, but from the `.sby` file's own `[files]` section, not from
      // `sources:`. An empty set would flag every source; the HDL union
      // would be a lie.
      expect(
        ConfigLoader.defaultSimulatorLanguages.containsKey(
          RiscvConfig.kFormalSimulatorId,
        ),
        isFalse,
      );
      expect(
        ConfigLoader.defaultSimulatorLanguages.containsKey(
          RiscvConfig.kSimulatorId,
        ),
        isFalse,
      );
    });
  });
}
