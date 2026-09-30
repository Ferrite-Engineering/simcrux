// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/pass_fail_detector_registry.dart';

class _RecordingDetector implements PassFailDetector {
  _RecordingDetector(this._returns);
  final TestStatus _returns;
  int callCount = 0;

  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    callCount++;
    return _returns;
  }
}

void main() {
  group('PassFailDetectorRegistry', () {
    test('routes ExitCodePassFailConfig to the exit-code detector', () {
      final exit = _RecordingDetector(TestStatus.pass);
      final str = _RecordingDetector(TestStatus.fail);
      final registry = PassFailDetectorRegistry(
        exitCodeDetector: exit,
        stringMatchDetector: str,
      );
      final status = registry.classify(
        config: const ExitCodePassFailConfig(),
        stdout: '',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
      );
      expect(status, TestStatus.pass);
      expect(exit.callCount, 1);
      expect(str.callCount, 0);
    });

    test('routes StringMatchPassFailConfig to the string-match detector', () {
      final exit = _RecordingDetector(TestStatus.pass);
      final str = _RecordingDetector(TestStatus.fail);
      final registry = PassFailDetectorRegistry(
        exitCodeDetector: exit,
        stringMatchDetector: str,
      );
      final status = registry.classify(
        config: const StringMatchPassFailConfig(passString: 'OK'),
        stdout: '',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
      );
      expect(status, TestStatus.fail);
      expect(exit.callCount, 0);
      expect(str.callCount, 1);
    });

    test('routes RegexPassFailConfig to the regex detector', () {
      final regex = _RecordingDetector(TestStatus.pass);
      final registry = PassFailDetectorRegistry(regexDetector: regex);
      final status = registry.classify(
        config: const RegexPassFailConfig(passPattern: '.*OK.*'),
        stdout: 'OK',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
      );
      expect(status, TestStatus.pass);
      expect(regex.callCount, 1);
    });

    test('routes UvmReportPassFailConfig to the uvm-report detector', () {
      final uvm = _RecordingDetector(TestStatus.pass);
      final registry = PassFailDetectorRegistry(uvmReportDetector: uvm);
      final status = registry.classify(
        config: const UvmReportPassFailConfig(),
        stdout: 'UVM_INFO @ 0: hello',
        stderr: '',
        exitCode: 0,
        runtime: Duration.zero,
      );
      expect(status, TestStatus.pass);
      expect(uvm.callCount, 1);
    });

    test('composes UVM with exit_code via all_of (real detector dispatch)', () {
      const registry = PassFailDetectorRegistry();
      // Clean exit + clean UVM summary → composite pass.
      expect(
        registry.classify(
          config: CompositePassFailConfig(
            allOf: const [
              ExitCodePassFailConfig(),
              UvmReportPassFailConfig(),
            ],
          ),
          stdout: '''
--- UVM Report Summary ---
UVM_INFO : 1
UVM_WARNING : 0
UVM_ERROR : 0
UVM_FATAL : 0
''',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.pass,
      );
      // Clean exit but UVM_ERROR present → composite fail.
      expect(
        registry.classify(
          config: CompositePassFailConfig(
            allOf: const [
              ExitCodePassFailConfig(),
              UvmReportPassFailConfig(),
            ],
          ),
          stdout: '''
--- UVM Report Summary ---
UVM_INFO : 1
UVM_WARNING : 0
UVM_ERROR : 1
UVM_FATAL : 0
''',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.fail,
      );
    });

    test('classifies CompositePassFailConfig via nested children', () {
      const registry = PassFailDetectorRegistry();
      expect(
        registry.classify(
          config: CompositePassFailConfig(
            allOf: const [
              ExitCodePassFailConfig(),
              StringMatchPassFailConfig(passString: 'PASS'),
            ],
          ),
          stdout: 'banner\nPASS',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.pass,
      );
      expect(
        registry.classify(
          config: CompositePassFailConfig(
            anyOf: const [
              StringMatchPassFailConfig(passString: 'NEVER_HAPPENS'),
            ],
          ),
          stdout: 'irrelevant',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.fail,
      );
    });

    // AND/OR composite semantics — migrated from the deleted
    // composite_detector.dart's test when the standalone `CompositeDetector`
    // wrapper was removed (the registry inlines composite dispatch, so these
    // exercise the real production path).
    test('anyOf: at least one passing child wins', () {
      const registry = PassFailDetectorRegistry();
      expect(
        registry.classify(
          config: CompositePassFailConfig(
            anyOf: const [
              StringMatchPassFailConfig(passString: 'FOO'),
              StringMatchPassFailConfig(passString: 'BAR'),
            ],
          ),
          stdout: 'noise BAR more',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.pass,
      );
    });

    test('allOf + anyOf: both groups must hold', () {
      const registry = PassFailDetectorRegistry();
      final config = CompositePassFailConfig(
        allOf: const [ExitCodePassFailConfig()],
        anyOf: const [StringMatchPassFailConfig(passString: 'PASS')],
      );
      // Exit 0 + sees PASS ⇒ both hold ⇒ pass.
      expect(
        registry.classify(
          config: config,
          stdout: 'PASS',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.pass,
      );
      // Exit 1 ⇒ the allOf group fails the composite even though anyOf holds.
      expect(
        registry.classify(
          config: config,
          stdout: 'PASS',
          stderr: '',
          exitCode: 1,
          runtime: Duration.zero,
        ),
        TestStatus.fail,
      );
    });

    test('nested composite (composite inside allOf) recurses', () {
      const registry = PassFailDetectorRegistry();
      final outer = CompositePassFailConfig(
        allOf: [
          const ExitCodePassFailConfig(),
          CompositePassFailConfig(
            anyOf: const [
              StringMatchPassFailConfig(passString: 'FOO'),
              StringMatchPassFailConfig(passString: 'BAR'),
            ],
          ),
        ],
      );
      expect(
        registry.classify(
          config: outer,
          stdout: 'FOO',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.pass,
      );
      expect(
        registry.classify(
          config: outer,
          stdout: 'baz',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        TestStatus.fail,
      );
    });
  });

  group('PassFailDetectorRegistry.classifyAsync', () {
    const registry = PassFailDetectorRegistry();

    // The production scheduler path calls classifyAsync (regex leaves are
    // matched under an isolate deadline). For every non-pathological
    // config it must agree, bit-for-bit, with the synchronous classify —
    // otherwise routing the scheduler through it would flip verdicts.
    final cases = <(String, PassFailConfig, String, String, int?)>[
      ('exit-code pass', const ExitCodePassFailConfig(), '', '', 0),
      ('exit-code fail', const ExitCodePassFailConfig(), '', '', 1),
      (
        'string-match pass',
        const StringMatchPassFailConfig(passString: 'OK'),
        'banner\nOK',
        '',
        0,
      ),
      (
        'string-match fail',
        const StringMatchPassFailConfig(passString: 'OK'),
        'banner',
        '',
        0,
      ),
      (
        'regex fail wins',
        const RegexPassFailConfig(
          passPattern: 'PASS',
          failPattern: 'UVM_ERROR',
        ),
        'PASS\nUVM_ERROR : 1',
        '',
        0,
      ),
      (
        'regex required-pass downgrade',
        const RegexPassFailConfig(passPattern: 'PASS'),
        'nothing here',
        '',
        0,
      ),
      (
        'regex invalid pattern ⇒ unknown',
        const RegexPassFailConfig(failPattern: '('),
        'anything',
        '',
        0,
      ),
      (
        'uvm clean',
        const UvmReportPassFailConfig(),
        '--- UVM Report Summary ---\nUVM_ERROR : 0\nUVM_FATAL : 0',
        '',
        0,
      ),
      (
        'composite regex leaf in all_of',
        CompositePassFailConfig(
          allOf: const [
            ExitCodePassFailConfig(),
            RegexPassFailConfig(passPattern: 'DONE'),
          ],
        ),
        'DONE',
        '',
        0,
      ),
      (
        'composite regex leaf fails in any_of',
        CompositePassFailConfig(
          anyOf: const [RegexPassFailConfig(failPattern: 'BOOM')],
        ),
        'BOOM',
        '',
        0,
      ),
    ];

    for (final (name, config, stdout, stderr, exitCode) in cases) {
      test('agrees with sync classify: $name', () async {
        final sync = registry.classify(
          config: config,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: Duration.zero,
        );
        final async = await registry.classifyAsync(
          config: config,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: Duration.zero,
        );
        expect(async, sync);
      });
    }

    test('routes a non-default injected regex detector on the sync path', () {
      // A test-injected fake has no detectAsync; classifyAsync must still
      // honor it rather than throwing.
      final regex = _RecordingDetector(TestStatus.pass);
      final registry = PassFailDetectorRegistry(regexDetector: regex);
      expect(
        registry.classifyAsync(
          config: const RegexPassFailConfig(passPattern: '.*'),
          stdout: 'x',
          stderr: '',
          exitCode: 0,
          runtime: Duration.zero,
        ),
        completion(TestStatus.pass),
      );
      expect(regex.callCount, 1);
    });
    // ── golden_compare ────────────────────────────────────────────────
    //
    // The only filesystem-backed detector, and the only config the two
    // classification paths treat differently. The sync path MUST throw:
    // a silent `unknown` there becomes the driver's status, and an
    // exit-0 run that produced no output would be reported as a pass.
    group('golden_compare', () {
      late Directory workDir;

      setUp(() {
        workDir = Directory.systemTemp.createTempSync('simcrux_registry_');
        File(p.join(workDir.path, 'dut.sig')).writeAsStringSync('aa\nbb\n');
        File(p.join(workDir.path, 'golden.sig')).writeAsStringSync('aa\nbb\n');
      });

      tearDown(() {
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      });

      GoldenComparePassFailConfig config({String dut = 'dut.sig'}) =>
          GoldenComparePassFailConfig(
            dutPath: dut,
            referencePath: 'golden.sig',
            profile: GoldenCompareProfile.riscvSignature,
          );

      test('classifyAsync compares against the working directory', () async {
        const registry = PassFailDetectorRegistry();
        expect(
          await registry.classifyAsync(
            config: config(),
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
            workingDirectory: workDir.path,
          ),
          TestStatus.pass,
        );
        expect(
          await registry.classifyAsync(
            config: config(dut: 'nope.sig'),
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
            workingDirectory: workDir.path,
          ),
          TestStatus.fail,
        );
      });

      test('the synchronous classify() throws rather than degrading', () {
        const registry = PassFailDetectorRegistry();
        expect(
          () => registry.classify(
            config: config(),
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
          ),
          throwsA(isA<UnsupportedError>()),
        );
      });

      test(
        'a golden_compare leaf in a composite works on the async path',
        () async {
          const registry = PassFailDetectorRegistry();
          final composite = CompositePassFailConfig(
            allOf: [const ExitCodePassFailConfig(), config()],
          );
          expect(
            await registry.classifyAsync(
              config: composite,
              stdout: '',
              stderr: '',
              exitCode: 0,
              runtime: Duration.zero,
              workingDirectory: workDir.path,
            ),
            TestStatus.pass,
          );
          // ...and the leaf is really evaluated: break the DUT and the
          // composite must flip.
          final broken = CompositePassFailConfig(
            allOf: [
              const ExitCodePassFailConfig(),
              config(dut: 'nope.sig'),
            ],
          );
          expect(
            await registry.classifyAsync(
              config: broken,
              stdout: '',
              stderr: '',
              exitCode: 0,
              runtime: Duration.zero,
              workingDirectory: workDir.path,
            ),
            TestStatus.fail,
          );
        },
      );

      test('a nested composite still receives the working directory', () async {
        const registry = PassFailDetectorRegistry();
        final nested = CompositePassFailConfig(
          allOf: [
            CompositePassFailConfig(anyOf: [config()]),
          ],
        );
        expect(
          await registry.classifyAsync(
            config: nested,
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
            workingDirectory: workDir.path,
          ),
          TestStatus.pass,
        );
      });

      test('a composite leaf on the SYNC path throws, never degrades', () {
        // This is the regression the note above is about: sync composite
        // helpers recurse through classify(), so a nested leaf would
        // otherwise return `unknown` ⇒ driver status ⇒ silent pass.
        const registry = PassFailDetectorRegistry();
        final composite = CompositePassFailConfig(
          allOf: [const ExitCodePassFailConfig(), config()],
        );
        expect(
          () => registry.classify(
            config: composite,
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
          ),
          throwsA(isA<UnsupportedError>()),
        );
      });

      test('omitting workingDirectory fails rather than passing', () async {
        const registry = PassFailDetectorRegistry();
        expect(
          await registry.classifyAsync(
            config: config(),
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
          ),
          TestStatus.fail,
        );
      });

      test('honors a non-default injected detector on the sync path', () {
        final injected = _RecordingDetector(TestStatus.pass);
        final registry = PassFailDetectorRegistry(
          goldenCompareDetector: injected,
        );
        expect(
          registry.classifyAsync(
            config: config(),
            stdout: '',
            stderr: '',
            exitCode: 0,
            runtime: Duration.zero,
            workingDirectory: workDir.path,
          ),
          completion(TestStatus.pass),
        );
        expect(injected.callCount, 1);
      });
    });
  });
}
