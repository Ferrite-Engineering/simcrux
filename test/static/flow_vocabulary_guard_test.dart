// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Flow results are findings, never signoff. This guard scans for the claim
/// family, not one phrasing, in every Flow string a user reads:
///
/// - every Flow message in the five ARB files;
/// - the HTML export template (`lib/services/flow/flow_export.dart`), code
///   not comments;
/// - the docs-site Flow pages, once they exist.
///
/// The words: signoff (and its spellings), tapeout-ready, certif…,
/// qualified, guarantee, and "RTL to GDS" unless the same sentence says
/// "open PDK". Gate-level strings are also scanned for the timing-check
/// words (gate-level simulation has no timing checks, so none can be a
/// result).
///
/// The one disclaimer that names signoff in the negative is fenced: in the
/// ARB by its key, [kFencedArbKeys]; in Dart between
/// `// vocabulary-guard: disclaimer begin` and `... end` comments.
void main() {
  const fencedArbKeys = kFencedArbKeys;
  final claims = <RegExp>[
    RegExp('sign-?off', caseSensitive: false),
    RegExp(r'sign\s+off', caseSensitive: false),
    RegExp(r'tape-?\s?out[- ]ready', caseSensitive: false),
    RegExp('certif', caseSensitive: false),
    RegExp(r'\bqualified\b', caseSensitive: false),
    RegExp('guarantee', caseSensitive: false),
  ];
  final timingClaims = <RegExp>[
    RegExp('timing (violation|failure)', caseSensitive: false),
    RegExp('(setup|hold) violation', caseSensitive: false),
    RegExp('timing clean', caseSensitive: false),
  ];
  final rtlToGds = RegExp('RTL[ -]to[ -]GDS', caseSensitive: false);

  /// Whether [key] is a Flow message: the panel, the actions, the dock
  /// tab, the inspector hand-off, Settings > Implementation flow, the
  /// diagnostics rows.
  bool isFlowKey(String key) =>
      key.startsWith('flow') ||
      key.startsWith('inspectorFlow') ||
      key.startsWith('inspectorActionOpenIn') ||
      key.startsWith('settingsFlow') ||
      key == 'settingsImplementationFlowSection' ||
      key == 'dockTabFlowRuns' ||
      key.startsWith('diagnosticsTabFlow') ||
      key.startsWith('diagnosticsTabRowFlow') ||
      // Gate-level simulation: its results, reasons and notes, the
      // inspector's section and button, and the three actions.
      key.startsWith('gls') ||
      key == 'inspectorSectionGateLevel' ||
      key == 'inspectorActionOpenGateLevelWaveform' ||
      RegExp(
        '^action(ToggleFlowRuns|RunFlowEntry|OpenIn|Ingest|OpenFlow|'
        'WriteFlow|RunGateLevel|OpenGateLevel|OpenGls)',
      ).hasMatch(key);

  bool gateLevel(String key) => RegExp('^gls|Gls|GateLevel|Sdf').hasMatch(key);

  /// The offences in [text], named by [where].
  List<String> offences(String where, String text, {bool timing = false}) {
    final out = <String>[
      for (final re in [...claims, if (timing) ...timingClaims])
        if (re.hasMatch(text)) '$where: ${re.pattern}',
    ];
    for (final sentence in text.split(RegExp(r'(?<=[.!?])\s'))) {
      if (rtlToGds.hasMatch(sentence) &&
          !RegExp('open PDK', caseSensitive: false).hasMatch(sentence)) {
        out.add('$where: unscoped RTL to GDS');
      }
    }
    return out;
  }

  final arbs = Directory(
    'lib/l10n',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();

  test('the five ARB files are found and hold Flow messages', () {
    expect(arbs, hasLength(5));
    final en =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    final flowKeys = en.keys.where((k) => !k.startsWith('@') && isFlowKey(k));
    expect(flowKeys.length, greaterThan(100));
    for (final key in fencedArbKeys) {
      expect(en, contains(key), reason: 'a fenced key must exist');
    }
  });

  test('no Flow message makes a signoff claim', () {
    final found = <String>[];
    for (final arb in arbs) {
      final json = jsonDecode(arb.readAsStringSync()) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in json.entries) {
        if (key.startsWith('@') || value is! String || !isFlowKey(key)) {
          continue;
        }
        if (fencedArbKeys.contains(key)) continue;
        found.addAll(
          offences(
            '${p.basename(arb.path)} $key',
            value,
            timing: gateLevel(key),
          ),
        );
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('the fenced disclaimer names signoff only in the negative', () {
    for (final arb in arbs) {
      final json = jsonDecode(arb.readAsStringSync()) as Map<String, dynamic>;
      for (final key in fencedArbKeys) {
        final value = json[key] as String;
        // Every claim word the disclaimer carries is negated in English;
        // the translations carry none of the English words at all.
        final hits = offences(key, value);
        if (arb.path.endsWith('app_en.arb')) {
          expect(value, contains('not signoff'), reason: key);
          expect(hits, hasLength(1), reason: hits.join('\n'));
        } else {
          expect(hits, isEmpty, reason: '${arb.path} $key');
        }
      }
    }
  });

  test('the HTML export template makes no claim outside its fence', () {
    final lines = File('lib/services/flow/flow_export.dart').readAsLinesSync();
    final found = <String>[];
    var fenced = false;
    var fences = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line == '// vocabulary-guard: disclaimer begin') {
        fenced = true;
        fences++;
        continue;
      }
      if (line == '// vocabulary-guard: disclaimer end') {
        fenced = false;
        continue;
      }
      if (fenced || line.startsWith('//')) continue;
      found.addAll(offences('flow_export.dart:${i + 1}', line));
    }
    expect(fences, 1, reason: 'exactly one fenced disclaimer');
    expect(fenced, isFalse, reason: 'the fence is closed');
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('the gate-level code makes no signoff or timing claim', () {
    // Messages the CLI and the exporters print: a functional gate-level
    // simulation has unit delays and no timing checks, so none of the
    // timing words can be a result, and nothing is signoff.
    final files = Directory('lib/services/flow/gate_level')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files.length, greaterThan(5));
    final found = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('//')) continue;
        found.addAll(
          offences('${p.basename(file.path)}:${i + 1}', line, timing: true),
        );
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('the docs-site Flow pages make no claim (from 1.2)', () {
    final docs = Directory('docs-site/docs');
    expect(docs.existsSync(), isTrue);
    final pages = docs
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.md') &&
              (p.basename(f.path).startsWith('flow') ||
                  p.split(f.path).contains('flow')),
        );
    final found = <String>[];
    for (final page in pages) {
      var fenced = false;
      final lines = page.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.contains('<!-- vocabulary-guard: disclaimer begin -->')) {
          fenced = true;
          continue;
        }
        if (line.contains('<!-- vocabulary-guard: disclaimer end -->')) {
          fenced = false;
          continue;
        }
        if (fenced) continue;
        found.addAll(offences('${page.path}:${i + 1}', line));
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('the guard catches each claim it names', () {
    for (final claim in const [
      'Ready for signoff',
      'sign-off quality',
      'tapeout-ready layout',
      'certified results',
      'a qualified flow',
      'guaranteed timing',
      'RTL to GDS in one click.',
    ]) {
      expect(offences('probe', claim), isNotEmpty, reason: claim);
    }
    expect(offences('probe', 'RTL to GDS with an open PDK.'), isEmpty);
    expect(offences('probe', 'no setup violation', timing: true), isNotEmpty);
  });
}

/// The ARB keys of the one disclaimer allowed to name signoff, in the
/// negative.
const Set<String> kFencedArbKeys = <String>{'flowFindingsNote'};
