// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// A fake project root that is absolute ON THE HOST.
///
/// `/proj` is absolute on POSIX but not on Windows, where the loader's own
/// absolutisation turns `/proj/simcrux.yaml` into `D:\proj\simcrux.yaml`.
/// That matched no fixture key, so every test in this file died with
/// "Bad state: no fixture for D:\proj\simcrux.yaml" — a path bug wearing a
/// fixture bug's error message. Deriving the root from the host's own root
/// prefix keeps the fixtures readable AND makes the expected resolved paths
/// correct on all three platforms.
final String _projRoot = p.join(p.rootPrefix(p.current), 'proj');
final String _projYaml = p.join(_projRoot, 'simcrux.yaml');

// The `riscv:` block through the real loader.
//
// Two things here are load-bearing beyond ordinary schema coverage:
//
//  1. **FOUR inheritance levels**, not three: include file → project
//     `defaults:` → suite → test. Miss one and a per-test `riscv:` silently
//     ignores that level. Each level gets its own assertion, and the
//     all-four-at-once test is the regression guard.
//  2. **No tier gate, ever** — including at `LicenseTier.openCore` with
//     `kBetaPeriod = false`, which is the configuration a post-flip
//     unlicensed build runs in. The loader's `_parameterizationUnlocked`
//     gate covers `seeds:`/`parameters:` and must never grow an analogue
//     here: the compatibility verdict is correctness, and correctness is
//     free.
//
// MUTATION: delete any one of the four `_readRiscvConfig` call sites and
// the matching level test fails while the others still pass — which is how
// you tell they are really independent.

