// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Generates the orchestration-robustness corpus (layer 1) into BOTH the
// unit-test tree and the release-verification mirror in one pass, so the
// two cannot drift. Each scenario writes a `simcrux.yaml`, a
// `behaviors.json` (the fake-runner script), and an
// `expected_results.ndjson` golden produced by replaying the scenario
// through the real LocalJobScheduler + the in-process FakeProcessRunner
// (no real simulator). See lib/services/job_scheduler/orchestration_fixture.dart
// and the sibling orchestration_golden_test.dart.
//
//   dart run tool/generate_orchestration_fixtures.dart
import 'dart:io';

import 'package:simcrux/services/job_scheduler/orchestration_fixture.dart';

const List<String> _trees = <String>[
  'test/fixtures/orchestration',
  'verification/fixtures/orchestration',
];

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('simcrux_fixture_gen_');
  try {
    for (final scenario in orchestrationScenarios()) {
      final rows = await replayOrchestrationScenario(
        scenario,
        runRoot: tmp.path,
      );
      final ndjson = orchestrationNdjson(rows);
      for (final tree in _trees) {
        final dir = Directory('$tree/${scenario.name}/generated')
          ..createSync(recursive: true);
        File(
          '${dir.path}/simcrux.yaml',
        ).writeAsStringSync(scenario.simcruxYaml);
        File(
          '${dir.path}/behaviors.json',
        ).writeAsStringSync(scenario.behaviorsJson);
        File('${dir.path}/expected_results.ndjson').writeAsStringSync(ndjson);
        stdout.writeln('wrote ${dir.path} (${rows.length} rows)');
      }
    }
    _writeHelpersReadme();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void _writeHelpersReadme() {
  const readme = '''
# Orchestration fixture corpus

Regenerate with:

```bash
dart run tool/generate_orchestration_fixtures.dart
```

Each `<scenario>/generated/` holds three files:

- `simcrux.yaml` — the real SimCrux config the scenario models (the input).
- `behaviors.json` — the deterministic per-test fake-process script the
  `FakeProcessRunner` replays (exit code, delay, whether it ignores
  SIGTERM, how many grandchildren it forks). **No real simulator runs.**
- `expected_results.ndjson` — the golden: one JSON object per test in
  scheduler emission order, with bucketed (machine-stable) durations and
  the recorded `killSignal` (the kill *path*, not just the outcome).

The golden is produced by replaying the scenario through the real
`LocalJobScheduler` + `FakeProcessRunner`; `orchestration_golden_test.dart`
re-runs the same replay and diffs against the committed golden, so a
scheduler/reaper regression is caught. The generator writes this corpus
into both `test/fixtures/orchestration/` (the unit backbone) and
`verification/fixtures/orchestration/` (the release sign-off mirror).
''';
  for (final tree in _trees) {
    final dir = Directory('$tree/helpers')..createSync(recursive: true);
    File('${dir.path}/README.md').writeAsStringSync(readme);
  }
}
