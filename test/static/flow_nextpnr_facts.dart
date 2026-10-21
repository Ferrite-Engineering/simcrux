// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Independent extraction of the facts the nextpnr fixtures pin.
//
// Everything here reads nextpnr's own log line and report with `dart:convert`
// and a regular expression. It shares no code with the product's readers, so
// an expectation checked through it never comes from the tool under test.

import 'dart:convert';
import 'dart:io';

/// The verdict nextpnr itself printed on its last "Max frequency" line.
class VerdictFacts {
  const VerdictFacts({
    required this.verdict,
    required this.marker,
    required this.constraintMhz,
    required this.exitCode,
  });

  /// `met` for PASS, `violated` for FAIL.
  final String verdict;

  /// The literal `PASS` or `FAIL` in the log line.
  final String marker;
  final double constraintMhz;
  final int? exitCode;

  @override
  String toString() =>
      'verdict=$verdict marker=$marker constraint=$constraintMhz exit=$exitCode';
}

final RegExp _maxFrequency = RegExp(
  r"Max frequency for clock '.*': ([0-9.]+) MHz \((PASS|FAIL) at ([0-9.]+) MHz\)",
);

/// The last "Max frequency" line of [log]: the post-route one, which is the
/// line nextpnr's own exit status follows.
VerdictFacts verdictFromLog(String log, {int? exitCode}) {
  RegExpMatch? last;
  for (final line in const LineSplitter().convert(log)) {
    final match = _maxFrequency.firstMatch(line);
    if (match != null) last = match;
  }
  if (last == null) {
    throw StateError('no "Max frequency" line in the log');
  }
  final marker = last.group(2)!;
  return VerdictFacts(
    verdict: marker == 'PASS' ? 'met' : 'violated',
    marker: marker,
    constraintMhz: double.parse(last.group(3)!),
    exitCode: exitCode,
  );
}

/// Reads a hand-written `verdict.expected.json`.
VerdictFacts verdictFromExpectation(File file) {
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return VerdictFacts(
    verdict: json['verdict'] as String,
    marker: json['marker'] as String,
    constraintMhz: (json['constraint_mhz'] as num).toDouble(),
    exitCode: json['exit_code'] as int?,
  );
}

/// What the report says about the worst clocked path of the designed adder.
class MappingFacts {
  const MappingFacts({
    required this.startRegister,
    required this.statementLines,
    required this.cellNamesCarryRegisters,
  });

  /// Base name (no bit index) of the net leaving the first register.
  final String startRegister;

  /// Source lines named by the `sources` of the path's routing steps.
  final Set<int> statementLines;

  /// Whether both end cells are named after the RTL registers.
  final bool cellNamesCarryRegisters;
}

MappingFacts mappingFromReport(
  Map<String, dynamic> report, {
  required String sourceFile,
  required List<String> startRegisters,
  required String endRegister,
}) {
  final paths = report['critical_paths'] as List<dynamic>;
  final clocked = paths.cast<Map<String, dynamic>>().firstWhere(
    (p) => (p['from'] as String).startsWith('posedge'),
  );
  final steps = (clocked['path'] as List<dynamic>).cast<Map<String, dynamic>>();
  final routing = steps.where((s) => s['type'] == 'routing').toList();
  final net = routing.first['net'] as String;
  final startRegister = net.split('[').first;
  final lines = <int>{};
  final span = RegExp('^${RegExp.escape(sourceFile)}:(\\d+)\\.');
  for (final step in routing) {
    for (final source in (step['sources'] as List<dynamic>)) {
      final match = span.firstMatch(source as String);
      if (match != null) lines.add(int.parse(match.group(1)!));
    }
  }
  final startCell = (steps.first['from'] as Map<String, dynamic>)['cell'];
  final endCell = (steps.last['to'] as Map<String, dynamic>)['cell'];
  final carries =
      startRegisters.any((r) => (startCell as String).startsWith(r)) &&
      (endCell as String).startsWith(endRegister);
  return MappingFacts(
    startRegister: startRegister,
    statementLines: lines,
    cellNamesCarryRegisters: carries,
  );
}

/// Key sets only: no values, clock names or resource names. Two reports with
/// equal signatures share a schema.
Map<String, Object> schemaSignature(Map<String, dynamic> report) {
  List<String> keys(Map<dynamic, dynamic> m) =>
      (m.keys.cast<String>().toList()..sort());
  final fmax = report['fmax'] as Map<String, dynamic>;
  final util = report['utilization'] as Map<String, dynamic>;
  final paths = (report['critical_paths'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final stepKeySets = <String>{
    for (final p in paths)
      for (final s in (p['path'] as List<dynamic>))
        keys(s as Map<dynamic, dynamic>).join(','),
  };
  final nets = (report['detailed_net_timings'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final endpointKeySets = <String>{
    for (final n in nets)
      for (final e in (n['endpoints'] as List<dynamic>))
        keys(e as Map<dynamic, dynamic>).join(','),
  };
  return {
    'top': keys(report),
    'fmax_value_keys': keys(fmax.values.first as Map<dynamic, dynamic>),
    'utilization_value_keys': keys(util.values.first as Map<dynamic, dynamic>),
    'critical_path_keys': keys(paths.first),
    'step_key_sets': (stepKeySets.toList()..sort()),
    'net_timing_keys': keys(nets.first),
    'endpoint_key_sets': (endpointKeySets.toList()..sort()),
  };
}

/// The step types a report uses. Reported, not compared: the vocabulary varies
/// by family and by design.
Set<String> stepTypes(Map<String, dynamic> report) => {
  for (final p in (report['critical_paths'] as List<dynamic>))
    for (final s in ((p as Map<String, dynamic>)['path'] as List<dynamic>))
      (s as Map<String, dynamic>)['type'] as String,
};
