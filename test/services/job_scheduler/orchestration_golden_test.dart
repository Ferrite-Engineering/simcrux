// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/job_scheduler/orchestration_fixture.dart';

/// Layer-4 golden replay for the orchestration corpus: each committed scenario is
/// replayed through the real [LocalJobScheduler] + the in-process
/// [FakeProcessRunner] (no real simulator) and the resulting per-test
/// rows — status, exit code, bucketed duration, and the recorded
/// `killSignal` (the kill *path*) — are diffed against the committed
/// `expected_results.ndjson`.
///
/// Regenerate the corpus after an intended scheduler/reaper change with:
///
///   dart run tool/generate_orchestration_fixtures.dart
///
/// MUTATION: a regression that drops the SIGKILL escalation, fails to
/// reap a process tree, or stops threading `killSignal` through the
/// driver → scheduler → result changes a committed golden line, so the
/// matching scenario goes red here without any test edit.
/// Every tree the generator writes the corpus into. The unit backbone
/// and the release-verification mirror are both committed, and both are
/// checked here — the copy a human opens in the app at release sign-off
/// is the `verification/` one, so leaving it unvalidated is exactly how
/// an unloadable config reaches a user.
const List<String> _corpusTrees = <String>[
  'test/fixtures/orchestration',
  'verification/fixtures/orchestration',
];

void main() {
  final corpusRoot = _corpusTrees.first;

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_golden_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  for (final scenario in orchestrationScenarios()) {
    group('orchestration golden — ${scenario.name}', () {
      final dir = '$corpusRoot/${scenario.name}/generated';

      test('corpus files are committed under generated/', () {
        for (final tree in _corpusTrees) {
          final treeDir = '$tree/${scenario.name}/generated';
          for (final file in const <String>[
            'simcrux.yaml',
            'behaviors.json',
            'expected_results.ndjson',
          ]) {
            expect(
              File('$treeDir/$file').existsSync(),
              isTrue,
              reason: 'missing $treeDir/$file',
            );
          }
        }
      });

      // The guard that would have caught the schema rot: existence is
      // not validity. Every committed `simcrux.yaml` — in BOTH trees —
      // is parsed by the real [ConfigLoader], the same code path the
      // app uses when a user opens the file, and the loaded specs are
      // diffed against the specs the scheduler actually runs. Without
      // this the YAML is decorative and free to drift into a schema the
      // loader rejects (which is precisely what happened: no `version`,
      // top-level `simulator:`/`tests:`, `pass_fail.detector`).
      test(
        'committed simcrux.yaml loads and mirrors the scenario specs',
        () async {
          for (final tree in _corpusTrees) {
            final path = '$tree/${scenario.name}/generated/simcrux.yaml';
            final config = await ConfigLoader().load(path);

            expect(
              config.loadWarnings,
              isEmpty,
              reason: '$path loaded with warnings',
            );
            expect(
              config.suites.map((s) => s.name),
              <String>[scenario.specs.first.suiteName],
              reason: '$path: unexpected suite set',
            );
            expect(
              config.defaultSimulatorId,
              scenario.modelledSimulatorId,
              reason: '$path: `defaults.simulator` drifted from the scenario',
            );

            final loaded = config.suites.single.tests;
            expect(
              loaded.map(_mirrorOf),
              scenario.specs.map(_mirrorOf),
              reason:
                  '$path no longer describes the tests the scheduler runs '
                  '(name / suite / top / seed / timeout)',
            );
            // `simulatorId` is the one field that cannot round-trip: the
            // replay must run with no simulator installed, so the specs
            // name the in-process `fake` driver while the config names the
            // simulator the scenario models (asserted above).
            expect(
              loaded.map((t) => t.simulatorId).toSet(),
              <String>{scenario.modelledSimulatorId},
            );
          }
        },
      );

      test('replay matches the committed golden', () async {
        final rows = await replayOrchestrationScenario(
          scenario,
          runRoot: tmp.path,
        );
        final actual = orchestrationNdjson(rows);
        // Normalize CRLF→LF: the committed golden is LF, but git may check it
        // out as CRLF on Windows. The replay emits LF, so compare on LF terms.
        final expected = File(
          '$dir/expected_results.ndjson',
        ).readAsStringSync().replaceAll('\r\n', '\n');
        expect(actual.replaceAll('\r\n', '\n'), expected);
      });
    });
  }
}

/// The slice of a [TestSpec] the committed `simcrux.yaml` and the
/// scheduler's specs must agree on, in a form `expect` can diff
/// readably.
///
/// [TestSpec.id] and [TestSpec.simulatorId] are excluded by design and
/// asserted separately — see the doc on [OrchestrationScenario.specs].
Map<String, Object?> _mirrorOf(TestSpec spec) => <String, Object?>{
  'suite': spec.suiteName,
  'name': spec.name,
  'top': spec.top,
  'seed': spec.seed,
  'timeoutMs': spec.timeout.inMilliseconds,
};
