// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/services/export/html_report_shell.dart';

void main() {
  test('document wraps the body in a self-contained skeleton', () {
    final html = HtmlReportShell.document(
      title: 'Report',
      body: '<h1>Body</h1>',
    );
    expect(html, startsWith('<!DOCTYPE html>'));
    expect(html, contains('<title>Report</title>'));
    expect(html, contains('<h1>Body</h1>'));
    expect(html, contains(HtmlReportShell.baseCss));
    // Self-contained: nothing is fetched when the file is opened from
    // file:// on a machine with no network.
    expect(html, isNot(contains('http://')));
    expect(html, isNot(contains('https://')));
    expect(html, isNot(contains('<link')));
  });

  test('document escapes the title rather than trusting the caller', () {
    final html = HtmlReportShell.document(
      title: '<script>alert("x")</script>',
      body: '',
    );
    expect(html, contains('&lt;script&gt;'));
    expect(html, isNot(contains('<script>alert')));
  });

  test('extraCss is appended after the shared palette, never instead', () {
    final html = HtmlReportShell.document(
      title: 't',
      body: '',
      extraCss: '  .custom { color: red; }\n',
    );
    expect(html, contains('.status-pass'));
    expect(html, contains('.custom { color: red; }'));
    expect(
      html.indexOf('.status-pass'),
      lessThan(html.indexOf('.custom')),
    );
  });

  test('escape covers attribute position as well as text', () {
    expect(
      HtmlReportShell.escape('a & b < c > d "e"'),
      'a &amp; b &lt; c &gt; d &quot;e&quot;',
    );
  });

  test('every TestStatus has a palette rule', () {
    // A status added to the enum without a rule renders as a plain chip
    // rather than borrowing another status's color — but the export is
    // the artifact a customer reads, so catch it here instead.
    for (final status in TestStatus.values) {
      expect(
        HtmlReportShell.baseCss,
        contains('.status-${status.name}'),
        reason: '${status.name} has no chip color',
      );
    }
  });

  test('statusChip renders the palette class', () {
    expect(
      HtmlReportShell.statusChip('fail'),
      '<span class="chip status-fail">fail</span>',
    );
  });
}
