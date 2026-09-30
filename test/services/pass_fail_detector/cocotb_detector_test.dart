// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/cocotb_detector.dart';

/// The summary lines here are copied from real cocotb 2.1.0 runs driving Icarus
/// — both default and `COCOTB_PREVIEW=xfail_in_results` — rather than written
/// to match the parser. The stdout scraper this detector reuses previously
/// matched nothing in production because it was built against an idealised
/// example, and these fixtures exist so that cannot recur.
void main() {
  const detector = CocotbDetector();

  TestStatus classify(String stdout, {PassFailConfig? config}) {
    return detector.detect(
      stdout: stdout,
      stderr: '',
      exitCode: 0,
      runtime: Duration.zero,
      config: config ?? const CocotbPassFailConfig(),
    );
  }

  group('CocotbDetector', () {
    test('a clean run passes', () {
      expect(
        classify('** TESTS=4 PASS=3 FAIL=0 SKIP=1        60.00  0.03  1.0 **'),
        TestStatus.pass,
      );
    });

    test('any failure fails', () {
      expect(
        classify('** TESTS=4 PASS=2 FAIL=1 SKIP=1        60.00  0.03  1.0 **'),
        TestStatus.fail,
      );
    });

    test('an unaccounted-for case fails rather than passing quietly', () {
      // PASS + SKIP falls short of TESTS with no FAIL reported: a case ended
      // in a state the summary has no word for. Reading that as green is how
      // a crashed testcase disappears.
      expect(
        classify('** TESTS=4 PASS=2 FAIL=0 SKIP=1        60.00  0.03  1.0 **'),
        TestStatus.fail,
      );
    });

    group('xfail', () {
      test('counts as expected, so an all-xfail run passes', () {
        expect(
          classify(
            '** TESTS=1 PASS=0 FAIL=0 SKIP=0 XFAIL=1   30.00 0.0 1.0 **',
          ),
          TestStatus.pass,
        );
      });

      test('the preview flag does not change the verdict', () {
        // Cocotb 2.1 reports an xfailed test as PASS by default and as XFAIL
        // only under COCOTB_PREVIEW. Both describe the same run, so both must
        // classify the same way — otherwise setting a logging flag would flip
        // a regression's result.
        const withoutPreview =
            '** TESTS=4 PASS=2 FAIL=1 SKIP=1            60.00 0.03 1.0 **';
        const withPreview =
            '** TESTS=4 PASS=1 FAIL=1 SKIP=1 XFAIL=1    60.00 0.03 1.0 **';
        expect(classify(withoutPreview), classify(withPreview));
        expect(classify(withPreview), TestStatus.fail);
      });
    });

    group('a run that executed nothing', () {
      test('fails by default', () {
        expect(
          classify('** TESTS=0 PASS=0 FAIL=0 SKIP=0        0.00 0.0 0.0 **'),
          TestStatus.fail,
        );
      });

      test('passes when allow_no_tests is set', () {
        expect(
          classify(
            '** TESTS=0 PASS=0 FAIL=0 SKIP=0        0.00 0.0 0.0 **',
            config: const CocotbPassFailConfig(allowNoTests: true),
          ),
          TestStatus.pass,
        );
      });
    });

    test('no summary at all is unknown, not a verdict', () {
      // Cocotb prints the aggregate unconditionally, so its absence means the
      // run died before the regression finished. Returning `unknown` hands the
      // decision to the composite detector or the exit-code default rather
      // than inventing one.
      expect(classify('make: *** [results.xml] Error 1'), TestStatus.unknown);
      expect(classify(''), TestStatus.unknown);
    });

    test('reads the summary from stderr too', () {
      final status = detector.detect(
        stdout: 'nothing useful here',
        stderr: '** TESTS=1 PASS=1 FAIL=0 SKIP=0   10.00 0.0 1.0 **',
        exitCode: 0,
        runtime: Duration.zero,
        config: const CocotbPassFailConfig(),
      );
      expect(status, TestStatus.pass);
    });

    test('ignores the exit code — the summary is the signal', () {
      // A Makefile can swallow a non-zero status or return one for reasons
      // unrelated to the tests. Compose with exit_code when both matter.
      final status = detector.detect(
        stdout: '** TESTS=1 PASS=1 FAIL=0 SKIP=0   10.00 0.0 1.0 **',
        stderr: '',
        exitCode: 2,
        runtime: Duration.zero,
        config: const CocotbPassFailConfig(),
      );
      expect(status, TestStatus.pass);
    });
  });
}
