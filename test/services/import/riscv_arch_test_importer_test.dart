// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/riscv_arch_test_importer.dart';

// Enumerate up front, one test per job. The job model has no
// fan-out — one TestSpec yields exactly one TestExecutionFinished and one
// TestResult — so the N-results-per-RISCOF-invocation mismatch is resolved
// HERE, before the scheduler, following the FuseSoCImporter precedent:
// read an external ecosystem's format, emit inspectable SimCrux YAML the
// user owns.
//
// The load-bearing assertion in this file is the round trip: the emitted
// YAML is fed to the REAL ConfigLoader and must produce one TestSpec per
// architectural test, each carrying its extension tag. An importer that
// emits config the loader rejects (the `top:` trap) is worse than no
// importer.

/// In-memory tree: directory path → child paths.
class _FakeTree {
  _FakeTree(this.dirs, [this.files = const <String, String>{}]);

  final Map<String, List<String>> dirs;
  final Map<String, String> files;

  List<String> list(String dir) => dirs[dir] ?? const <String>[];
  bool isDir(String path) => dirs.containsKey(path);
  String read(String path) {
    final contents = files[path];
    if (contents == null) throw StateError('no file at $path');
    return contents;
  }
}

/// Matches `key: <path>` in emitted YAML, quoted or not.
///
/// The importer runs every scalar through its own YAML quoter, and a Windows
/// path contains a drive colon — so `suite_path` comes out quoted on Windows
/// and bare on POSIX. Both are correct YAML for the same value; matching with
/// an optional quote keeps the assertion about WHERE the suite is pinned
/// without duplicating the emitter's escaping rules in the test.
Matcher _yamlPins(String key, String hostPath) =>
    contains(RegExp("$key: '?${RegExp.escape(hostPath)}'?"));

