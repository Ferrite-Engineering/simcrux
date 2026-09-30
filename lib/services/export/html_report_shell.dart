// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The shared skeleton behind every self-contained HTML document SimCrux
/// exports.
///
/// Extracted from [HtmlExporter] so a second HTML artifact — the Pro
/// RISC-V compatibility report — can be
/// built on the *existing* export machinery instead of a parallel
/// renderer with its own escaping rules and its own status palette. The
/// status chip colors in particular are a correctness surface: two HTML
/// exports that disagree about what `fail` looks like is a defect the
/// user finds after handing the file to someone else.
///
/// Everything here is deliberately inert: no script, no network, no
/// external stylesheet or font. Documents built from this shell open from
/// `file://` on a machine with no connectivity, which is the whole point
/// of a self-contained export.
class HtmlReportShell {
  const HtmlReportShell._();

  /// Escapes [value] for interpolation into element text **or** an
  /// attribute value.
  ///
  /// Quotes are escaped as well as the angle brackets, so a single
  /// function covers both positions and no caller has to remember which
  /// one it is in.
  static String escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Document chrome plus the per-status color palette.
  ///
  /// One `.status-<name>` rule per [TestStatus] value. A status added to
  /// the enum without a rule here renders as an unstyled chip rather than
  /// as some other status's color — visibly plain, never misleading.
  static const String baseCss = '''
  :root { color-scheme: dark; }
  body {
    margin: 0;
    padding: 16px;
    font-family: -apple-system, "Segoe UI", system-ui, sans-serif;
    background: #1a1a1a;
    color: #e0e0e0;
  }
  h1 { font-weight: 500; margin: 0 0 8px 0; }
  .meta { color: #999; margin-bottom: 16px; font-size: 13px; }
  .toolbar { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }
  .toolbar input {
    padding: 6px 10px;
    background: #2a2a2a;
    border: 1px solid #444;
    border-radius: 4px;
    color: inherit;
    min-width: 240px;
  }
  .chips { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }
  .chip {
    padding: 4px 10px;
    border-radius: 12px;
    font-size: 12px;
    cursor: pointer;
    border: 1px solid transparent;
    user-select: none;
  }
  .chip.dimmed { opacity: 0.4; }
  .status-pass     { background: #1f6f43; color: white; }
  .status-fail     { background: #a8324a; color: white; }
  .status-timeout  { background: #b6711a; color: white; }
  .status-cancelled{ background: #5b5f63; color: white; }
  .status-skipped  { background: #4a5160; color: #c8c8c8; }
  .status-vacuous  { background: #2c5e63; color: white; }
  .status-cover    { background: #3242b6; color: white; }
  .status-unknown  { background: #322f31; color: #c0c0c0; }
  .status-running  { background: #2a5475; color: white; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td {
    text-align: left;
    padding: 6px 8px;
    border-bottom: 1px solid #2c2c2c;
    white-space: nowrap;
  }
  th {
    cursor: pointer;
    background: #232323;
    user-select: none;
  }
  th:hover { background: #2c2c2c; }
  tr:nth-child(odd) td { background: #1f1f1f; }
  td.status { text-align: center; }
  td.runtime { text-align: right; font-variant-numeric: tabular-nums; }
  .failure { color: #ff9a9a; font-size: 12px; padding-left: 16px; }
  .small { font-size: 11px; color: #888; }
''';

  /// Wraps [body] in the document skeleton.
  ///
  /// [title] is escaped here so callers never have to. [extraCss] is
  /// appended after [baseCss], so a document may add rules but the shared
  /// palette is always present.
  static String document({
    required String title,
    required String body,
    String extraCss = '',
  }) =>
      '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<style>
$baseCss$extraCss</style>
</head>
<body>
$body
</body>
</html>
''';

  /// A status pill using the [baseCss] palette. [status] is a
  /// `TestStatus.name`.
  static String statusChip(String status) =>
      '<span class="chip status-${escape(status)}">${escape(status)}</span>';
}
