// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Reader for the `results.xml` Cocotb writes next to every run.
///
/// **Why this exists.** The driver used to learn per-test outcomes by scraping
/// Cocotb's human-readable summary table out of stdout. That table is a
/// presentation surface: it renamed its rows (`module.qualname` rather than the
/// bare name the scraper expected), gained a status word in 2.1 (`XFAIL`), and
/// gained a counter on its aggregate line. Each drift was silent, because a row
/// that no longer matches simply disappears.
///
/// `results.xml` is the machine-readable form of the same run, has been emitted
/// since Cocotb 1.x, and is xUnit — so it is stable across every version this
/// suite supports and does not move when the table is restyled.
///
/// Real Cocotb 2.1 output, elided:
///
/// ```xml
/// <testsuites name="cocotb tests">
///   <testsuite name="test_mix" errors="0" failures="1" skipped="1" tests="4">
///     <testcase classname="test_mix" name="test_alpha_pass" time="0.000">
///       <properties>
///         <property name="sim_time_duration" value="10.0"/>
///       </properties>
///     </testcase>
///     <testcase classname="test_mix" name="test_bravo_fail">
///       <failure message="deliberate failure" type="AssertionError">…</failure>
///     </testcase>
///     <testcase classname="test_mix" name="test_charlie_skip">
///       <skipped message="Test was skipped"/>
///     </testcase>
///   </testsuite>
/// </testsuites>
/// ```
///
/// Cocotb 1.9 and 2.0 write an older shape: one `<testsuite name="all">` with
/// **no** `tests`/`failures`/`errors`/`skipped` attributes, the simulated time
/// as a `sim_time_ns` attribute on each `<testcase>`, and (2.0) the failure
/// text in `error_msg`/`error_type`. Counts are therefore taken from the
/// children, never from the attributes alone.
///
/// A case carries its outcome by which child element is present — `<failure>`,
/// `<error>`, `<skipped>`, or none at all for a pass. An **xfailed** test has
/// no `<failure>` child, which is why it reads as a pass here exactly as it
/// does in the table without the 2.1 preview flag.
library;

import 'package:xml/xml.dart';

/// One `<testcase>` from `results.xml`.
class CocotbJunitCase {
  /// Creates a case.
  const CocotbJunitCase({
    required this.name,
    required this.status,
    this.simTimeNs,
    this.message,
    this.type,
  });

  /// `<module>.<test>` — assembled from `classname` and `name` so it matches
  /// the identity the summary table prints and the metrics key already used.
  final String name;

  /// `PASS`, `FAIL`, `ERROR` or `SKIP`.
  final String status;

  /// Simulated duration from the `sim_time_duration` property, when present.
  final double? simTimeNs;

  /// Failure/skip message, when the case carries one.
  final String? message;

  /// Exception type for a failure (e.g. `AssertionError`), when present.
  final String? type;
}

/// The whole document: every case, plus the counts the suite element declares.
class CocotbJunitReport {
  /// Creates a report.
  const CocotbJunitReport({
    required this.cases,
    required this.tests,
    required this.failures,
    required this.errors,
    required this.skipped,
  });

  /// Every `<testcase>`, in document order.
  final List<CocotbJunitCase> cases;

  /// `tests` attribute summed over every `<testsuite>`.
  final int tests;

  /// `failures` attribute summed over every `<testsuite>`.
  final int failures;

  /// `errors` attribute summed over every `<testsuite>`.
  final int errors;

  /// `skipped` attribute summed over every `<testsuite>`.
  final int skipped;

  /// Whether the run is clean: nothing failed and nothing errored.
  ///
  /// Deliberately NOT `passes + skips == tests`. An xfailed test has no
  /// `<failure>` child and is therefore already counted as neither a failure
  /// nor an error, so this is correct whether or not the 2.1 preview flag is
  /// set — no residual arithmetic to get wrong.
  bool get isClean => failures == 0 && errors == 0;
}

