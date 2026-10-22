// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'formal_fixture_checks.dart';

/// The committed EQY corpus directory.
String get eqyCorpus => p.absolute(kFormalFixtureRoot, 'eqy');

/// Each EQY run's partitions and what each must end as, written by hand
/// from `eqy/eqy.expected.json` (its `why` for each run, backed by the
/// simulation oracle), never from EQY's output. `true` means proved
/// equivalent, `false` not equivalent.
const Map<String, Map<String, bool>> kEqyPartitionExpectations = {
  // A false FAIL: the correct netlist, cut at the gate wire named r. y and
  // r prove; z cannot, because ABC restructured its cone past r.
  'alu_pass': {'alu.z': false, 'alu.y': true, 'alu.r': true},
  // gold-nomatch r: both registered outputs prove.
  'alu_pass2': {'alu.z': true, 'alu.y': true},
  // The mutant at the default cut: r holds the flipped gate, z fails for
  // the alu_pass reason and the mutation, y is a register on the cut r.
  'alu_fail': {'alu.z': false, 'alu.y': true, 'alu.r': false},
  // The mutant with gold-nomatch r: the flipped gate feeds y and z.
  'alu_fail2': {'alu.z': false, 'alu.y': false},
};

/// The captured EQY log of [run], as lines.
List<String> capturedEqyLog(String run) => const LineSplitter().convert(
  File(p.join(eqyCorpus, 'captured', run, 'eqy.log')).readAsStringSync(),
);

/// The exit code the captured [run] reported.
int capturedEqyExit(String run) => int.parse(
  File(
    p.join(eqyCorpus, 'captured', run, 'eqy.exit'),
  ).readAsStringSync().trim(),
);

/// Rebuilds [run]'s EQY work directory in [workDir] in the layout `eqy`
/// writes (simcrux guide §26.4) from the corpus, which keeps only the files
/// a reader needs, flattened per strategy:
///
/// | corpus `captured/<run>/` | work directory |
/// |---|---|
/// | `partition.list`, `summary_targets.list`, `matched.ids` | same name |
/// | `eqy.log` | `logfile.txt` |
/// | `verdict_marker` | a `PASS` or `FAIL` file |
/// | `strategies/<p>/<s>/status` | same |
/// | `strategies/<p>/<s>/sby.log` | `strategies/<p>/<s>/<p>/logfile.txt` |
/// | `strategies/<p>/<s>/trace*.vcd` | `strategies/<p>/<s>/<p>/engine_0/` |
void stageEqyWorkdir(String run, String workDir) {
  final from = p.join(eqyCorpus, 'captured', run);
  Directory(workDir).createSync(recursive: true);
  for (final name in const [
    'partition.list',
    'summary_targets.list',
    'matched.ids',
  ]) {
    final file = File(p.join(from, name));
    if (file.existsSync()) file.copySync(p.join(workDir, name));
  }
  File(p.join(from, 'eqy.log')).copySync(p.join(workDir, 'logfile.txt'));
  final marker = File(
    p.join(from, 'verdict_marker'),
  ).readAsStringSync().trim();
  File(p.join(workDir, marker)).writeAsStringSync('');
  final strategies = Directory(p.join(from, 'strategies'));
  for (final partition in strategies.listSync().whereType<Directory>()) {
    final name = p.basename(partition.path);
    for (final strategy in partition.listSync().whereType<Directory>()) {
      final s = p.basename(strategy.path);
      final dest = p.join(workDir, 'strategies', name, s);
      Directory(p.join(dest, name, 'engine_0')).createSync(recursive: true);
      for (final file in strategy.listSync().whereType<File>()) {
        final base = p.basename(file.path);
        final target = switch (base) {
          'status' => p.join(dest, 'status'),
          'sby.log' => p.join(dest, name, 'logfile.txt'),
          _ => p.join(dest, name, 'engine_0', base),
        };
        file.copySync(target);
      }
    }
  }
}
