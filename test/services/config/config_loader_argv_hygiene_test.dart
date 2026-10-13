// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// Project-file values that reach a simulator's argv or `make` without
/// choosing which binary runs.
///
/// The project-tooling gate (`config_loader_project_tooling_test.dart`)
/// covers the keys that pick argv[0] or the environment. These are the
/// neighbours that were left when it landed: text the file controls that a
/// simulator reads as a flag (`sources`), that `make` expands (cocotb's
/// options, `top` and `parameters`), that Verilator reads as a toolchain
/// choice (`options.args`), or that SymbiYosys reads as an option
/// (`formal.sby_file`, `formal.task`). None of them lets a project run a
/// binary it could not already run by being run, so the gated ones are
/// dropped with an advisory rather than failing the load, and the ones that
/// are never legitimate are refused whether tooling is allowed or not.
void main() {
  final denied = ConfigLoader();
  final allowed = ConfigLoader(allowProjectDefinedTooling: true);

  ConfigLoaderException captureError(ConfigLoader loader, String yaml) {
    try {
      loader.parse(yaml, '/p/simcrux.yaml');
    } on ConfigLoaderException catch (e) {
      return e;
    }
    fail('expected ConfigLoaderException');
  }

  group('sources: an entry that a simulator would read as a flag', () {
    String yaml(String entry) =>
        '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        sources:
          - $entry
''';

    test('a bare string beginning with - fails the load, with the remedy', () {
      final ex = captureError(denied, yaml('-CFLAGS'));
      final message = ex.errors.single.message;
      expect(message, contains('`-CFLAGS`'));
      expect(message, contains('flag'));
      expect(message, contains('./-CFLAGS'));
      expect(ex.errors.single.line, isNotNull);
    });

    test('the {path, language} form is held to the same rule', () {
      final ex = captureError(
        denied,
        yaml('{ path: --Mdir, language: verilog }'),
      );
      expect(ex.errors.single.message, contains('`--Mdir`'));
    });

    test('./-name is a file, and allowing tooling changes nothing here', () {
      for (final loader in <ConfigLoader>[denied, allowed]) {
        final config = loader.parse(yaml('./-odd.v'), '/p/simcrux.yaml');
        expect(config.suites.single.tests.single.sources, <String>['./-odd.v']);
      }
      expect(
        () => allowed.parse(yaml('-CFLAGS'), '/p/simcrux.yaml'),
        throwsA(isA<ConfigLoaderException>()),
        reason: 'a path is never a flag on purpose',
      );
    });
  });

  group('simulators.<id>.options while project tooling is denied', () {
    String yaml(String simulator, String options) =>
        '''
version: "1"
defaults:
  simulator: $simulator
simulators:
  $simulator:
    options:
$options
suites:
  s:
    tests:
      - name: t
        top: tb
''';

    test('a value make would expand is dropped with a warning', () {
      final config = denied.parse(
        yaml('cocotb', r'      sim: "icarus$(shell id > /tmp/pwned)"'),
        '/p/simcrux.yaml',
      );
      expect(config.simulatorBinaries['cocotb']!.options, isEmpty);
      final warning = config.loadWarnings.single;
      expect(warning.severity, ConfigLoaderErrorSeverity.warning);
      expect(warning.message, contains('`options.sim`'));
      expect(warning.message, contains('make expands'));
      expect(warning.message, contains(kAllowProjectToolingControlLabel));
      expect(warning.line, isNotNull);
    });

    test('a backtick is dropped the same way', () {
      final config = denied.parse(
        yaml('cocotb', '      sim: "`id`"'),
        '/p/simcrux.yaml',
      );
      expect(config.simulatorBinaries['cocotb']!.options, isEmpty);
      expect(config.loadWarnings.single.message, contains('backtick'));
    });

    test('a Verilator args list naming a build tool is dropped whole', () {
      final config = denied.parse(
        yaml('verilator', '      args: "-Wno-WIDTH -CFLAGS -include pwn.h"'),
        '/p/simcrux.yaml',
      );
      expect(config.simulatorBinaries['verilator']!.options, isEmpty);
      final warning = config.loadWarnings.single;
      expect(warning.severity, ConfigLoaderErrorSeverity.warning);
      expect(warning.message, contains('`-CFLAGS`'));
      expect(warning.message, contains('build tool'));
    });

    test('every flag on the deny-list is caught, including key=value', () {
      for (final flag in kVerilatorToolingFlags) {
        final config = denied.parse(
          yaml('verilator', '      args: "-O3 $flag=x"'),
          '/p/simcrux.yaml',
        );
        expect(
          config.simulatorBinaries['verilator']!.options,
          isEmpty,
          reason: '$flag must be refused',
        );
      }
    });

    test('plain simulation flags pass, and are kept beside a dropped one', () {
      final config = denied.parse(
        yaml(
          'verilator',
          '      args: "-Wno-WIDTH -O3 --no-timing"\n'
              r'      extra: "$(shell id)"',
        ),
        '/p/simcrux.yaml',
      );
      expect(
        config.simulatorBinaries['verilator']!.options,
        <String, String>{'args': '-Wno-WIDTH -O3 --no-timing'},
      );
      expect(config.loadWarnings, hasLength(1));
    });

    test('an allowed loader keeps every option and raises no advisory', () {
      final config = allowed.parse(
        yaml('verilator', r'      args: "-CFLAGS -O2 $(shell id)"'),
        '/p/simcrux.yaml',
      );
      expect(
        config.simulatorBinaries['verilator']!.options['args'],
        r'-CFLAGS -O2 $(shell id)',
      );
      expect(config.loadWarnings, isEmpty);
    });
  });

  group('cocotb top and parameters while project tooling is denied', () {
    String yaml({required String top, String parameters = ''}) =>
        '''
version: "1"
defaults:
  simulator: cocotb
suites:
  s:
    tests:
      - name: t
        top: $top
$parameters
''';

    test(r'a $(shell …) in top refuses the test, with the remedy', () {
      final ex = captureError(denied, yaml(top: r'"dff$(shell id)"'));
      final message = ex.errors.single.message;
      expect(message, contains('`top`'));
      expect(message, contains('make variable'));
      expect(message, contains(kAllowProjectToolingControlLabel));
    });

    test('a parameter value is held to the same rule, at its own line', () {
      final ex = captureError(
        denied,
        yaml(
          top: 'dff',
          parameters: '        parameters:\n          MODULE: "x\${shell id}"',
        ),
      );
      expect(ex.errors.single.message, contains('`parameters.MODULE`'));
      expect(ex.errors.single.line, isNotNull);
    });

    test('a swept value is checked too', () {
      final ex = captureError(
        denied,
        yaml(
          top: 'dff',
          parameters: '        parameters:\n          W: ["8", "`id`"]',
        ),
      );
      expect(ex.errors.single.message, contains('`parameters.W`'));
    });

    test(r'a Verilog identifier with $ in it is not refused', () {
      // `$` alone is a legal identifier character in Verilog and expands to
      // nothing in make; only `$(` and `${` reach a command.
      final config = denied.parse(yaml(top: r'top$x'), '/p/simcrux.yaml');
      expect(config.suites.single.tests.single.top, r'top$x');
    });

    test('an allowed loader takes the values as written', () {
      final config = allowed.parse(
        yaml(top: r'"dff$(shell id)"'),
        '/p/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.top, r'dff$(shell id)');
      expect(config.loadWarnings, isEmpty);
    });

    test('another simulator is not held to make rules', () {
      final config = denied.parse(
        yaml(top: r'"dff$(x)"').replaceAll('cocotb', 'icarus'),
        '/p/simcrux.yaml',
      );
      expect(config.suites.single.tests.single.top, r'dff$(x)');
    });
  });

  group('riscv.formal sby_file and task', () {
    String yaml({required String sbyFile, required String task}) =>
        '''
version: "1"
defaults:
  simulator: riscv_formal
  riscv:
    isa: rv32imc
    formal:
      checks_dir: cores/democore/checks
suites:
  formal:
    tests:
      - name: insn_add_ch0
        top: insn_add_ch0
        riscv:
          formal:
            check: insn_add_ch0
            sby_file: $sbyFile
            task: $task
''';

    test('a job file beginning with - is refused, allowed or not', () {
      for (final loader in <ConfigLoader>[denied, allowed]) {
        final ex = captureError(
          loader,
          yaml(sbyFile: '"-f"', task: 'basecase'),
        );
        expect(
          ex.errors.map((e) => e.message),
          anyElement(allOf(contains('sby_file'), contains('flag'))),
        );
      }
    });

    test('a task that is not an identifier is refused', () {
      for (final task in <String>['"-x"', '"base case"', '"a;b"']) {
        final ex = captureError(
          denied,
          yaml(sbyFile: 'insn_add_ch0.sby', task: task),
        );
        expect(
          ex.errors.map((e) => e.message),
          anyElement(contains('task name')),
          reason: '$task must be refused',
        );
      }
    });

    test('the documented shapes load', () {
      final config = denied.parse(
        yaml(sbyFile: './-odd.sby', task: 'basecase.v2-ch0'),
        '/p/simcrux.yaml',
      );
      final formal = config.suites.single.tests.single.riscv!.formal!;
      expect(formal.sbyFile, './-odd.sby');
      expect(formal.task, 'basecase.v2-ch0');
    });
  });
}
