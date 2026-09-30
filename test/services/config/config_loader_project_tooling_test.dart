// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/riscv_toolchain_probe.dart';

/// The project-defined-tooling gate.
///
/// A `simcrux.yaml` is untrusted input. `.yaml` and `.yml` are registered
/// SimCrux document types (`macos/Runner/Info.plist`), so one arrives by
/// double-click, by `git clone`, or by download — and these of its keys
/// decide what SimCrux *executes*:
///
///   `simulators.<id>.path`  → `resolveBinary` → `Process.start`
///   `simulators.<id>.env`   → the child environment (`LD_PRELOAD`,
///                             `DYLD_INSERT_LIBRARIES`, `PATH`, …), which
///                             is code execution even against a legitimate
///                             simulator binary
///   `riscv.<target|riscof|compile|formal>.command`
///                           → `argv.first` becomes the executable in
///                             `riscv_arch_driver.dart` /
///                             `riscv_formal_driver.dart`
///   `riscv.reference.path`, `riscv.toolchain.path` / `.prefix`,
///   `riscv.riscof.binary`, `riscv.formal.sby_binary`
///                           → argv[0] of the reference model, the
///                             cross-compiler, RISCOF and SymbiYosys
///
/// The trigger is normally "press Run", but a user who turned on
/// `autoRunOnOpen` never presses anything. So the loader honors these
/// only when a human decided to trust project files on this machine —
/// the Settings → Simulators [kAllowProjectToolingControlLabel] switch,
/// or `--allow-project-tooling` on the CLI.
void main() {
  // Deny by default — the constructor takes no argument here on purpose.
  final denied = ConfigLoader();
  final allowed = ConfigLoader(allowProjectDefinedTooling: true);

  String simulatorsYaml(String body) =>
      '''
version: "1"
defaults:
  simulator: icarus
simulators:
$body
suites:
  s:
    tests:
      - name: t
        top: tb
''';

  group('simulators.<id>.path', () {
    const hostile = '''
  icarus:
    source: custom
    path: /tmp/pwn
''';

    test('is dropped, and the entry degrades to source=system', () {
      final config = denied.parse(simulatorsYaml(hostile), '/p.yaml');
      final icarus = config.simulatorBinaries['icarus'];
      expect(icarus, isNotNull);
      expect(icarus!.customPath, isNull);
      expect(icarus.source, SimulatorBinarySource.system);
    });

    test('drops with a load advisory naming the key and where to allow it', () {
      final config = denied.parse(simulatorsYaml(hostile), '/p.yaml');
      expect(config.loadWarnings, hasLength(1));
      final warning = config.loadWarnings.single;
      expect(warning.severity, ConfigLoaderErrorSeverity.warning);
      expect(warning.message, contains('`path`'));
      expect(warning.message, contains('icarus'));
      expect(warning.message, contains(kAllowProjectToolingControlLabel));
      // The advisory has to be clickable, like every other loader
      // diagnostic — it points at the offending node, not the file.
      expect(warning.line, isNotNull);
      expect(warning.column, isNotNull);
    });

    test('does NOT also report the "source=custom requires a path" error', () {
      // Degrading to `system` must not trip the completeness check for a
      // file that did supply a path; two diagnostics for one key would
      // bury the one that says why.
      final config = denied.parse(simulatorsYaml(hostile), '/p.yaml');
      expect(
        config.loadWarnings.map((e) => e.message),
        isNot(anyElement(contains('requires a `path`'))),
      );
    });

    test('an entry that never named a path still errors as before', () {
      final ex = _captureException(
        () => denied.parse(
          simulatorsYaml('''
  icarus:
    source: custom
'''),
          '/p.yaml',
        ),
      );
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('requires a `path` field')),
      );
    });

    test('is honored once the user has allowed project-defined tooling', () {
      final config = allowed.parse(simulatorsYaml(hostile), '/p.yaml');
      final icarus = config.simulatorBinaries['icarus'];
      expect(icarus!.customPath, '/tmp/pwn');
      expect(icarus.source, SimulatorBinarySource.custom);
      expect(config.loadWarnings, isEmpty);
    });
  });

  group('simulators.<id>.env', () {
    // `source: system` is the point: the binary is the user's own
    // `iverilog`, and the environment alone hijacks it.
    const preload = '''
  icarus:
    source: system
    env:
      LD_PRELOAD: ./pwn.so
''';
    const dyld = '''
  icarus:
    source: system
    env:
      DYLD_INSERT_LIBRARIES: ./pwn.dylib
''';

    test('LD_PRELOAD on a system-source simulator is dropped', () {
      final config = denied.parse(simulatorsYaml(preload), '/p.yaml');
      expect(config.simulatorBinaries['icarus']!.extraEnv, isEmpty);
      expect(config.loadWarnings.single.message, contains('`env`'));
    });

    test('DYLD_INSERT_LIBRARIES on a system-source simulator is dropped', () {
      final config = denied.parse(simulatorsYaml(dyld), '/p.yaml');
      expect(config.simulatorBinaries['icarus']!.extraEnv, isEmpty);
    });

    test('no allow-list: an innocuous-looking key is dropped too', () {
      // There is no safe subset of `env`. PATH re-points every bare
      // binary name; PYTHONPATH is import-time execution under cocotb.
      final config = denied.parse(
        simulatorsYaml('''
  icarus:
    source: system
    env:
      PATH: /tmp/evil/bin
      LM_LICENSE_FILE: "2100@lic"
'''),
        '/p.yaml',
      );
      expect(config.simulatorBinaries['icarus']!.extraEnv, isEmpty);
    });

    test('both keys at once are named in one advisory', () {
      final config = denied.parse(
        simulatorsYaml('''
  icarus:
    source: custom
    path: /tmp/pwn
    env:
      LD_PRELOAD: ./pwn.so
'''),
        '/p.yaml',
      );
      expect(config.loadWarnings, hasLength(1));
      expect(config.loadWarnings.single.message, contains('`path` and `env`'));
    });

    test('is honored once the user has allowed project-defined tooling', () {
      final config = allowed.parse(simulatorsYaml(preload), '/p.yaml');
      expect(
        config.simulatorBinaries['icarus']!.extraEnv,
        <String, String>{'LD_PRELOAD': './pwn.so'},
      );
    });
  });

  group('untouched keys', () {
    test('options: and source: alone raise no advisory', () {
      final config = denied.parse(
        simulatorsYaml('''
  verilator:
    source: system
    options:
      trace: "1"
'''),
        '/p.yaml',
      );
      expect(config.loadWarnings, isEmpty);
      expect(
        config.simulatorBinaries['verilator']!.options,
        <String, String>{'trace': '1'},
      );
    });
  });

  group('riscv.<stage>.command', () {
    String riscvYaml(String stage) =>
        '''
version: "1"
defaults:
  simulator: riscv_arch
  riscv:
    xlen: 32
    $stage:
      command: ["/tmp/pwn", "--now"]
suites:
  s:
    tests:
      - name: t
        top: tb
''';

    for (final stage in const <String>[
      'target',
      'riscof',
      'compile',
      'formal',
    ]) {
      test('$stage.command refuses the load outright', () {
        // An argv list is the most direct execution key in the schema:
        // `riscv_arch_driver` spawns `argv.first` verbatim. A dropped
        // command cannot run anyway, so this is a fatal error rather
        // than a drop-and-warn — one clear diagnostic, not two.
        final ex = _captureException(
          () => denied.parse(riscvYaml(stage), '/p.yaml'),
        );
        expect(
          ex.errors.map((e) => e.message),
          anyElement(contains('`defaults.riscv.$stage.command`')),
        );
        expect(
          ex.errors.map((e) => e.message),
          anyElement(contains(kAllowProjectToolingControlLabel)),
        );
      });

      test('$stage.command raises no gate error once tooling is allowed', () {
        // The fixture is deliberately minimal, so the RISC-V
        // completeness rules still reject it (`riscv.test` is missing).
        // What matters here is that the *gate* is silent.
        List<String> messages;
        try {
          allowed.parse(riscvYaml(stage), '/p.yaml');
          messages = const <String>[];
        } on ConfigLoaderException catch (e) {
          messages = e.errors.map((x) => x.message).toList();
        }
        expect(
          messages,
          isNot(anyElement(contains(kAllowProjectToolingControlLabel))),
        );
      });
    }

    test('the gate fires for a suite-level riscv block too', () {
      const yaml = '''
version: "1"
defaults:
  simulator: riscv_arch
suites:
  s:
    riscv:
      target:
        command: ["/tmp/pwn"]
    tests:
      - name: t
        top: tb
''';
      final ex = _captureException(() => denied.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`riscv.target.command`')),
      );
    });

    test('the gate fires for a test-level riscv block too', () {
      const yaml = '''
version: "1"
defaults:
  simulator: riscv_arch
suites:
  s:
    tests:
      - name: t
        top: tb
        riscv:
          target:
            command: ["/tmp/pwn"]
''';
      final ex = _captureException(() => denied.parse(yaml, '/p.yaml'));
      expect(
        ex.errors.map((e) => e.message),
        anyElement(contains('`riscv.target.command`')),
      );
    });

    test('a riscv block with no command: is untouched', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  riscv:
    xlen: 32
    isa: rv32i
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = denied.parse(yaml, '/p.yaml');
      expect(config.defaultRiscv?.isa, 'rv32i');
      expect(config.loadWarnings, isEmpty);
    });
  });

  // The keys that choose argv[0] without being a whole command. Before they
  // were gated, `riscv.formal.sby_binary` (and `formal.command`) loaded clean
  // with the gate closed and `RiscvFormalDriver.buildArgv` returned the
  // project's binary as the executable: the gate was bypassable by moving
  // the payload from `target.command` into the formal block.
  group('riscv executable paths', () {
    final cases = <(String, String, String? Function(RiscvConfig))>[
      ('reference', 'path', (r) => r.reference?.path),
      ('toolchain', 'path', (r) => r.toolchain?.path),
      ('toolchain', 'prefix', (r) => r.toolchain?.prefix),
      ('riscof', 'binary', (r) => r.riscof?.pythonBinary),
      ('formal', 'sby_binary', (r) => r.formal?.sbyBinary),
    ];

    // `simulator: icarus` keeps the riscv block inert, so nothing but the
    // gate can speak: the gate is applied as the block is read, whichever
    // driver ends up using it.
    String oneKey(String block, String key) =>
        '''
version: "1"
defaults:
  simulator: icarus
  riscv:
    $block:
      $key: /tmp/pwn
suites:
  s:
    tests:
      - name: t
        top: tb
''';

    for (final (block, key, read) in cases) {
      test('$block.$key is dropped with an advisory at its line', () {
        final config = denied.parse(oneKey(block, key), '/p.yaml');
        expect(read(config.defaultRiscv!), isNull);
        final warning = config.loadWarnings.single;
        expect(warning.severity, ConfigLoaderErrorSeverity.warning);
        expect(warning.message, contains('`defaults.riscv.$block.$key`'));
        expect(warning.message, contains(kAllowProjectToolingControlLabel));
        expect(warning.message, contains('--allow-project-tooling'));
        // Line 6 is `      $key: /tmp/pwn`; the span starts at the value.
        expect(warning.line, 6);
        expect(warning.column, 6 + key.length + 2 + 1);
      });

      test('$block.$key is honored once tooling is allowed', () {
        final config = allowed.parse(oneKey(block, key), '/p.yaml');
        expect(read(config.defaultRiscv!), '/tmp/pwn');
        expect(config.loadWarnings, isEmpty);
      });
    }

    test('every key dropped from one block is named in one advisory', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
  riscv:
    reference: { path: /tmp/a }
    toolchain: { path: /tmp, prefix: b- }
    formal: { sby_binary: /tmp/c }
suites:
  s:
    tests:
      - name: t
        top: tb
''';
      final config = denied.parse(yaml, '/p.yaml');
      expect(config.loadWarnings, hasLength(1));
      expect(
        config.loadWarnings.single.message,
        allOf(
          contains('`defaults.riscv.reference.path`'),
          contains('`defaults.riscv.toolchain.prefix`'),
          contains('`defaults.riscv.toolchain.path`'),
          contains('`defaults.riscv.formal.sby_binary`'),
        ),
      );
    });

    test('the gate fires at the test level too', () {
      const yaml = '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        riscv:
          formal:
            sby_binary: /tmp/pwn
''';
      final config = denied.parse(yaml, '/p.yaml');
      expect(
        config.suites.single.tests.single.riscv?.formal?.sbyBinary,
        isNull,
      );
      expect(
        config.loadWarnings.single.message,
        contains('`riscv.formal.sby_binary`'),
      );
    });

    // The bypass, end to end: what the driver would spawn.
    group('what riscv_formal would spawn', () {
      const formalYaml = '''
version: "1"
defaults:
  simulator: riscv_formal
suites:
  s:
    tests:
      - name: t
        top: t
        riscv:
          formal:
            sby_file: /checks/insn_add_ch0.sby
            sby_binary: /tmp/pwn
''';

      List<String> argvOf(RegressionConfig config) {
        final test = config.suites.single.tests.single;
        return RiscvFormalDriver().buildArgv(
          cfg: test.riscv!,
          workingDirectory: '/wd',
          testName: test.name,
        );
      }

      test('gate closed: the conventional sby, not the project binary', () {
        final argv = argvOf(denied.parse(formalYaml, '/p.yaml'));
        expect(argv.first, RiscvFormalConfig.kDefaultSbyBinary);
        expect(argv, isNot(contains('/tmp/pwn')));
      });

      test('gate open: the project binary', () {
        expect(argvOf(allowed.parse(formalYaml, '/p.yaml')).first, '/tmp/pwn');
      });

      test('formal.command with the gate closed does not load at all', () {
        final ex = _captureException(
          () => denied.parse(
            formalYaml.replaceFirst(
              'sby_binary: /tmp/pwn',
              'command: ["/tmp/pwn", "{sby_file}"]',
            ),
            '/p.yaml',
          ),
        );
        expect(
          ex.errors.map((e) => e.message),
          anyElement(contains('`riscv.formal.command`')),
        );
      });
    });

    test('riscv_arch resolves the default toolchain and reference model', () {
      // `mode: demo` loads with the gate closed (it needs no command) and
      // spawns nothing; the resolvers are what `mode: normal` would spawn.
      const yaml = '''
version: "1"
defaults:
  simulator: riscv_arch
suites:
  s:
    tests:
      - name: t
        top: t
        riscv:
          isa: rv32i
          mode: demo
          demo_signatures: /corpus
          reference: { path: /tmp/pwn-ref }
          toolchain: { path: /tmp, prefix: pwn- }
''';
      final riscv = denied
          .parse(yaml, '/p.yaml')
          .suites
          .single
          .tests
          .single
          .riscv!;
      const clean = RiscvConfig(isa: 'rv32i');
      expect(
        RiscvToolchainProbe.crossCompilerBinary(riscv),
        RiscvToolchainProbe.crossCompilerBinary(clean),
      );
      expect(
        RiscvToolchainProbe.referenceModelBinary(riscv),
        RiscvToolchainProbe.referenceModelBinary(clean),
      );
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
