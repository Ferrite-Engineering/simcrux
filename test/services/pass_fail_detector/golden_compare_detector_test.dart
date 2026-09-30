// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/golden_compare_detector.dart';

// The detector's whole job is a status. The interesting assertions are
// therefore about what it must NEVER return: `unknown` (which hands the
// verdict back to the driver — exit 0 ⇒ pass) and `vacuous` (which the
// scheduler treats as success and whose evidence work dir it deletes).
//
// MUTATION: change any `TestStatus.fail` below to `TestStatus.unknown`
// and a broken DUT starts reporting green — this file is what catches it.
void main() {
  const detector = GoldenCompareDetector();
  const canonical = 'deadbeef\n0000000f\n12345678\ncafebabe\n';

  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('simcrux_golden_');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  void write(String name, String contents) {
    File(p.join(workDir.path, name)).writeAsStringSync(contents);
  }

  Future<TestStatus> classify({
    String dut = 'dut.sig',
    String reference = 'golden.sig',
    GoldenCompareProfile? profile,
    String? workingDirectory,
    int? exitCode = 0,
  }) {
    return detector.detectAsync(
      stdout: '',
      stderr: '',
      exitCode: exitCode,
      runtime: Duration.zero,
      config: GoldenComparePassFailConfig(
        dutPath: dut,
        referencePath: reference,
        profile: profile ?? GoldenCompareProfile.riscvSignature,
      ),
      workingDirectory: workingDirectory ?? workDir.path,
    );
  }

  group('verdict', () {
    test('identical dumps pass', () async {
      write('dut.sig', canonical);
      write('golden.sig', canonical);
      expect(await classify(), TestStatus.pass);
    });

    test('a divergent word fails', () async {
      write('dut.sig', 'deadbeef\n0000000f\nffffffff\ncafebabe\n');
      write('golden.sig', canonical);
      expect(await classify(), TestStatus.fail);
    });

    test('a length divergence fails', () async {
      write('dut.sig', 'deadbeef\n0000000f\n');
      write('golden.sig', canonical);
      expect(await classify(), TestStatus.fail);
    });

    test('the profile is honored end to end', () async {
      write('dut.sig', '0XDEADBEEF\n0X0000000F\n0X12345678\n0XCAFEBABE\n');
      write('golden.sig', canonical);
      expect(
        await classify(profile: GoldenCompareProfile.riscvSignature),
        TestStatus.pass,
      );
      expect(
        await classify(profile: GoldenCompareProfile.generic),
        TestStatus.fail,
      );
    });
  });

  group('missing or empty — always fail, never unknown, never vacuous', () {
    test('missing DUT dump on an exit-0 run', () async {
      // The trap: a core that produced no output typically still exits 0,
      // so `unknown` here would become the driver's `pass`.
      write('golden.sig', canonical);
      final status = await classify();
      expect(status, TestStatus.fail);
      expect(status, isNot(TestStatus.unknown));
      expect(status, isNot(TestStatus.vacuous));
    });

    test('missing golden reference', () async {
      write('dut.sig', canonical);
      expect(await classify(), TestStatus.fail);
    });

    test('both files missing', () async {
      expect(await classify(), TestStatus.fail);
    });

    test('empty DUT dump', () async {
      write('dut.sig', '');
      write('golden.sig', canonical);
      final status = await classify();
      expect(status, TestStatus.fail);
      expect(status, isNot(TestStatus.vacuous));
    });

    test('whitespace-only DUT dump counts as empty', () async {
      write('dut.sig', '  \r\n\n\t\n');
      write('golden.sig', canonical);
      expect(await classify(), TestStatus.fail);
    });

    test('empty golden reference', () async {
      write('dut.sig', canonical);
      write('golden.sig', '');
      expect(await classify(), TestStatus.fail);
    });

    test('BOTH dumps empty is a failure, not a vacuous pass', () async {
      write('dut.sig', '');
      write('golden.sig', '');
      expect(await classify(), TestStatus.fail);
    });

    test(
      'a directory where a dump was expected fails, does not throw',
      () async {
        Directory(p.join(workDir.path, 'dut.sig')).createSync();
        write('golden.sig', canonical);
        expect(await classify(), TestStatus.fail);
      },
    );
  });

  group('path resolution', () {
    test('relative paths resolve against the working directory', () {
      expect(
        GoldenCompareDetector.resolvePath('sig/dut.sig', '/runs/t1'),
        p.join('/runs/t1', 'sig/dut.sig'),
      );
    });

    test('absolute paths pass through untouched', () {
      final absolute = p.join(workDir.path, 'golden.sig');
      expect(
        GoldenCompareDetector.resolvePath(absolute, '/somewhere/else'),
        absolute,
      );
    });

    test('a null or empty working directory leaves the path relative', () {
      expect(GoldenCompareDetector.resolvePath('dut.sig', null), 'dut.sig');
      expect(GoldenCompareDetector.resolvePath('dut.sig', ''), 'dut.sig');
    });

    test('an absolute golden outside the run tree is read', () async {
      final goldenRoot = Directory.systemTemp.createTempSync('simcrux_gold_');
      addTearDown(() => goldenRoot.deleteSync(recursive: true));
      final golden = File(p.join(goldenRoot.path, 'committed.sig'))
        ..writeAsStringSync(canonical);
      write('dut.sig', canonical);
      expect(await classify(reference: golden.path), TestStatus.pass);
    });

    test('a null working directory still fails rather than passing', () async {
      // Relative paths then resolve against the process CWD, where these
      // files do not exist. The answer must still be `fail`.
      expect(
        await classify(workingDirectory: ''),
        TestStatus.fail,
      );
    });
  });

  group('the synchronous entry point fails loudly', () {
    test('detect() throws instead of degrading to unknown', () {
      expect(
        () => detector.detect(
          stdout: '',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          config: GoldenComparePassFailConfig.forProfile(
            GoldenCompareProfile.riscvSignature,
          ),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('classifyAsync'), contains('silently report pass')),
          ),
        ),
      );
    });
  });

  test(
    'a mismatched config variant fails rather than returning unknown',
    () async {
      // A dispatch/wiring defect. `unknown` would hand the verdict to the
      // driver; refusing to pass is the safe answer.
      expect(
        await detector.detectAsync(
          stdout: '',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
          config: const ExitCodePassFailConfig(),
          workingDirectory: workDir.path,
        ),
        TestStatus.fail,
      );
    },
  );
}
