// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The educational-licence mark at the exporter level: the HTML report closes
// with it, every data format ignores it. The licence decision itself (which
// status yields a mark) is covered where it is made, in the GUI export flow
// and the CI runner tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/export/html_report_shell.dart';
import 'package:simcrux/services/export/result_exporter.dart';

import '../../support/edu_license_status.dart';

final TestRun _run = TestRun(
  id: 'r1',
  startedAt: DateTime.utc(2026, 5, 23, 17),
  finishedAt: DateTime.utc(2026, 5, 23, 17, 0, 42),
  testIds: const ['axi/burst'],
);

final List<DashboardRow> _rows = [
  DashboardRow(
    result: TestResult(
      testId: 'axi/burst',
      runId: 'r1',
      status: TestStatus.pass,
      startedAt: DateTime.utc(2026, 5, 23, 17),
      finishedAt: DateTime.utc(2026, 5, 23, 17, 0, 1),
      exitCode: 0,
    ),
    suiteName: 'axi',
    simulatorId: 'verilator',
    testName: 'burst',
  ),
];

String _encode(ExportFormat format, {String? exportMark}) =>
    const ExporterRegistry()
        .exporterFor(format)
        .encode(
          run: _run,
          rows: _rows,
          configPath: '/p/simcrux.yaml',
          exportMark: exportMark,
        );

void main() {
  group('HtmlReportShell', () {
    test('closes the page with the mark as a footer', () {
      final html = HtmlReportShell.document(
        title: 't',
        body: '<p>body</p>\n',
        exportMark: kEnglishEduExportMark,
      );
      expect(
        html,
        contains(
          '<footer class="crux-edu-mark" style="margin-top: 24px; '
          'text-align: right; font-size: 11px; color: #888;">'
          '$kEnglishEduExportMark</footer>',
        ),
      );
      // After the body, inside it.
      expect(
        html.indexOf('crux-edu-mark'),
        greaterThan(html.indexOf('<p>body</p>')),
      );
      expect(html.indexOf('crux-edu-mark'), lessThan(html.indexOf('</body>')));
    });

    test('escapes the mark', () {
      final html = HtmlReportShell.document(
        title: 't',
        body: '',
        exportMark: '<b>x</b>',
      );
      expect(html, contains('&lt;b&gt;x&lt;/b&gt;'));
      expect(html, isNot(contains('<b>x</b>')));
    });

    test('without a mark the body closes the page as before', () {
      final unmarked = HtmlReportShell.document(title: 't', body: '<p>b</p>');
      expect(unmarked, isNot(contains('crux-edu-mark')));
      expect(unmarked, endsWith('<body>\n<p>b</p>\n</body>\n</html>\n'));
    });
  });

  group('HtmlExporter', () {
    test('stamps the mark when given one', () {
      final html = _encode(
        ExportFormat.html,
        exportMark: kEnglishEduExportMark,
      );
      expect(html, contains(kEnglishEduExportMark));
      expect(html, contains('class="crux-edu-mark"'));
    });

    test('carries no mark without one', () {
      final html = _encode(ExportFormat.html);
      expect(html, isNot(contains('crux-edu-mark')));
      expect(html, isNot(contains('Educational')));
    });
  });

  group('data formats ignore the mark', () {
    for (final format in [
      ExportFormat.junit,
      ExportFormat.json,
      ExportFormat.csv,
    ]) {
      test('${format.id} is byte-identical with and without it', () {
        final marked = _encode(format, exportMark: kEnglishEduExportMark);
        expect(marked, _encode(format));
        expect(marked, isNot(contains('Educational')));
        expect(marked, isNot(contains('Non-commercial')));
      });
    }
  });
}