void main() {
  // Absolute ON THE HOST: `/checkout` is absolute on POSIX but not on
  // Windows, where the importer's absolutisation produced `D:\checkout` and
  // the fake tree — keyed on the literal — reported "Not a directory".
  final root = p.join(p.rootPrefix(p.current), 'checkout');
  final suiteRoot = p.join(root, RiscvArchTestImporter.kSuiteSubdir);
  // Host-absolute for the same reason `root` is: importDemo absolutises, and
  // `/corpus` is not an absolute path on Windows.
  final corpus = p.join(p.rootPrefix(p.current), 'corpus');

  RiscvArchTestImporter importerFor(_FakeTree tree) => RiscvArchTestImporter(
    listDirectory: tree.list,
    directoryExists: tree.isDir,
    readFile: tree.read,
  );

  _FakeTree archTestTree() {
    final rv32 = p.join(suiteRoot, 'rv32i_m');
    final i = p.join(rv32, 'I');
    final m = p.join(rv32, 'M');
    final iSrc = p.join(i, 'src');
    final mSrc = p.join(m, 'src');
    return _FakeTree(
      {
        root: [suiteRoot],
        suiteRoot: [rv32],
        rv32: [i, m],
        i: [iSrc],
        m: [mSrc],
        iSrc: <String>[],
        mSrc: <String>[],
      }..addAll({
        iSrc: [
          p.join(iSrc, 'add-01.S'),
          p.join(iSrc, 'sub-01.S'),
          p.join(iSrc, 'README.md'),
        ],
        mSrc: [p.join(mSrc, 'mul-01.S')],
      }),
    );
  }

  const targetDefaults = RiscvConfig(
    isa: 'rv32imc',
    target: RiscvTargetConfig(
      command: ['./mycore', '--elf', '{elf}', '--signature', '{signature}'],
    ),
  );

  Future<int> loadTestCount(RiscvImportResult result) async {
    final loader = ConfigLoader(
      readFile: (_) async => result.simcruxYaml,
      // The importer's output carries `riscv.target.command`, which the
      // default loader refuses as project-defined tooling. These cases
      // are about what the importer emits; the gate itself is
      // `test/services/config/config_loader_project_tooling_test.dart`.
      allowProjectDefinedTooling: true,
    );
    final config = await loader.load('/proj/simcrux.yaml');
    return config.suites.fold<int>(0, (a, s) => a + s.tests.length);
  }

  group('importSuite', () {
    test('emits one test per .S file, tagged with its extension', () {
      final result = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults);
      expect(result.testCount, 3);
      expect(result.extensions, ['I', 'M']);
      expect(result.simcruxYaml, contains('extension: I'));
      expect(result.simcruxYaml, contains('extension: M'));
      expect(result.simcruxYaml, contains('name: add-01'));
      expect(result.simcruxYaml, contains('name: mul-01'));
    });

    test('ignores non-.S files in a src directory', () {
      final yaml = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults).simcruxYaml;
      expect(yaml, isNot(contains('README')));
    });

    test('synthesizes a top: for every test — it is mandatory', () {
      // An architectural test has no HDL top level, and the loader rejects
      // a test without `top:`. An importer that omits it produces config
      // that cannot load.
      final yaml = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults).simcruxYaml;
      expect('top:'.allMatches(yaml).length, 3);
      expect(yaml, contains('top: add-01'));
    });

    test('pins arch_test.suite_path to the scanned root', () {
      // `riscv.test` is emitted relative to this, so the driver resolves an
      // absolute path with no cwd dependence.
      final yaml = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults).simcruxYaml;
      expect(yaml, _yamlPins('suite_path', suiteRoot));
      expect(yaml, contains('test: rv32i_m/I/src/add-01.S'));
    });

    test('emits the golden_compare detector alongside the riscv block', () {
      // The detector config is self-contained and never sees the `riscv:`
      // block. With `profile: riscv_signature` and no explicit paths it
      // resolves to exactly what the driver writes — so the importer emits
      // both halves together and they agree by convention.
      final yaml = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults).simcruxYaml;
      expect(yaml, contains('type: golden_compare'));
      expect(yaml, contains('profile: riscv_signature'));
      expect(yaml, contains('simulator: ${RiscvConfig.kSimulatorId}'));
    });

    test('restricts to the requested extensions', () {
      final result = importerFor(archTestTree()).importSuite(
        suitePath: root,
        defaults: targetDefaults,
        extensions: ['M'],
      );
      expect(result.extensions, ['M']);
      expect(result.testCount, 1);
    });

    test('warns when no target command was supplied', () {
      final result = importerFor(archTestTree()).importSuite(suitePath: root);
      expect(
        result.warnings.map((w) => w.code),
        contains('missing_target_command'),
      );
      // Warnings are echoed into the file so the user has a record.
      expect(result.simcruxYaml, contains('missing_target_command'));
    });

    test('refuses a path that is not a directory', () {
      expect(
        () => importerFor(_FakeTree(const {})).importSuite(suitePath: root),
        throwsA(isA<RiscvImportException>()),
      );
    });

    test('refuses a directory with no architectural tests', () {
      final empty = _FakeTree({root: <String>[]});
      expect(
        () => importerFor(empty).importSuite(suitePath: root),
        throwsA(
          isA<RiscvImportException>().having(
            (e) => e.message,
            'message',
            contains('No architectural tests found'),
          ),
        ),
      );
    });

    test('warns but proceeds without the riscv-test-suite subdirectory', () {
      final i = p.join(root, 'I');
      final iSrc = p.join(i, 'src');
      final tree = _FakeTree({
        root: [i],
        i: [iSrc],
        iSrc: [p.join(iSrc, 'add-01.S')],
      });
      final result = importerFor(
        tree,
      ).importSuite(suitePath: root, defaults: targetDefaults);
      expect(result.testCount, 1);
      expect(result.warnings.map((w) => w.code), contains('no_suite_subdir'));
    });

    test('the emitted YAML loads through the real ConfigLoader', () async {
      final result = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults);
      expect(await loadTestCount(result), result.testCount);
    });

    test('every loaded spec carries its extension and test path', () async {
      final result = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults);
      final loader = ConfigLoader(
        readFile: (_) async => result.simcruxYaml,
        // The importer's output carries `riscv.target.command`, which the
        // default loader refuses as project-defined tooling. These cases
        // are about what the importer emits; the gate itself is
        // `test/services/config/config_loader_project_tooling_test.dart`.
        allowProjectDefinedTooling: true,
      );
      final config = await loader.load('/proj/simcrux.yaml');
      final specs = config.suites.expand((s) => s.tests).toList();
      expect(specs, hasLength(3));
      for (final spec in specs) {
        expect(spec.riscv, isNotNull, reason: spec.id);
        expect(spec.riscv!.extension, isNotNull);
        expect(spec.riscv!.testPath, isNotNull);
        expect(spec.riscv!.isa, 'rv32imc', reason: 'defaults inherited');
        expect(spec.simulatorId, RiscvConfig.kSimulatorId);
      }
      expect(
        specs.map((s) => s.riscv!.extension).toSet(),
        {'I', 'M'},
      );
    });

    test('one TestSpec per architectural test — no fan-out anywhere', () async {
      // One test per job, restated as an assertion: enumeration happens here, and
      // downstream every spec is exactly one job, one finish event and one
      // result.
      final result = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults);
      expect(await loadTestCount(result), 3);
    });
  });

  group('importDemo', () {
    _FakeTree corpusTree() {
      final clean = p.join(corpus, 'clean_pass');
      final missing = p.join(corpus, 'missing_dut');
      return _FakeTree(
        {
          corpus: [clean, missing],
          clean: <String>[],
          missing: <String>[],
        },
        {
          p.join(clean, 'case.json'):
              '{"dut": "dut.sig", "reference": "golden.sig"}',
          p.join(missing, 'case.json'):
              '{"dut": "dut.sig", "reference": "golden.sig", '
              '"extension": "M"}',
        },
      );
    }

    test('emits one test per case directory in demo mode', () {
      final result = importerFor(
        corpusTree(),
      ).importDemo(demoSignaturesPath: corpus);
      expect(result.testCount, 2);
      expect(result.simcruxYaml, contains('mode: demo'));
      expect(result.simcruxYaml, contains('demo_case: clean_pass'));
      expect(result.simcruxYaml, contains('demo_case: missing_dut'));
    });

    test('reads an extension tag from case.json, else falls back', () {
      final result = importerFor(
        corpusTree(),
      ).importDemo(demoSignaturesPath: corpus);
      // The `golden_compare` corpus carries no extension key — those cases exercise
      // comparison semantics, not ISA coverage — so the fallback applies.
      expect(result.extensions, containsAll(<String>['I', 'M']));
    });

    test(
      'the emitted demo YAML loads and needs no toolchain plumbing',
      () async {
        final result = importerFor(
          corpusTree(),
        ).importDemo(demoSignaturesPath: corpus);
        final loader = ConfigLoader(
          readFile: (_) async => result.simcruxYaml,
          // The importer's output carries `riscv.target.command`, which the
          // default loader refuses as project-defined tooling. These cases
          // are about what the importer emits; the gate itself is
          // `test/services/config/config_loader_project_tooling_test.dart`.
          allowProjectDefinedTooling: true,
        );
        final config = await loader.load('/proj/simcrux.yaml');
        final specs = config.suites.expand((s) => s.tests).toList();
        expect(specs, hasLength(2));
        for (final spec in specs) {
          expect(spec.riscv!.effectiveMode, RiscvRunMode.demo);
          expect(spec.riscv!.demoSignatures, isNotNull);
          expect(spec.riscv!.demoCase, isNotNull);
          // No target command, no cross-compiler, no reference model — and
          // the loader accepts it, which is what makes demo mode usable on a
          // conference laptop and on a CI runner.
          expect(spec.riscv!.validateForRun(), isEmpty);
        }
      },
    );

    test('refuses an empty corpus', () {
      expect(
        () => importerFor(
          _FakeTree({corpus: <String>[]}),
        ).importDemo(demoSignaturesPath: corpus),
        throwsA(isA<RiscvImportException>()),
      );
    });
  });

  group("the output is the user's, not a hidden mapping", () {
    test('carries a provenance header naming the source', () {
      final yaml = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults).simcruxYaml;
      expect(yaml, contains('# Generated by the SimCrux RISC-V arch-test'));
      expect(yaml, contains('# Source: $suiteRoot'));
      expect(yaml, contains('read it, diff it, edit it, commit it'));
    });

    test('explains why enumeration happens up front', () {
      final yaml = importerFor(
        archTestTree(),
      ).importSuite(suitePath: root, defaults: targetDefaults).simcruxYaml;
      expect(yaml, contains('One test per architectural test'));
    });

    test('suggests the canonical project filename', () {
      expect(
        importerFor(
          archTestTree(),
        ).importSuite(suitePath: root).suggestedOutputFilename,
        'simcrux.yaml',
      );
    });
  });
}
