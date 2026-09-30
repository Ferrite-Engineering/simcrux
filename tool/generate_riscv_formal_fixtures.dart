// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Regenerates the counterexample/cover **traces** and the `expected.json`
// golden for every riscv-formal demo fixture case.
//
//   dart run tool/generate_riscv_formal_fixtures.dart
//
// Each case directory under `verification/fixtures/riscv_formal/` holds:
//
//   case.json     — the input declaration (check, group, proof mode,
//                   depth, log filename, traces, exit code). Hand-written;
//                   never regenerated.
//   sby.log       — the captured SymbiYosys output. Hand-written.
//   engine_*/…    — the trace files the log announces. **Generated** from
//                   the hand-authored step tables in `riscv_formal_traces
//                   .dart`, so the VCD text is mechanical and the retire
//                   sequence it describes is the thing under review.
//   expected.json — the golden this script writes: what the real
//                   SbyLogReader parses out of the log, and the status the
//                   real RiscvFormalVerdict mapping turns it into.
//
// The verdict is produced by running the **production** parser and the
// **production** verdict→status mapping against the **committed** log —
// not by restating what the fixture author expected — so a regression in
// either shows up as a diff here and in
// `test/services/simulator/riscv_formal_fixtures_test.dart`.
//
// Nothing in the corpus is derived from riscv-formal or SymbiYosys; the
// logs are hand-authored in `sby`'s output shape, which is the shape the
// parser must handle, and the traces are hand-authored RVFI bundles of a
// fictional core. That keeps the fixtures free of any third-party
// attribution obligation.
import 'dart:convert';
import 'dart:io';

import 'package:simcrux/domain/models/sby_outcome.dart';

import 'riscv_formal_traces.dart';

const String fixtureRoot = 'verification/fixtures/riscv_formal';

Future<void> main() async {
  final root = Directory(fixtureRoot);
  if (!root.existsSync()) {
    stderr.writeln(
      'Run from the package root (cwd = simcrux/); $fixtureRoot not found.',
    );
    exitCode = 1;
    return;
  }

  // Traces first: `expected.json` is derived from the log, but a case whose
  // declared trace is missing is a corpus that cannot support the
  // counterexample hand-off to WaveCrux, and writing the goldens over a broken
  // corpus hides that.
  for (final spec in kRiscvFormalTraces) {
    final out = File('$fixtureRoot/${spec.relativePath}');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(spec.toVcd());
    stdout.writeln(
      'wrote ${out.path}  → ${spec.steps.length} steps, '
      '${kRvfiChannelOrder.length} RVFI channels',
    );
  }

  final cases = root.listSync().whereType<Directory>().toList(growable: false)
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in cases) {
    final expected = buildExpected(dir);
    final out = File('${dir.path}/expected.json');
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(expected)}\n',
    );
    stdout.writeln('wrote ${out.path}  → ${expected['status']}');
  }
}

/// Computes the expected record for one fixture case by running the
/// production parser against its committed log.
Map<String, Object?> buildExpected(Directory dir) {
  final decl =
      jsonDecode(File('${dir.path}/case.json').readAsStringSync())
          as Map<String, Object?>;
  final logName = decl['log'] as String? ?? 'sby.log';
  final logFile = File('${dir.path}/$logName');
  final outcome = SbyLogReader.parse(
    logFile.existsSync() ? logFile.readAsStringSync() : '',
  );
  return <String, Object?>{
    'description': decl['description'],
    'check': decl['check'],
    'group': decl['group'],
    // The two facts the whole driver turns on.
    'verdict': outcome.verdict.wireName,
    'status': outcome.verdict.status.name,
    'return_code': outcome.returnCode,
    'depth_reached': outcome.depthReached,
    'engine': outcome.engine,
    'elapsed_seconds': outcome.elapsedSeconds,
    'traces': outcome.traces,
  };
}
