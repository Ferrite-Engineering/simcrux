# SimCrux (Open Core) — Verification Fixtures

Committed test fixtures consumed by `VERIFICATION_GUIDE.md` and the corresponding integration tests.

## Layout

```
fixtures/
├── golden_compare/      # `golden_compare` detector cases: case.json + dumps + expected.json
├── orchestration/       # scheduler/reaper scenarios replayed through a fake process runner
│   ├── <scenario>/generated/   # simcrux.yaml + behaviors.json + expected_results.ndjson
│   └── helpers/README.md       # how the corpus is regenerated and what each file holds
├── rohd/                # real `dart test` JSON from ROHD and ROHD-VF tests, pinned ROHD commits; see its README.md
├── riscv_formal/        # pre-captured SymbiYosys outputs for `riscv: { mode: demo }` (see its README.md)
├── formal/              # sby, EQY and SVA-frontend corpus with hand-written expectations; see its PROVENANCE.md
│   ├── sby/<case>/      # RTL + .sby + <case>.expected.json; captured/ holds logs, status stream, status.sqlite, VCDs
│   ├── sva_matrix/      # the 51 SVA construct probes, built-in and yosys-slang frontends
│   ├── eqy/             # ALU gold, gate and mutant netlists, four .eqy configs, a simulation oracle, captured work dirs
│   ├── eqy_flow/        # the sky130 RTL-to-LibreLane-netlist EQY recipe and its measured outcome; see RECIPE-GATE.md
│   └── schemas/<build>/ # status-stream, status.sqlite and EQY work-dir shapes, one directory per OSS CAD Suite build
└── flow/
    ├── nextpnr/         # captured nextpnr runs (iCE40, ECP5, Gowin, GateMate) + the RTL; see its PROVENANCE.md
    ├── fusesoc/         # one FuseSoC/Edalize servant run with no nextpnr report; see its PROVENANCE.md
    ├── librelane/       # trimmed LibreLane runs per release (<version>/<case>/run) + designs; see its PROVENANCE.md and MAPPING-GATE.md
    └── gate_level/      # self-checking testbenches for the LibreLane designs, the MAC case with port VCDs, a reset-less register (resetless/); see PROVENANCE.md and GLS-GATE.md
```

Each corpus has a regenerator under `../../tool/`:

| Corpus | Regenerate with |
|---|---|
| `golden_compare/` | `dart run tool/generate_golden_compare_fixtures.dart` |
| `orchestration/` | `dart run tool/generate_orchestration_fixtures.dart` (also writes `test/fixtures/orchestration/`) |
| `riscv_formal/` | `dart run tool/generate_riscv_formal_fixtures.dart` |
| `rohd/` | `verification/fixtures/rohd/generator/generate.sh <empty work dir> verification/fixtures/rohd dart-test.json` (needs network; pinned ROHD commits) |
| `formal/` | `tool/regenerate_formal_fixtures.sh --suite <newest oss-cad-suite> --suite <previous> --suite <one before>` (captures only; it never writes or touches a `*.expected.*` file) |
| `flow/nextpnr/` | `tool/flow/regen_nextpnr_fixtures.sh --suite <oss-cad-suite dir>` (captures only; the expectation JSON files beside the captures are hand-written) |
| `flow/fusesoc/` | `tool/flow/regen_fusesoc_fixture.sh --suite <oss-cad-suite dir> --yosys-dir <dir>` (needs network) |
| `flow/librelane/` | `tool/flow/regen_librelane_fixtures.sh [--case <name>]`, inside a LibreLane checkout's Nix shell (captures and trims with `tool/flow/trim_run_fixture.py`; the expectation JSON files are hand-written) |
| `flow/gate_level/`, `formal/eqy_flow/` | `python3 -I tool/flow/gate_level/regen_gate_level.py --suite <oss-cad-suite dir> --out <dir> [--run picorv32=<LibreLane run>] [--run picorv32_cg=<run>]` (re-measures and writes `gate_level.json` under `--out`, never into the fixtures; `gls.expected.json` and `recipe.expected.json` are hand-written) |

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
