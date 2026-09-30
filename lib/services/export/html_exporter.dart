// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/export/html_report_shell.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// Single-file static-site dashboard exporter.
///
/// Produces a self-contained HTML document with:
///
/// - A header summary (totals by status, run timestamp, config path).
/// - Status filter chips (clickable) that hide/show rows in the
///   table via tiny inline JavaScript.
/// - A sortable table (click any header to sort ascending /
///   descending) with rows colored by status.
/// - A simple substring search input.
///
/// No CDN, no framework — only a few hundred lines of CSS + JS
/// inline so the file works offline and behind a corporate proxy.
///
/// The document skeleton, the escaping and the per-status color palette
/// live in [HtmlReportShell] so a second HTML artifact can reuse them
/// rather than fork them.
class HtmlExporter implements ResultExporter {
  /// Const constructor.
  const HtmlExporter();

  @override
  ExportFormat get format => ExportFormat.html;

  @override
  String encode({
    required TestRun run,
    required List<DashboardRow> rows,
    String? configPath,
  }) {
    final totals = <TestStatus, int>{};
    for (final row in rows) {
      totals.update(row.result.status, (n) => n + 1, ifAbsent: () => 1);
    }
    final rowsJson = jsonEncode([
      for (final row in rows)
        <String, Object?>{
          'id': row.testId,
          'suite': row.suiteName,
          'name': row.testName,
          'simulator': row.simulatorId,
          'status': row.result.status.name,
          'runtime_ms': row.result.runtime.inMilliseconds,
          'started_at': row.result.startedAt.toUtc().toIso8601String(),
          'exit_code': row.result.exitCode,
          'failure_message': row.result.failureMessage,
        },
    ]);

    final summary = totals.entries
        .map(
          (e) =>
              '<span class="chip status-${e.key.name}" '
              'data-status="${e.key.name}">${e.key.name}: ${e.value}</span>',
        )
        .join('\n');

    return HtmlReportShell.document(
      title: 'SimCrux regression — ${configPath ?? run.id}',
      body:
          '''
<h1>SimCrux regression</h1>
<div class="meta">
  Run <span class="small">${_escape(run.id)}</span> ·
  Started ${_escape(run.startedAt.toUtc().toIso8601String())}${run.finishedAt != null ? " · Finished ${_escape(run.finishedAt!.toUtc().toIso8601String())}" : ''} ·
  ${rows.length} tests${configPath != null ? " · ${_escape(configPath)}" : ''}
</div>

<div class="chips" id="chips">$summary</div>

<div class="toolbar">
  <input type="search" id="filter" placeholder="Filter by test id or suite…">
</div>

<table id="results">
  <thead>
    <tr>
      <th data-col="status">Status</th>
      <th data-col="suite">Suite</th>
      <th data-col="name">Test</th>
      <th data-col="simulator">Simulator</th>
      <th data-col="runtime_ms">Runtime</th>
      <th data-col="started_at">Started</th>
    </tr>
  </thead>
  <tbody id="body"></tbody>
</table>

<script id="data" type="application/json">$rowsJson</script>
<script>
(function() {
  const data = JSON.parse(document.getElementById('data').textContent);
  const body = document.getElementById('body');
  const chips = document.getElementById('chips');
  const filter = document.getElementById('filter');
  let sortCol = 'status';
  let sortDir = 1;
  const hidden = new Set();

  function render() {
    const needle = filter.value.toLowerCase();
    const rows = data
      .filter((r) => !hidden.has(r.status))
      .filter((r) => {
        if (!needle) return true;
        return (r.id + ' ' + r.suite + ' ' + r.name).toLowerCase().includes(needle);
      });
    rows.sort((a, b) => {
      const va = a[sortCol], vb = b[sortCol];
      if (va === vb) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      if (typeof va === 'number') return (va - vb) * sortDir;
      return String(va).localeCompare(String(vb)) * sortDir;
    });
    body.innerHTML = rows.map((r) => {
      const fmsg = r.failure_message ? '<div class="failure">' + escapeHtml(r.failure_message) + '</div>' : '';
      return '<tr>'
        + '<td class="status"><span class="chip status-' + r.status + '">' + r.status + '</span></td>'
        + '<td>' + escapeHtml(r.suite) + '</td>'
        + '<td>' + escapeHtml(r.name) + fmsg + '</td>'
        + '<td>' + escapeHtml(r.simulator) + '</td>'
        + '<td class="runtime">' + r.runtime_ms + ' ms</td>'
        + '<td><span class="small">' + escapeHtml(r.started_at || '') + '</span></td>'
        + '</tr>';
    }).join('');
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  document.querySelectorAll('th').forEach((th) => {
    th.addEventListener('click', () => {
      const col = th.getAttribute('data-col');
      if (col === sortCol) { sortDir = -sortDir; }
      else { sortCol = col; sortDir = 1; }
      render();
    });
  });
  chips.querySelectorAll('.chip').forEach((c) => {
    c.addEventListener('click', () => {
      const s = c.getAttribute('data-status');
      if (hidden.has(s)) { hidden.delete(s); c.classList.remove('dimmed'); }
      else { hidden.add(s); c.classList.add('dimmed'); }
      render();
    });
  });
  filter.addEventListener('input', render);
  render();
})();
</script>
''',
    );
  }

  static String _escape(String value) => HtmlReportShell.escape(value);
}
