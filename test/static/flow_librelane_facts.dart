// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Independent extraction over LibreLane run directories, for the LibreLane
// fixture tests. Nothing here imports the product: the facts a fixture is
// checked against must not come from the code under test.
//
// What it reads, and how:
// - STA text reports (report_checks output): split at "Startpoint:", the
//   header lines, the table rows, and the slack line.
// - The synthesis sidecar (<D>.nl.v.json, Yosys write_json): the
//   write_verilog auto-name map (`$` wires, then `$` cells, sorted, numbered
//   _NNN_ after the highest existing _NNN_ name), and the public nets on a
//   flip-flop's Q pin.
// - flow.log: "Running '<Step.Id>' at '<run>/<NN>-<slug>'" lines.

import 'dart:convert';
import 'dart:io';

/// One timing path of a report_checks text listing.
class StaPath {
  StaPath({
    required this.rank,
    required this.start,
    required this.startKind,
    required this.end,
    required this.endKind,
    required this.group,
    required this.type,
    required this.slack,
    required this.met,
    required this.arrival,
    required this.required,
    required this.pins,
  });

  /// 1-based position in the file.
  final int rank;
  final String start;
  final String startKind;
  final String end;
  final String endKind;
  final String group;
  final String type;
  final double slack;
  final bool met;
  final double arrival;
  final double required;

  /// Pin rows before the data arrival line, in order: `inst/pin`, or a port.
  final List<StaPin> pins;

  /// Pin rows from the startpoint on: the data path a reader shows.
  List<StaPin> get segments {
    final i = pins.indexWhere(
      (p) => p.pin == start || p.pin.startsWith('$start/'),
    );
    return i < 0 ? const [] : pins.sublist(i);
  }
}

class StaPin {
  StaPin(this.pin, this.cell, this.edge, this.time);

  final String pin;
  final String cell;
  final String edge;
  final double time;
}

class StaParseError implements Exception {
  StaParseError(this.message);

  final String message;

  @override
  String toString() => 'StaParseError: $message';
}

final _row = RegExp(r'^((?:\s+-?\d+(?:\.\d+)?)*)\s+(\S.*)$');
final _pinDesc = RegExp(r'^([\^v]) (\S+) \(([^)]+)\)$');
final _netDesc = RegExp(r'^\S+ \(net\)$');
final _externalDelay = RegExp(r'^(?:[\^v] )?(?:input|output) external delay$');

/// Parses every path of a report_checks `-format full_clock_expanded` text
/// listing. Throws [StaParseError] on a row it cannot classify.
List<StaPath> parseStaReport(String text) {
  final blocks = text.split(RegExp(r'\n(?=Startpoint: )')).skip(1);
  final paths = <StaPath>[];
  for (final block in blocks) {
    String header(String key) {
      final m = RegExp(
        '^${RegExp.escape(key)}: (.*)\$',
        multiLine: true,
      ).firstMatch(block);
      if (m == null) {
        throw StaParseError('missing $key in path ${paths.length}');
      }
      return m[1]!;
    }

    final startLine = header('Startpoint');
    final endLine = header('Endpoint');
    final group = header('Path Group');
    final type = header('Path Type');
    final lines = block.split('\n');
    final tableAt = lines.indexWhere((l) => l.startsWith('Fanout'));
    if (tableAt < 0) throw StaParseError('no table in path ${paths.length}');
    final rows = <(List<double>, String)>[];
    for (final line in lines.skip(tableAt + 2)) {
      final t = line.trim();
      if (t.isEmpty || RegExp(r'^-+$').hasMatch(t)) continue;
      final m = _row.firstMatch(line);
      if (m == null) throw StaParseError('unparsed row: $line');
      final cols = m[1]!
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .map(double.parse)
          .toList();
      rows.add((cols, m[2]!));
    }
    double last(String desc) {
      final r = rows.firstWhere(
        (r) => r.$2 == desc,
        orElse: () => throw StaParseError('missing "$desc"'),
      );
      return r.$1.last;
    }

    final arrival = last('data arrival time');
    final required = last('data required time');
    final slackRow = rows.firstWhere(
      (r) => r.$2.startsWith('slack ('),
      orElse: () => throw StaParseError('missing slack'),
    );
    final arrivalAt = rows.indexWhere((r) => r.$2 == 'data arrival time');
    final pins = <StaPin>[];
    for (final (cols, desc) in rows.take(arrivalAt)) {
      final p = _pinDesc.firstMatch(desc);
      if (p != null) {
        pins.add(StaPin(p[2]!, p[3]!, p[1]!, cols.last));
      } else if (!(_netDesc.hasMatch(desc) ||
          desc.startsWith('clock ') ||
          _externalDelay.hasMatch(desc))) {
        throw StaParseError('unclassified row: $desc');
      }
    }
    String name(String line) => line.split(' ').first;
    String kind(String line) {
      final m = RegExp(r'\((.*)\)$').firstMatch(line);
      return m == null ? '' : m[1]!;
    }

    paths.add(
      StaPath(
        rank: paths.length + 1,
        start: name(startLine),
        startKind: kind(startLine),
        end: name(endLine),
        endKind: kind(endLine),
        group: group,
        type: type,
        slack: slackRow.$1.last,
        met: slackRow.$2 == 'slack (MET)',
        arrival: arrival,
        required: required,
        pins: pins,
      ),
    );
  }
  return paths;
}