/// Parses `results.xml`, or returns `null` when it is absent, empty, not XML,
/// or not a Cocotb report.
///
/// **Never throws.** A malformed report must degrade to the stdout path rather
/// than fail a run that the simulator itself may have completed happily.
CocotbJunitReport? parseCocotbJunit(String xml) {
  if (xml.trim().isEmpty) return null;

  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }

  final suites = doc.findAllElements('testsuite').toList();
  if (suites.isEmpty) return null;

  var tests = 0;
  var failures = 0;
  var errors = 0;
  var skipped = 0;
  final cases = <CocotbJunitCase>[];

  for (final suite in suites) {
    var suiteTests = 0;
    var suiteFailures = 0;
    var suiteErrors = 0;
    var suiteSkipped = 0;

    for (final testcase in suite.findElements('testcase')) {
      final classname = testcase.getAttribute('classname')?.trim() ?? '';
      final bare = testcase.getAttribute('name')?.trim() ?? '';
      if (bare.isEmpty) continue;
      final name = classname.isEmpty ? bare : '$classname.$bare';

      final failure = testcase.findElements('failure').firstOrNull;
      final error = testcase.findElements('error').firstOrNull;
      final skip = testcase.findElements('skipped').firstOrNull;

      final (status, carrier) = switch ((failure, error, skip)) {
        (final XmlElement f, _, _) => ('FAIL', f),
        (_, final XmlElement e, _) => ('ERROR', e),
        (_, _, final XmlElement s) => ('SKIP', s),
        _ => ('PASS', null),
      };

      suiteTests++;
      switch (status) {
        case 'FAIL':
          suiteFailures++;
        case 'ERROR':
          suiteErrors++;
        case 'SKIP':
          suiteSkipped++;
      }

      cases.add(
        CocotbJunitCase(
          name: name,
          status: status,
          simTimeNs: _simTimeNs(testcase),
          // 2.1 writes `message`/`type`; 2.0 writes `error_msg`/`error_type`.
          message:
              carrier?.getAttribute('message') ??
              carrier?.getAttribute('error_msg'),
          type:
              carrier?.getAttribute('type') ??
              carrier?.getAttribute('error_type'),
        ),
      );
    }

    // Only Cocotb 2.1 writes the count attributes. 1.9 and 2.0 write a bare
    // `<testsuite name="all" package="all">`, so a report that read only the
    // attributes saw zero failures in every 1.9/2.0 run and called it clean.
    // The children are the ground truth — they are what Cocotb's own
    // `check_results` counts — and an attribute can only raise the number.
    tests += _max(_attrIntOrNull(suite, 'tests'), suiteTests);
    failures += _max(_attrIntOrNull(suite, 'failures'), suiteFailures);
    errors += _max(_attrIntOrNull(suite, 'errors'), suiteErrors);
    skipped += _max(_attrIntOrNull(suite, 'skipped'), suiteSkipped);
  }

  if (cases.isEmpty && tests == 0) return null;

  return CocotbJunitReport(
    cases: cases,
    tests: tests,
    failures: failures,
    errors: errors,
    skipped: skipped,
  );
}

/// Reads `<property name="sim_time_duration" value="…"/>`, which Cocotb 2.1
/// emits in nanoseconds alongside `sim_time_unit`, or the `sim_time_ns`
/// attribute Cocotb 1.9 and 2.0 put on the `<testcase>` itself.
double? _simTimeNs(XmlElement testcase) {
  for (final property in testcase.findAllElements('property')) {
    if (property.getAttribute('name') == 'sim_time_duration') {
      return double.tryParse(property.getAttribute('value') ?? '');
    }
  }
  return double.tryParse(testcase.getAttribute('sim_time_ns') ?? '');
}

int? _attrIntOrNull(XmlElement element, String name) =>
    int.tryParse(element.getAttribute(name) ?? '');

int _max(int? attribute, int counted) =>
    (attribute != null && attribute > counted) ? attribute : counted;
