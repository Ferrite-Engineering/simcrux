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