void main() {
  const targetBlock = '''
    target:
      command: ['./mycore', '--elf', '{elf}', '--signature', '{signature}']
''';

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
      (loader ?? loaderWith()).parse(yaml, _projYaml);

  TestSpec onlyTest(RegressionConfig config) =>
      config.suites.single.tests.single;

  group('four-level inheritance', () {
    test('level 2 — project defaults reach the test', () {
      final config = parse('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    isa: rv32imc
    mode: demo
    demo_signatures: corpus
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
''');
      final riscv = onlyTest(config).riscv!;
      expect(riscv.isa, 'rv32imc');
      expect(riscv.effectiveMode, RiscvRunMode.demo);
      expect(riscv.demoSignatures, 'corpus');
      // Retained on the config for the dashboard's "what was the default?"
      // display, exactly like the other three defaults.
      expect(config.defaultRiscv!.isa, 'rv32imc');
    });

    test('level 3 — a suite overrides the project default', () {
      final config = parse('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    isa: rv32i
    mode: demo
    demo_signatures: corpus
suites:
  arch:
    riscv:
      isa: rv32imc
      extension: M
    tests:
      - name: mul-01
        top: mul-01
''');
      final riscv = onlyTest(config).riscv!;
      expect(riscv.isa, 'rv32imc', reason: 'suite won');
      expect(riscv.extension, 'M');
      expect(riscv.demoSignatures, 'corpus', reason: 'project default kept');
    });

    test('level 4 — a test overrides the suite', () {
      final config = parse('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: corpus
suites:
  arch:
    riscv:
      extension: I
    tests:
      - name: mul-01
        top: mul-01
        riscv:
          extension: M
          test: rv32i_m/M/src/mul-01.S
''');
      final riscv = onlyTest(config).riscv!;
      expect(riscv.extension, 'M');
      expect(riscv.testPath, 'rv32i_m/M/src/mul-01.S');
      expect(riscv.demoSignatures, 'corpus');
    });

    test('level 1 — an including file seeds the included one', () async {
      final loader = loaderWith(
        files: {
          _projYaml: '''
version: '1'
includes:
  - suites.yaml
defaults:
  simulator: riscv_arch
  riscv:
    isa: rv32imc
    mode: demo
    demo_signatures: corpus
''',
          'suites.yaml': '''
version: '1'
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
        riscv:
          extension: I
''',
        },
      );
      final config = await loader.load(_projYaml);
      final riscv = config.suites.single.tests.single.riscv!;
      // The included file declared no `defaults.riscv` at all, so every one
      // of these came down the include seam.
      expect(riscv.isa, 'rv32imc');
      expect(riscv.effectiveMode, RiscvRunMode.demo);
      // Rooted at the ROOT project file's directory, the way `sources:`
      // and `include_dirs:` already are — `load()` resolves demo-corpus
      // paths, `parse()` (the sync core the other level tests use) does
      // not. See the `demo-corpus paths resolve` group below.
      expect(riscv.demoSignatures, p.join(_projRoot, 'corpus'));
      expect(riscv.extension, 'I');
    });

    test('all four levels compose in one config', () async {
      final loader = loaderWith(
        files: {
          _projYaml: '''
version: '1'
includes:
  - suites.yaml
defaults:
  simulator: riscv_arch
  riscv:
    isa: rv32imc
    mode: demo
    demo_signatures: corpus
    signature:
      word_size: 8
''',
          'suites.yaml': '''
version: '1'
defaults:
  riscv:
    signature:
      word_size: 4
suites:
  arch:
    riscv:
      extension: I
    tests:
      - name: add-01
        top: add-01
        riscv:
          test: rv32i_m/I/src/add-01.S
''',
        },
      );
      final config = await loader.load(_projYaml);
      final riscv = config.suites.single.tests.single.riscv!;
      expect(riscv.isa, 'rv32imc', reason: 'level 1 (include seam)');
      expect(
        riscv.signature!.wordSize,
        4,
        reason: "level 2 (the included file's own defaults) overrode level 1",
      );
      expect(riscv.extension, 'I', reason: 'level 3 (suite)');
      expect(riscv.testPath, 'rv32i_m/I/src/add-01.S', reason: 'level 4');
    });

    test('nested blocks merge rather than replace across levels', () {
      final config = parse('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: corpus
    reference:
      model: sail
      path: /opt/riscv/bin/riscv_sim_RV32
suites:
  arch:
    riscv:
      reference:
        model: spike
    tests:
      - name: add-01
        top: add-01
''');
      final reference = onlyTest(config).riscv!.reference!;
      expect(reference.model, RiscvReferenceModel.spike);
      // The suite switched only the model; the project's path survives,
      // which is what makes a suite-level model switch usable.
      expect(reference.path, '/opt/riscv/bin/riscv_sim_RV32');
    });
  });

  group('TestSpecExpander propagation', () {
    test('a swept child keeps its riscv block', () {
      final config = parse('''
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
        seeds: [1, 2, 3]
        riscv:
          extension: I
''');
      final tests = config.suites.single.tests;
      expect(tests, hasLength(3), reason: 'the seed sweep expanded');
      for (final spec in tests) {
        expect(
          spec.riscv?.extension,
          'I',
          reason: 'expansion must not drop the riscv: block',
        );
        expect(spec.riscv?.effectiveMode, RiscvRunMode.demo);
      }
    });
  });

  group('validation', () {
    List<ConfigLoaderError> errorsFrom(String yaml, {ConfigLoader? loader}) {
      try {
        parse(yaml, loader: loader);
        return const <ConfigLoaderError>[];
      } on ConfigLoaderException catch (e) {
        return e.errors;
      }
    }

    test('an unknown mode names the valid values', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv:
          mode: pretend
''');
      expect(errors, isNotEmpty);
      expect(errors.first.message, contains('normal'));
      expect(errors.first.message, contains('riscof_passthrough'));
      // The passthrough limitation is documented AT the config key, not
      // discovered by the user.
      expect(errors.first.message, contains('once per test'));
    });

    test('an unknown reference model names the valid values', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv:
          mode: demo
          demo_signatures: corpus
          reference:
            model: qemu
''');
      expect(errors.single.message, contains('sail, spike'));
    });

    test('a non-positive word_size is refused with a reason', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv:
          mode: demo
          demo_signatures: corpus
          signature:
            word_size: 0
''');
      expect(errors.single.message, contains('positive integer'));
      expect(errors.single.message, contains('byte offset'));
    });

    test('dut and reference pointing at one file is refused', () {
      // Same guard as `golden_compare`: it would compare a dump against
      // itself and always pass.
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv:
          mode: demo
          demo_signatures: corpus
          signature:
            dut: sig.txt
            reference: sig.txt
''');
      expect(errors.single.message, contains('always pass'));
    });

    test('errors accumulate — the whole punch list in one load', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv:
          mode: pretend
          reference:
            model: qemu
          signature:
            word_size: -4
''');
      expect(errors.length, greaterThanOrEqualTo(3));
    });

    test('every error carries a source span', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv:
          mode: pretend
''');
      expect(errors, isNotEmpty);
      for (final error in errors) {
        expect(error.line, isNotNull, reason: error.message);
        expect(error.column, isNotNull, reason: error.message);
      }
    });

    test('completeness is checked on the FLATTENED config', () {
      // `target.command` lives in defaults and `test:` per test — a
      // perfectly valid split that per-level validation would reject.
      expect(
        errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    isa: rv32imc
$targetBlock
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
        riscv:
          test: rv32i_m/I/src/add-01.S
'''),
        isEmpty,
      );
    });

    test('normal mode without a target command is refused', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
        riscv:
          test: rv32i_m/I/src/add-01.S
''');
      expect(errors.single.message, contains('riscv.target.command'));
      expect(errors.single.message, contains('arch/add-01'));
    });

    test('demo mode needs no toolchain plumbing whatsoever', () {
      expect(
        errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: verification/fixtures/golden_compare
suites:
  arch:
    tests:
      - name: clean_pass
        top: clean_pass
'''),
        isEmpty,
      );
    });

    test('a riscv block on a non-riscv_arch test is inert, not an error', () {
      // Completeness is scoped to tests that actually run under the driver;
      // an inherited block on an Icarus test is unused, not wrong.
      expect(
        errorsFrom('''
version: '1'
defaults:
  simulator: icarus
  riscv:
    isa: rv32imc
suites:
  arch:
    tests:
      - name: tb
        top: tb
        sources: [tb.v]
'''),
        isEmpty,
      );
    });

    test('a non-map riscv block is refused', () {
      final errors = errorsFrom('''
version: '1'
defaults:
  simulator: riscv_arch
suites:
  arch:
    tests:
      - name: t
        top: t
        riscv: nope
''');
      expect(errors.single.message, contains('must be a map'));
    });
  });

  group('no tier gate — deliberately, and forever', () {
    const yaml = '''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    isa: rv32imc
    mode: demo
    demo_signatures: corpus
    extensions: [I, M, C]
suites:
  arch:
    tests:
      - name: add-01
        top: add-01
        riscv:
          extension: I
''';

    test('open core, post-kBetaPeriod, produces the full block', () {
      // This is the exact configuration a post-flip unlicensed build runs
      // in. The compatibility verdict is RVI's own program; gating it would
      // read as tolling a standard.
      final config = parse(
        yaml,
        loader: loaderWith(betaPeriod: false),
      );
      final riscv = onlyTest(config).riscv!;
      expect(riscv.isa, 'rv32imc');
      expect(riscv.extension, 'I');
      expect(riscv.extensions, ['I', 'M', 'C']);
      expect(config.loadWarnings, isEmpty, reason: 'no gate ⇒ no advisory');
    });

    test('every tier produces an identical block', () {
      final blocks = <RiscvConfig?>[];
      for (final tier in LicenseTier.values) {
        for (final beta in [true, false]) {
          blocks.add(
            onlyTest(
              parse(
                yaml,
                loader: loaderWith(tier: tier, betaPeriod: beta),
              ),
            ).riscv,
          );
        }
      }
      expect(blocks.toSet(), hasLength(1));
    });

    test('the sweep gate still applies — the asymmetry is intentional', () {
      // Sanity check on the other side of the asymmetry: `seeds:` IS gated
      // post-beta at open core. If this ever stops being true the note
      // about the intentional asymmetry has gone stale.
      final config = parse('''
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
        seeds: [1, 2, 3]
''', loader: loaderWith(betaPeriod: false));
      expect(config.suites.single.tests, hasLength(1));
      expect(config.loadWarnings, isNotEmpty);
      // …and the riscv block came through anyway.
      expect(onlyTest(config).riscv?.effectiveMode, RiscvRunMode.demo);
    });
  });

  group('MixedLanguageValidator', () {
    test('riscv_arch is absent from the language catalog on purpose', () {
      // The catalog maps a simulator id to the HDL languages it COMPILES,
      // and riscv_arch compiles no HDL at all — it cross-compiles RISC-V
      // assembly. An empty set would flag every source; the HDL union would
      // be a lie. The validator's documented "skip unknown ids" branch is
      // the correct behavior.
      expect(
        ConfigLoader.defaultSimulatorLanguages.containsKey(
          RiscvConfig.kSimulatorId,
        ),
        isFalse,
      );
    });

    test('a riscv_arch test with sources is not flagged', () async {
      final loader = loaderWith(
        files: {
          _projYaml: '''
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
        sources: [env/model_test.h]
''',
        },
      );
      final config = await loader.load(_projYaml);
      expect(config.suites.single.tests, hasLength(1));
    });
  });

  // The demo corpora are directories in the user's project tree, and both
  // drivers consume the configured value as-is. A relative value that is
  // NOT resolved here resolves against the process working directory
  // instead — which is the repo root under `flutter test` and `/` for a
  // Finder-launched desktop build, so a config that passes CI would fail
  // for the user opening it from the app. That asymmetry is exactly what
  // makes it worth a test.
  //
  // MUTATION: drop the `riscv:` line from `_resolveTestPaths` and
  // `examples/riscv-*-demo/simcrux.yaml` stop opening in the GUI while
  // every other test still passes.
  group('demo-corpus paths resolve against the project file', () {
    Future<RegressionConfig> loadWith(String yaml) =>
        loaderWith(files: {_projYaml: yaml}).load(
          _projYaml,
        );

    test('`riscv.demo_signatures` is rooted at the config directory', () async {
      final config = await loadWith('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: ../fixtures/golden_compare
suites:
  arch:
    tests:
      - { name: add-01, top: add-01 }
''');
      // p.equals, not string equality: a YAML value like `/fixtures/x` is a
      // rooted-but-driveless path on Windows, which the loader resolves to
      // `D:\fixtures\x` (and elsewhere to `\fixtures\x`). Both name the same
      // place; p.equals canonicalises before comparing, string equality does
      // not, and the difference is not what this test is about.
      expect(
        p.equals(
          onlyTest(config).riscv!.demoSignatures!,
          '/fixtures/golden_compare',
        ),
        isTrue,
        reason: 'got ${onlyTest(config).riscv!.demoSignatures}',
      );
    });

    test('`riscv.formal.demo_outputs` is too — a separate key', () async {
      final config = await loadWith('''
version: '1'
defaults:
  simulator: riscv_formal
  riscv:
    mode: demo
    formal:
      demo_outputs: fixtures/riscv_formal
suites:
  formal:
    tests:
      - { name: insn_add_ch0, top: insn_add_ch0 }
''');
      expect(
        onlyTest(config).riscv!.formal!.demoOutputs,
        p.join(_projRoot, 'fixtures', 'riscv_formal'),
      );
    });

    test('an absolute corpus path is left alone', () async {
      final config = await loadWith('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: /opt/corpora/golden_compare
suites:
  arch:
    tests:
      - { name: add-01, top: add-01 }
''');
      // p.equals, not string equality: a YAML value like `/fixtures/x` is a
      // rooted-but-driveless path on Windows, which the loader resolves to
      // `D:\fixtures\x` (and elsewhere to `\fixtures\x`). Both name the same
      // place; p.equals canonicalises before comparing, string equality does
      // not, and the difference is not what this test is about.
      expect(
        p.equals(
          onlyTest(config).riscv!.demoSignatures!,
          '/opt/corpora/golden_compare',
        ),
        isTrue,
        reason: 'got ${onlyTest(config).riscv!.demoSignatures}',
      );
    });

    test('nothing else in the block is rewritten', () async {
      // Install locations stay verbatim (rewriting them would change
      // engine detection, which is deliberately detect-and-guide), and so do
      // the placeholder-bearing fields —
      // pre-resolving `{elf}` into `/proj/{elf}` would corrupt the argv.
      final config = await loadWith('''
version: '1'
defaults:
  simulator: riscv_arch
  riscv:
    mode: demo
    demo_signatures: corpus
    reference:
      path: bin/spike
    toolchain:
      path: bin
    arch_test:
      suite_path: third_party/riscv-arch-test
    compile:
      link_script: '{work_dir}/link.ld'
$targetBlock
suites:
  arch:
    tests:
      - { name: add-01, top: add-01 }
''');
      final riscv = onlyTest(config).riscv!;
      expect(riscv.demoSignatures, p.join(_projRoot, 'corpus'));
      expect(riscv.reference!.path, 'bin/spike');
      expect(riscv.toolchain!.path, 'bin');
      expect(riscv.archTest!.suitePath, 'third_party/riscv-arch-test');
      expect(riscv.compile!.linkScript, '{work_dir}/link.ld');
      expect(riscv.target!.command, contains('{elf}'));
    });
  });
}