/// write_verilog's auto-names for one sidecar module: `_NNN_` to the `$` id.
Map<String, String> autoNameMap(Map<String, dynamic> module) {
  final wires = (module['netnames'] as Map<String, dynamic>).keys.toList()
    ..sort(_byteOrder);
  final cells = (module['cells'] as Map<String, dynamic>).keys.toList()
    ..sort(_byteOrder);
  var offset = 0;
  final numbered = RegExp(r'^_(\d+)_?$');
  for (final n in [...wires, ...cells]) {
    final m = numbered.firstMatch(n);
    if (m != null) {
      final v = int.parse(m[1]!) + 1;
      if (v > offset) offset = v;
    }
  }
  final ids = [
    ...wires.where((n) => n.startsWith(r'$')),
    ...cells.where((n) => n.startsWith(r'$')),
  ];
  final total = offset + ids.length;
  var digits = 1;
  var bound = 10;
  while (bound < total) {
    digits++;
    bound *= 10;
  }
  return {
    for (var k = 0; k < ids.length; k++)
      '_${(offset + k).toString().padLeft(digits, '0')}_': ids[k],
  };
}

// Python's sorted() on str compares code points; Dart's compareTo compares
// UTF-16 units, which agree for the ASCII names Yosys writes.
int _byteOrder(String a, String b) => a.compareTo(b);

/// The synthesis sidecar's top module, its auto-name map, and the public net
/// labels per bit (`name` for a one-bit net, `name[i]` otherwise).
class Sidecar {
  Sidecar(Map<String, dynamic> json, this.top)
    : module =
          (json['modules'] as Map<String, dynamic>)[top]
              as Map<String, dynamic> {
    names = autoNameMap(module);
    final nets = module['netnames'] as Map<String, dynamic>;
    for (final e in nets.entries) {
      final net = e.value as Map<String, dynamic>;
      if ((net['hide_name'] as int? ?? 0) != 0 || e.key.startsWith(r'$')) {
        continue;
      }
      final bits = net['bits'] as List<dynamic>;
      for (var i = 0; i < bits.length; i++) {
        final label = bits.length == 1 ? e.key : '${e.key}[$i]';
        (_bitLabels[bits[i]] ??= []).add(label);
      }
    }
  }

  final String top;
  final Map<String, dynamic> module;
  late final Map<String, String> names;
  final Map<Object?, List<String>> _bitLabels = {};

