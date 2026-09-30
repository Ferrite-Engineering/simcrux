// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/simulator/cocotb_junit.dart';

/// The blobs here are copied from a real `results.xml`, produced by
/// cocotb 2.1.0 driving Icarus through the Makefile flow
/// (Strategy A) that [CocotbDriver] uses — not hand-written to match the
/// parser. The stdout scraper this replaces was written against an idealised
/// example and consequently matched nothing in production for years, which is
/// the mistake these fixtures exist to avoid repeating.
void main() {
  // Trimmed to the structure that matters; attributes and element order are
  // verbatim. One case of each outcome, including an xfail (which carries no
  // <failure> child and therefore reads as a pass).
  const realResultsXml = '''
<?xml version='1.0' encoding='utf-8'?>
<testsuites name="cocotb tests"><testsuite name="test_mix" errors="0" failures="1" skipped="1" tests="4" time="0.000" timestamp="2026-09-02T13:23:37.512104+00:00" hostname="MartinEliteBook"><testcase classname="test_mix" name="test_alpha_pass" time="0.000"><properties><property name="cocotb" value="True" /><property name="sim_time_unit" value="ns" /><property name="sim_time_duration" value="10.0" /></properties></testcase><testcase classname="test_mix" name="test_bravo_fail" time="0.000"><failure message="deliberate failure&#10;assert False" type="AssertionError">Traceback (most recent call last):
  File "test_mix.py", line 21, in test_bravo_fail
    assert False, "deliberate failure"
AssertionError: deliberate failure
</failure><properties><property name="sim_time_duration" value="20.0" /></properties></testcase><testcase classname="test_mix" name="test_charlie_skip" time="0.000"><skipped message="Test was skipped" /><properties><property name="cocotb" value="True" /></properties></testcase><testcase classname="test_mix" name="test_delta_xfail" time="0.000"><properties><property name="sim_time_duration" value="30.000000000000004" /></properties></testcase></testsuite></testsuites>
''';

  group('parseCocotbJunit', () {
    test('reads every case from a real cocotb 2.1 report', () {
      final report = parseCocotbJunit(realResultsXml)!;
      expect(report.tests, 4);
      expect(report.failures, 1);
      expect(report.errors, 0);
      expect(report.skipped, 1);
      expect(report.cases, hasLength(4));
    });

    test('names are module-qualified, matching the summary table', () {
      final report = parseCocotbJunit(realResultsXml)!;
      expect(
        report.cases.map((c) => c.name),
        [
          'test_mix.test_alpha_pass',
          'test_mix.test_bravo_fail',
          'test_mix.test_charlie_skip',
          'test_mix.test_delta_xfail',
        ],
      );
    });

    test('outcome comes from the child element, not a status string', () {
      final report = parseCocotbJunit(realResultsXml)!;
      final byName = {for (final c in report.cases) c.name: c};
      expect(byName['test_mix.test_alpha_pass']!.status, 'PASS');
      expect(byName['test_mix.test_bravo_fail']!.status, 'FAIL');
      expect(byName['test_mix.test_charlie_skip']!.status, 'SKIP');
    });

    test('an xfailed case has no <failure> and so reads as PASS', () {
      // This is why the report needs no XFAIL special-casing and no knowledge
      // of COCOTB_PREVIEW: cocotb has already decided, and it decided by
      // omitting the failure element.
      final report = parseCocotbJunit(realResultsXml)!;
      final xfail = report.cases.firstWhere(
        (c) => c.name == 'test_mix.test_delta_xfail',
      );
      expect(xfail.status, 'PASS');
      expect(report.isClean, isFalse, reason: 'bravo genuinely failed');
    });

    test('carries the failure message and type the table never had', () {
      final report = parseCocotbJunit(realResultsXml)!;
      final failed = report.cases.firstWhere((c) => c.status == 'FAIL');
      expect(failed.type, 'AssertionError');
      expect(failed.message, contains('deliberate failure'));
    });

    test('sim_time_duration is read from the properties block', () {
      final report = parseCocotbJunit(realResultsXml)!;
      expect(report.cases.first.simTimeNs, 10.0);
    });

    test('a clean run is clean', () {
      final report = parseCocotbJunit('''
<testsuites><testsuite name="t" errors="0" failures="0" skipped="0" tests="2">
<testcase classname="t" name="a"/><testcase classname="t" name="b"/>
</testsuite></testsuites>
''')!;
      expect(report.isClean, isTrue);
      expect(report.cases.map((c) => c.status), everyElement('PASS'));
    });

    test('an errored case is neither pass nor failure', () {
      final report = parseCocotbJunit('''
<testsuites><testsuite name="t" errors="1" failures="0" skipped="0" tests="1">
<testcase classname="t" name="boom"><error message="gpi died" type="RuntimeError"/></testcase>
</testsuite></testsuites>
''')!;
      expect(report.cases.single.status, 'ERROR');
      expect(report.isClean, isFalse, reason: 'errors must not read as clean');
    });

    test('multiple testsuites are summed — 2.1 groups by test module', () {
      final report = parseCocotbJunit('''
<testsuites>
<testsuite name="mod_a" errors="0" failures="1" skipped="0" tests="2">
<testcase classname="mod_a" name="x"/><testcase classname="mod_a" name="y"><failure message="m"/></testcase>
</testsuite>
<testsuite name="mod_b" errors="0" failures="0" skipped="1" tests="1">
<testcase classname="mod_b" name="z"><skipped/></testcase>
</testsuite>
</testsuites>
''')!;
      expect(report.tests, 3);
      expect(report.failures, 1);
      expect(report.skipped, 1);
      expect(report.cases, hasLength(3));
      expect(report.cases.last.name, 'mod_b.z');
    });

    group('cocotb 1.9 and 2.0 write no count attributes', () {
      // Verbatim from cocotb 2.0.1 driving Icarus through the Makefile flow
      // (only the `file` path is shortened). cocotb 1.9.2's reporter writes
      // the same shape, with `message=` on the failure element instead.
      const cocotb20ResultsXml = '''
<testsuites name="results">
  <testsuite name="all" package="all">
    <property name="random_seed" value="1789485672" />
    <testcase name="test_pass" classname="test_dff" file="test_dff.py" lineno="5" time="8.177757263183594e-05" sim_time_ns="10.0" ratio_time="122282.91545189504" />
    <testcase name="test_fail" classname="test_dff" file="test_dff.py" lineno="10" time="0.0003781318664550781" sim_time_ns="20.0" ratio_time="52891.60151324086">
      <failure error_type="AssertionError" error_msg="deliberate failure&#10;assert False" />
    </testcase>
  </testsuite>
</testsuites>''';

      const cocotb19ResultsXml = '''
<testsuites name="results">
  <testsuite name="all" package="all">
    <property name="random_seed" value="1" />
    <testcase name="test_pass" classname="test_dff" sim_time_ns="10.0" />
    <testcase name="test_skip" classname="test_dff" sim_time_ns="0.0"><skipped /></testcase>
    <testcase name="test_fail" classname="test_dff" sim_time_ns="20.0">
      <failure message="Test failed with RANDOM_SEED=1" />
    </testcase>
  </testsuite>
</testsuites>''';

      test('a failing 2.0 report is not clean', () {
        final report = parseCocotbJunit(cocotb20ResultsXml)!;
        expect(report.isClean, isFalse);
        expect(report.tests, 2);
        expect(report.failures, 1);
        final failed = report.cases.firstWhere((c) => c.status == 'FAIL');
        expect(failed.name, 'test_dff.test_fail');
        expect(failed.type, 'AssertionError');
        expect(failed.message, contains('deliberate failure'));
        expect(failed.simTimeNs, 20.0);
      });

      test('a failing 1.9 report is not clean', () {
        final report = parseCocotbJunit(cocotb19ResultsXml)!;
        expect(report.isClean, isFalse);
        expect(report.tests, 3);
        expect(report.failures, 1);
        expect(report.skipped, 1);
        expect(
          report.cases.firstWhere((c) => c.status == 'FAIL').message,
          'Test failed with RANDOM_SEED=1',
        );
      });

      test('a passing report without attributes is clean', () {
        final report = parseCocotbJunit('''
<testsuites name="results"><testsuite name="all" package="all">
<testcase name="a" classname="t" sim_time_ns="1.0" />
</testsuite></testsuites>''')!;
        expect(report.isClean, isTrue);
        expect(report.tests, 1);
      });
    });

    group('degrades to null rather than throwing', () {
      test('empty input', () => expect(parseCocotbJunit(''), isNull));
      test('whitespace', () => expect(parseCocotbJunit('   \n '), isNull));
      test('not XML', () {
        expect(parseCocotbJunit('make: *** [results.xml] Error 1'), isNull);
      });
      test('truncated XML from a killed run', () {
        expect(
          parseCocotbJunit('<testsuites><testsuite name="t" tests="4">'),
          isNull,
        );
      });
      test('valid XML that is not a cocotb report', () {
        expect(parseCocotbJunit('<hello><world/></hello>'), isNull);
      });
    });
  });
}
