# SimCrux examples

Ready-to-open `simcrux.yaml` projects. Open one with **File → Open Config…**
(or the folder button on the toolbar, or `Cmd/Ctrl+O`), then run it with
**Tools → Run Regression** (`F5`).

Every example here is self-contained: it points only at fixtures committed
in this repository, using paths relative to its own `simcrux.yaml`, so it
works from any checkout without editing.

| Example | What it demonstrates | Needs a toolchain? |
|---|---|---|
| [`riscv-compatibility-demo/`](riscv-compatibility-demo/simcrux.yaml) | The `riscv_arch` driver and the `golden_compare` detector running the RISC-V architectural-compatibility flow against a committed signature corpus. | **No** |
| [`riscv-formal-demo/`](riscv-formal-demo/simcrux.yaml) | The `riscv_formal` driver replaying committed SymbiYosys outputs — one bounded proof per test, with the four-way PASS / FAIL / UNKNOWN / TIMEOUT verdict distinction. | **No** |

## Neither RISC-V example needs a toolchain

Both run in `mode: demo`, which is declared **in the config, never in the
environment**. Demo mode skips only the *spawn* steps and proceeds through
the identical signature reading, log parsing, comparison, metric emission
and event construction as a real run — it is the same driver, not a
stand-in. So you need:

- no RISC-V cross-compiler (`riscv32-unknown-elf-gcc`),
- no reference model (Spike or Sail),
- no `riscv-arch-test` or `riscv-formal` checkout,
- no SymbiYosys, Yosys or SMT solver,
- and no network.

The same two configs are executed end to end by
[`test/examples/riscv_demo_examples_test.dart`](../test/examples/riscv_demo_examples_test.dart)
through the real `ConfigLoader` and the real `LocalJobScheduler`, with a
process launcher that **throws if anything is ever spawned**. That test is
the guarantee behind the "no toolchain" claim, and it is why these files
cannot silently rot into something that no longer opens.

## Neither example is all-green, on purpose

A report that shows only passes demonstrates nothing. The corpora are shaped
to cover the cases where a naive implementation goes quietly wrong.

**`riscv-compatibility-demo`** — 8 tests, **3 pass / 5 fail**, grouped into
four extension suites so the per-extension rollup has something to roll up:

| Suite | Test | Result | Why it is in the corpus |
|---|---|---|---|
| `I` | `clean_pass` | pass | identical signatures |
| `I` | `first_word_mismatch` | fail | diverges at word 0 — the boundary an off-by-one hides |
| `M` | `mid_file_mismatch` | fail | diverges mid-file |
| `M` | `length_mismatch` | fail | the DUT signature is a prefix of the reference |
| `C` | `empty_dut` | fail | an empty DUT dump must never report `vacuous` |
| `C` | `missing_dut` | fail | a missing DUT dump must never report `unknown` |
| `Zicsr` | `format_variance_riscv` | pass | read under `profile: riscv_signature` |
| `Zicsr` | `format_variance_generic` | pass | the *same bytes*; they report `fail` only under `profile: generic`, and this driver is ISA-coupled by construction |

**`riscv-formal-demo`** — 7 tests, **2 pass / 5 fail**, one per verdict:

| Suite | Test | Verdict | Result |
|---|---|---|---|
| `insn` | `insn_add_pass` | `PASS` | pass |
| `insn` | `insn_sub_counterexample` | `FAIL` | fail — with the counterexample VCD, which is the "Debug in WaveCrux" hand-off |
| `pc_fwd` | `pc_fwd_unknown` | `UNKNOWN` | fail — nothing proved, nothing refuted |
| `reg` | `reg_timeout` | `TIMEOUT` | fail — SymbiYosys's own solver budget, deliberately *not* `TestStatus.timeout`, which would mean SimCrux killed the job |
| `causal` | `causal_error` | `ERROR` | fail — Yosys could not read a source, so the proof never ran |
| `liveness` | `liveness_no_outcome` | `NO_OUTCOME` | fail — no `DONE (…)` line at all and the process exits **0**; reading the exit code would report a proof that never happened as a pass |
| `cover` | `cover_multi_trace` | `PASS` | pass — two cover statements reached, one trace each |

## Pointing them at a real core

Each file ends with a short note on the switch. In both cases it is
`mode: normal` plus the plumbing that mode needs — for compatibility, your
DUT command, the arch-test suite and a reference model; for formal, the
`checks/` directory riscv-formal's `genchecks.py` writes.

**You do not write the per-test entries by hand.** Two importers enumerate
a checkout for you, from the menu or from a script:

| | Menu | Command |
|---|---|---|
| `riscv-arch-test` | File → **Import RISC-V Architectural Tests…** | `simcrux import-riscv-arch-test <suite-path>` |
| riscv-formal | File → **Import riscv-formal Checks…** | `simcrux import-riscv-formal <checks-path>` |

```bash
simcrux import-riscv-arch-test ~/src/riscv-arch-test \
  --extensions I,M,C \
  --isa rv32imc_zicsr_zifencei \
  --toolchain-prefix riscv64-unknown-elf- \
  --reference-model spike \
  --target-command './my_core --elf {elf} --signature {signature}'
```

`--target-command` is the one thing an importer cannot work out for you: it
is how *your* core runs one architectural test, and `mode: normal` will not
load without it. Everything else has a default or is optional. Run either
sub-command with `--help` for the full flag list.

What comes back is ordinary `simcrux.yaml` — one test per architectural test
or per bounded proof, with a header comment naming the source directory and
any import warnings. The file is yours to read, diff, edit and commit;
re-running the importer overwrites it.

Nothing on the `riscv:` path is tier-gated, in any tier, ever: a
compatibility verdict is correctness, and correctness is free.

## Where the fixtures live

Both examples consume corpora under
[`../verification/fixtures/`](../verification/fixtures/README.md) — the same
committed fixtures the test suite runs against, not a parallel copy. A case
disappearing from a corpus therefore breaks the example and its guard test
together, which is the intent.
