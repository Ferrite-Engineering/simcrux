// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/riscv_formal_check_importer.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';

// The enumeration step (one test per job, applied to bounded proofs;
// VERIFICATION_GUIDE.md §18.3).
//
// The load-bearing property is that **there is no fan-out anywhere
// downstream**: one `.sby` job becomes one `TestSpec`, which becomes one
// `TestExecutionFinished` and one `TestResult`. If the importer ever
// emitted one test for a whole check set, the dashboard would show a
// single row that either passed or failed for an hour.
//
// MUTATION: emit one test for the whole directory and the "one test per
// bounded proof" test fails.

/// Maps a host path back to the POSIX key the fake trees below are written in.
///
/// The importer absolutises its input before it reaches the seams, so on
/// Windows `/core/checks` arrives as `D:\core\checks` — matching nothing in a
/// tree keyed on POSIX strings. That is why all seventeen tests in this file
/// failed with "Not a directory" the first time this repo's Windows leg ever
/// ran. Translating at the seam keeps the fixtures readable POSIX on every
/// platform, instead of rewriting two dozen keys into host form.
String _posixKey(String hostPath) {
  final withoutRoot = hostPath.substring(p.rootPrefix(hostPath).length);
  return '/${p.split(withoutRoot).join('/')}';
}

/// The host-shaped form of a POSIX fixture path — the inverse of [_posixKey].
///
/// The importer writes the ABSOLUTISED directory into its emitted YAML, so
/// assertions on that YAML have to expect the host's spelling of it, not the
/// `/core/checks` the fixture was written with.
String _hostPath(String posixPath) =>
    p.joinAll([p.rootPrefix(p.current), ...p.posix.split(posixPath).skip(1)]);

/// Matches `key: <path>` in emitted YAML, quoted or not.
///
/// The importers run every scalar through their own YAML quoter, and a Windows
/// path contains a drive colon — so `checks_dir` comes out as
/// `checks_dir: 'D:\core\checks'` on Windows and bare `checks_dir:
/// /core/checks` on POSIX. Both are correct YAML for the same value. Matching
/// with an optional quote keeps the assertion about WHERE the directory is
/// pinned, which is the point, without duplicating the emitter's escaping
/// rules in the test and coupling the two.
Matcher _yamlPins(String key, String posixPath) =>
    contains(RegExp("$key: '?${RegExp.escape(_hostPath(posixPath))}'?"));