  Map<String, dynamic>? cell(String instance) {
    final cells = module['cells'] as Map<String, dynamic>;
    return (cells[names[instance] ?? instance] ??
            cells[instance.replaceAll(r'\', '')])
        as Map<String, dynamic>?;
  }

  /// Public net labels on the Q pins of [instance], or null when the sidecar
  /// has no such cell.
  List<String>? qNets(String instance) {
    final c = cell(instance);
    if (c == null) return null;
    final conns = c['connections'] as Map<String, dynamic>;
    return {
      for (final pin in const ['Q', 'Q_N', 'QN'])
        for (final bit in (conns[pin] as List<dynamic>? ?? const []))
          ...?_bitLabels[bit],
    }.toList()..sort();
  }
}

/// The register a net label names: the label with trailing `[N]` selects
/// removed, as far as [registers] needs.
String? registerOf(String label, Set<String> registers) {
  var candidate = label;
  while (true) {
    if (registers.contains(candidate)) return candidate;
    final shorter = candidate.replaceFirst(RegExp(r'\[\d+\]$'), '');
    if (shorter == candidate) return null;
    candidate = shorter;
  }
}

/// Step directories of a run (`NN-slug`), in ordinal order.
List<Directory> stepDirs(Directory run) {
  final dirs = run
      .listSync()
      .whereType<Directory>()
      .where((d) => RegExp(r'^\d+-').hasMatch(dirName(d)))
      .toList();
  int ordinal(Directory d) => int.parse(dirName(d).split('-').first);
  dirs.sort((a, b) => ordinal(a).compareTo(ordinal(b)));
  return dirs;
}

String dirName(FileSystemEntity e) {
  final segments = e.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return segments.last;
}

/// Step directory name (`NN-slug`) to step id, from flow.log's Running lines.
Map<String, String> stepIdsFromFlowLog(String flowLog) {
  final out = <String, String>{};
  final step = RegExp(r'^\d+-');
  for (final m in RegExp(
    r"^Running '([^']+)' at '(?:[^']*/)?([^'/]+)/(\d+-[^'/]+)'",
    multiLine: true,
  ).allMatches(flowLog)) {
    // A composite step's sub-steps live inside its directory
    // (`42-openroad-repairantennas/1-openroad-diodeinsertion`): not steps.
    if (step.hasMatch(m[2]!)) continue;
    out[m[3]!] = m[1]!;
  }
  return out;
}

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Directory? stepDir(Directory run, String slug) {
  for (final d in stepDirs(run)) {
    if (dirName(d).split('-').skip(1).join('-') == slug) return d;
  }
  return null;
}

String _sign(num v) => v == 0 ? 'zero' : (v > 0 ? 'positive' : 'negative');

/// The facts of one captured case (`<case>/run`, `exit_code.txt`) compared
/// with its hand-written expectation. Returns the differences; empty when
/// they agree. With [exactMetrics] metric values must match exactly (the
/// committed capture); without it only their sign must (a live rerun on
/// another machine).
List<String> caseDifferences(
  Directory caseDir,
  Map<String, dynamic> expected, {
  required bool exactMetrics,
  Map<String, dynamic>? mapping,
}) {
  final diffs = <String>[];
  void check(String what, Object? actual, Object? want) {
    if ('$actual' != '$want') diffs.add('$what: got $actual, want $want');
  }

  final run = Directory('${caseDir.path}/run');
  if (!run.existsSync()) return ['missing ${run.path}'];
  final exit = int.parse(
    File('${caseDir.path}/exit_code.txt').readAsStringSync().trim(),
  );
  check('exit code', exit, expected['exit_code']);

  final resolved = readJson('${run.path}/resolved.json');
  final meta = resolved['meta'] as Map<String, dynamic>;
  check(
    'meta.librelane_version',
    meta['librelane_version'],
    expected['librelane_version'],
  );
  check('PDK', resolved['PDK'], expected['pdk']);
  check(
    'STD_CELL_LIBRARY',
    resolved['STD_CELL_LIBRARY'],
    expected['std_cell_library'],
  );

  final metricsFile = File('${run.path}/final/metrics.json');
  check(
    'final/metrics.json present',
    metricsFile.existsSync(),
    expected['final_metrics'],
  );

  // Facts the tool builds of two platforms are known to disagree on
  // (`differs_by_platform`): held exactly on the committed capture, and not
  // compared on a live rerun on another machine.
  final differs = exactMetrics
      ? const <String, dynamic>{}
      : expected['differs_by_platform'] as Map<String, dynamic>? ??
            const <String, dynamic>{};
  final looseSteps = <String>{
    for (final s in differs['steps_without_state_out'] as List<dynamic>? ?? [])
      s as String,
  };
  final looseMetrics = <String>{
    for (final m in differs['metrics'] as List<dynamic>? ?? []) m as String,
  };

  final dirs = stepDirs(run);
  check('last step directory', dirName(dirs.last), expected['last_step']);
  final withoutStateOut = [
    for (final d in dirs)
      if (!File('${d.path}/state_out.json').existsSync() &&
          !looseSteps.contains(dirName(d)))
        dirName(d),
  ];
  // A platform-dependent step is left out of both sides: the capture may
  // have been made on either platform.
  check('steps without state_out.json', withoutStateOut, [
    for (final s in expected['steps_without_state_out'] as List<dynamic>)
      if (!looseSteps.contains(s)) s,
  ]);

  final flowLog = File('${run.path}/flow.log').readAsStringSync();
  final ids = stepIdsFromFlowLog(flowLog);
  final idsWanted = expected['step_ids'] as Map<String, dynamic>? ?? const {};
  for (final e in idsWanted.entries) {
    check('step id of ${e.key}', ids[e.key], e.value);
  }
  final gatedOff = RegExp(
    "^Skipping step '([^']+)'",
    multiLine: true,
  ).allMatches(flowLog).map((m) => m[1]!).toList();
  check(
    'steps skipped by a gating variable',
    gatedOff,
    expected['gated_off_steps'],
  );

  final errorLog = File('${run.path}/error.log').readAsStringSync();
  for (final text in (expected['error_log_contains'] as List<dynamic>)) {
    if (!errorLog.contains(text as String)) {
      diffs.add('error.log lacks "$text"');
    }
  }
  if ((expected['error_log_contains'] as List<dynamic>).isEmpty &&
      errorLog.trim().isNotEmpty) {
    diffs.add('error.log is not empty');
  }

  final wantMetrics = expected['metrics'] as Map<String, dynamic>;
  if (metricsFile.existsSync()) {
    final metrics = readJson(metricsFile.path);
    for (final key in (expected['absent_metrics'] as List<dynamic>? ?? [])) {
      if (metrics.containsKey(key)) diffs.add('metric $key is present');
    }
    for (final e in wantMetrics.entries) {
      if (looseMetrics.contains(e.key)) continue;
      final got = metrics[e.key];
      if (got is! num) {
        diffs.add('metric ${e.key} missing');
      } else if (exactMetrics) {
        check('metric ${e.key}', got, e.value);
      } else {
        check('sign of metric ${e.key}', _sign(got), _sign(e.value as num));
      }
    }
  }

  final worst = expected['worst_register_setup_path'] as Map<String, dynamic>?;
  if (worst != null && mapping != null) {
    diffs.addAll(_worstPathDifferences(run, worst, mapping));
  }
  return diffs;
}

List<String> _worstPathDifferences(
  Directory run,
  Map<String, dynamic> worst,
  Map<String, dynamic> mapping,
) {
  final sta = stepDir(run, 'openroad-stapostpnr');
  final synth = stepDir(run, 'yosys-synthesis');
  if (sta == null || synth == null) return ['no STA or synthesis step'];
  final corner = worst['corner'] as String;
  final report = File('${sta.path}/$corner/max.rpt');
  if (!report.existsSync()) return ['missing ${report.path}'];
  final paths =
      parseStaReport(
            report.readAsStringSync(),
          )
          // Register to register: an input-port path (from `d`) can be the
          // worst at a long clock period, and the RTL says nothing of its rank.
          .where(
            (p) =>
                p.startKind.contains('flip-flop') &&
                p.endKind.contains('flip-flop'),
          )
          .toList()
        ..sort((a, b) => a.slack.compareTo(b.slack));
  if (paths.isEmpty) return ['no register endpoint in $corner'];
  final top = mapping['top'] as String;
  final sidecar = Sidecar(
    readJson('${synth.path}/$top.nl.v.json'),
    top,
  );
  final registers = (mapping['registers'] as List<dynamic>)
      .cast<String>()
      .toSet();
  String? reg(String instance) {
    final nets = sidecar.qNets(instance);
    if (nets == null) return null;
    for (final n in nets) {
      final r = registerOf(n, registers);
      if (r != null) return r;
    }
    return null;
  }

  final p = paths.first;
  final diffs = <String>[];
  final end = reg(p.end);
  if (end != mapping['end_register']) {
    diffs.add('worst endpoint ${p.end} maps to $end');
  }
  final start = reg(p.start);
  if (!(mapping['start_registers'] as List<dynamic>).contains(start)) {
    diffs.add('worst startpoint ${p.start} maps to $start');
  }
  if (worst['met'] != p.met) {
    diffs.add('worst register path met=${p.met}, want ${worst['met']}');
  }
  return diffs;
}
