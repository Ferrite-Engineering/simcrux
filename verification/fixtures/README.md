# SimCrux (Open Core) — Verification Fixtures

Committed test fixtures consumed by `VERIFICATION_GUIDE.md` and the corresponding integration tests.

## Layout

```
fixtures/
├── golden_compare/      # `golden_compare` detector cases: case.json + dumps + expected.json
├── orchestration/       # scheduler/reaper scenarios replayed through a fake process runner
│   ├── <scenario>/generated/   # simcrux.yaml + behaviors.json + expected_results.ndjson
│   └── helpers/README.md       # how the corpus is regenerated and what each file holds
└── riscv_formal/        # pre-captured SymbiYosys outputs for `riscv: { mode: demo }` (see its README.md)
```

Each corpus has a regenerator under `../../tool/`:

| Corpus | Regenerate with |
|---|---|
| `golden_compare/` | `dart run tool/generate_golden_compare_fixtures.dart` |
| `orchestration/` | `dart run tool/generate_orchestration_fixtures.dart` (also writes `test/fixtures/orchestration/`) |
| `riscv_formal/` | `dart run tool/generate_riscv_formal_fixtures.dart` |

## Adding a new fixture

1. Create the subfolder if it does not exist
2. Commit the artifact + `expected*.json` companion in the same commit as the feature it verifies
3. Add or update the regenerator script under `../../tool/` and document the command in the corpus's own README (as `orchestration/helpers/README.md` and `riscv_formal/README.md` do) and in the table above
4. Reference the fixture from the matching `VERIFICATION_GUIDE.md` section
5. Add the corresponding bullet to `VERIFICATION_CHECKLIST.md`

## `golden_compare/`

One directory per case, each holding:

- `case.json` — the inputs: description, `profile`, and the two filenames.
  Hand-written; never regenerated.
- the dump files themselves — **absent** in the `missing_dut` case, and a
  zero-byte file in `empty_dut`. Both are load-bearing.
- `expected.json` — the golden: the verdict the real `GoldenCompareDetector`
  produces, the full `GoldenComparison`, and the `golden.*` metrics a driver
  would emit. Written by the regenerator, never by hand.

```bash
dart run tool/generate_golden_compare_fixtures.dart
```

The dumps are **hand-authored**, not derived from `riscv-arch-test`, so no
third-party attribution obligation is created and the corpus can be shaped
to the exact cases we need. `golden_compare_fixtures_test.dart` replays every
case through the production detector and comparator and asserts the required
case list by name, so a deleted case fails rather than quietly reducing
coverage.

A shipped feature whose fixtures are missing is a code-review-blocking defect — same rule as WaveCrux.