void main() {
  const bmcJob = '''
[options]
mode bmc
depth 20

[engines]
smtbmc boolector

[script]
read -formal democore.v

[files]
democore.v
''';

  const proveJobWithTasks = '''
[tasks]
basecase
induction

[options]
mode prove
depth 16

[engines]
smtbmc boolector
''';

  RiscvFormalCheckImporter importerOver(Map<String, String> tree) {
    final dirs = <String>{};
    for (final path in tree.keys) {
      var dir = path;
      while (dir.contains('/')) {
        dir = dir.substring(0, dir.lastIndexOf('/'));
        dirs.add(dir);
      }
    }
    return RiscvFormalCheckImporter(
      listDirectory: (hostDir) {
        final dir = _posixKey(hostDir);
        return <String>{
          ...tree.keys.where(
            (k) =>
                k.startsWith('$dir/') &&
                !k.substring(dir.length + 1).contains('/'),
          ),
          ...dirs.where(
            (d) =>
                d.startsWith('$dir/') &&
                !d.substring(dir.length + 1).contains('/'),
          ),
        }.toList()..sort();
      },
      readFile: (path) =>
          tree[_posixKey(path)] ?? (throw StateError('no fixture for $path')),
      directoryExists: (dir) => dirs.contains(_posixKey(dir)),
    );
  }

  group('enumeration — one test per bounded proof', () {
    late RiscvImportResult result;

    setUp(() {
      result = importerOver({
        '/core/checks/insn_add_ch0.sby': bmcJob,
        '/core/checks/insn_sub_ch0.sby': bmcJob,
        '/core/checks/reg_ch0.sby': bmcJob,
        '/core/checks/pc_fwd_ch0.sby': bmcJob,
        '/core/checks/genchecks.py': '# not a job file',
      }).importChecks(checksPath: '/core/checks');
    });

    test('every .sby becomes exactly one test', () {
      expect(result.testCount, 4);
      expect(RegExp('- name:').allMatches(result.simcruxYaml), hasLength(4));
    });

    test('non-.sby files in the directory are ignored', () {
      expect(result.simcruxYaml, isNot(contains('genchecks')));
    });

    test('checks are grouped by property family', () {
      expect(result.extensions, ['insn', 'pc_fwd', 'reg']);
      expect(result.simcruxYaml, contains('  insn:'));
      expect(result.simcruxYaml, contains('  pc_fwd:'));
    });

    test('every emitted test carries a synthesized top:', () {
      // `top:` is mandatory and a bounded proof has no HDL top level of
      // SimCrux's choosing, so the check name stands in. An importer that
      // omitted it would emit config the loader refuses.
      expect(RegExp('top:').allMatches(result.simcruxYaml), hasLength(4));
    });

    test('the checks directory is pinned absolutely', () {
      // `sby` is spawned there, so the run must not depend on the process
      // cwd.
      expect(
        result.simcruxYaml,
        _yamlPins('checks_dir', '/core/checks'),
      );
    });

    test('a core directory containing checks/ is accepted too', () {
      final fromCore = importerOver({
        '/core/checks/reg_ch0.sby': bmcJob,
      }).importChecks(checksPath: '/core');
      expect(fromCore.testCount, 1);
      expect(
        fromCore.simcruxYaml,
        _yamlPins('checks_dir', '/core/checks'),
      );
    });

    test('groups: restricts the import', () {
      final only = importerOver({
        '/core/checks/insn_add_ch0.sby': bmcJob,
        '/core/checks/reg_ch0.sby': bmcJob,
      }).importChecks(checksPath: '/core/checks', groups: ['reg']);
      expect(only.testCount, 1);
      expect(only.simcruxYaml, contains('reg_ch0'));
      expect(only.simcruxYaml, isNot(contains('insn_add_ch0')));
    });
  });

  group('a multi-task .sby becomes one test per task', () {
    late RiscvImportResult result;

    setUp(() {
      result = importerOver({
        '/core/checks/pc_fwd_ch0.sby': proveJobWithTasks,
      }).importChecks(checksPath: '/core/checks');
    });

    test('both tasks are emitted', () {
      // One invocation over all tasks would print several `DONE (…)`
      // lines into one result row — exactly the fan-out one-test-per-job prevents.
      expect(result.testCount, 2);
      expect(result.simcruxYaml, contains('task: basecase'));
      expect(result.simcruxYaml, contains('task: induction'));
    });

    test('the expansion is reported as a warning, not done silently', () {
      expect(result.warnings.single.code, 'multi_task_sby');
      expect(result.simcruxYaml, contains('[multi_task_sby]'));
    });

    test('both tests point at the same job file', () {
      expect(
        RegExp('sby_file: pc_fwd_ch0.sby').allMatches(result.simcruxYaml),
        hasLength(2),
      );
    });
  });

  group('the detector it emits', () {
    test('is string_match on the parser own pass marker', () {
      // Agreement by construction: the driver classifies from the same
      // literal, so the two halves cannot drift. A required pass string
      // that never appears is a FAIL by the detector's documented
      // semantics — never an `unknown` that would fall back to the
      // driver's exit code.
      final result = importerOver({
        '/core/checks/reg_ch0.sby': bmcJob,
      }).importChecks(checksPath: '/core/checks');
      expect(result.simcruxYaml, contains('type: string_match'));
      expect(
        result.simcruxYaml,
        contains("pass_string: '${SbyLogReader.kPassMarker}'"),
      );
    });

    test('the emitted simulator id is the formal driver', () {
      final result = importerOver({
        '/core/checks/reg_ch0.sby': bmcJob,
      }).importChecks(checksPath: '/core/checks');
      expect(
        result.simcruxYaml,
        contains('simulator: ${RiscvFormalDriver.kId}'),
      );
    });
  });

  group('the emitted YAML is real config', () {
    test('it loads through the real ConfigLoader', () {
      final result = importerOver({
        '/core/checks/insn_add_ch0.sby': bmcJob,
        '/core/checks/reg_ch0.sby': bmcJob,
      }).importChecks(checksPath: '/core/checks');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/proj/simcrux.yaml',
      );
      expect(config.suites, hasLength(2));
      final test = config.suites
          .firstWhere((s) => s.name == 'insn')
          .tests
          .single;
      expect(test.simulatorId, RiscvFormalDriver.kId);
      expect(test.riscv!.formal!.check, 'insn_add_ch0');
      expect(test.riscv!.formal!.sbyFile, 'insn_add_ch0.sby');
      expect(_posixKey(test.riscv!.formal!.checksDir!), '/core/checks');
      expect(test.riscv!.formal!.group, 'insn');
    });

    test('it carries a provenance header the user can read', () {
      final result = importerOver({
        '/core/checks/reg_ch0.sby': bmcJob,
      }).importChecks(checksPath: '/core/checks');
      expect(result.simcruxYaml, startsWith('#'));
      expect(
        result.simcruxYaml,
        contains('Source: ${_hostPath('/core/checks')}'),
      );
      expect(result.simcruxYaml, contains('This file is yours'));
    });
  });

  group('demo import', () {
    test('each case directory becomes one test', () {
      final result = importerOver({
        '/corpus/insn_add_pass/case.json':
            '{"check": "insn_add_ch0", "group": "insn"}',
        '/corpus/reg_timeout/case.json': '{"check": "reg_ch0", "group": "reg"}',
      }).importDemo(demoOutputsPath: '/corpus');
      expect(result.testCount, 2);
      expect(result.simcruxYaml, contains('mode: demo'));
      expect(
        result.simcruxYaml,
        _yamlPins('demo_outputs', '/corpus'),
      );
      expect(result.simcruxYaml, contains('demo_case: insn_add_pass'));
      expect(result.simcruxYaml, contains('check: insn_add_ch0'));
    });

    test('the demo config loads with no SymbiYosys plumbing at all', () {
      final result = importerOver({
        '/corpus/insn_add_pass/case.json':
            '{"check": "insn_add_ch0", "group": "insn"}',
      }).importDemo(demoOutputsPath: '/corpus');
      final config = ConfigLoader().parse(
        result.simcruxYaml,
        '/proj/simcrux.yaml',
      );
      final test = config.suites.single.tests.single;
      expect(_posixKey(test.riscv!.formal!.demoOutputs!), '/corpus');
      expect(test.riscv!.formal!.checksDir, isNull);
      expect(test.riscv!.formal!.sbyFile, isNull);
    });

    test('a case with no readable manifest still imports', () {
      final result = importerOver({
        '/corpus/mystery/notes.txt': 'nothing useful',
      }).importDemo(demoOutputsPath: '/corpus');
      expect(result.testCount, 1);
      expect(result.simcruxYaml, contains('check: mystery'));
    });
  });

  group('wrong paths fail loudly', () {
    test('a directory that is not a check set', () {
      expect(
        () => importerOver({
          '/core/README.md': '',
        }).importChecks(checksPath: '/core'),
        throwsA(
          isA<RiscvImportException>().having(
            (e) => e.message,
            'message',
            contains('genchecks.py'),
          ),
        ),
      );
    });

    test('a path that is not a directory at all', () {
      expect(
        () => importerOver(
          const {},
        ).importChecks(checksPath: '/nope'),
        throwsA(isA<RiscvImportException>()),
      );
    });

    test('an empty demo corpus', () {
      expect(
        () => importerOver({
          '/corpus/readme.txt': '',
        }).importDemo(demoOutputsPath: '/corpus'),
        throwsA(isA<RiscvImportException>()),
      );
    });
  });
}
