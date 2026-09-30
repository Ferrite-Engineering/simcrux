# riscv-formal demo corpus

Pre-captured SymbiYosys outputs for `riscv: { mode: demo }` under the
`riscv_formal` driver (VERIFICATION_GUIDE.md §18.3).

**Hand-authored. Nothing here is derived from riscv-formal, SymbiYosys or
any other upstream project**, so no third-party attribution obligation is
created — the same call the signature corpus makes. The logs
are written in `sby`'s output shape because that is the shape the parser
must handle; they describe proofs of a fictional core, and the traces are
that fictional core's retire log.

Each case directory holds:

| File | Role |
|---|---|
| `case.json` | hand-written inputs: the check name, group, proof mode, depth, the log filename, any trace files, and the exit code the run reported |
| `sby.log` | the captured SymbiYosys output the driver replays |
| `engine_*/trace*.vcd` | **generated** — counterexample / cover traces, staged into the task directory in demo mode. The step tables they are rendered from are hand-authored in `tool/riscv_formal_traces.dart` |
| `expected.json` | **generated** — the outcome the real `SbyLogReader` parses out, plus the verdict and status the real driver maps it to |

Regenerate the traces and the goldens with:

```bash
dart run tool/generate_riscv_formal_fixtures.dart
```

## The traces are a cross-product contract, not a placeholder

A counterexample VCD is not only an input to this driver — it is the
artifact the counterexample hand-off ships to **WaveCrux**, and WaveCrux's RVFI
consumer will not admit a trace carries an RVFI bundle at all without
`rvfi_valid`, `rvfi_insn` **and** `rvfi_pc_rdata`. An earlier revision of
this corpus declared three channels — `valid`, `insn`, `rd_wdata` — which
was enough for the driver tests here (they only need a VCD path that
exists and survives cleanup) and not enough for anything downstream to
read. Both halves' tests passed; the flagship SimCrux → WaveCrux demo
opened the file and silently landed nowhere.

So the traces now carry the **full 21-channel RVFI bundle**, and
`test/services/simulator/riscv_formal_trace_contract_test.dart` asserts
the properties the consumer depends on, against the committed files:

- every RVFI channel is declared, `rvfi_pc_rdata` among them;
- every value change lands on a uniform step lattice from tick 0, so a
  bounded-proof step number can be converted into a time at all;
- the counterexample trace reaches **step 7** — the depth `sby.log`
  reports — and `rvfi_valid` is high there, so the coordinate the producer
  emits resolves to a real retirement rather than to a cursor placement.

Thinning a trace again fails that test on this side, and the end-to-end
test on WaveCrux's side
(`test/services/remote/cxp/riscv_counterexample_handoff_test.dart`), which
runs the whole consumer chain against a byte-identical copy of
`insn_sub_counterexample/engine_0/trace.vcd`.

**`git add` whatever it writes.** Every file here is committed data — the
driver replays it from a clean CI clone, and a case whose `sby.log` is
missing does not fail loudly: it replays empty text and reports
`NO_OUTCOME`, a verdict the parser can legitimately reach. Flutter's
boilerplate `.gitignore` once swallowed all seven logs via `*.log`, which
is why `.gitignore` now carries an explicit negation for
`verification/fixtures/**/*.log` and why
`test/static/fixture_corpus_is_committed_test.dart` asserts that every file
in this tree is known to `git ls-files`.

`expected.json` is produced by running the **production** parser and the
production verdict→status mapping against the committed log — not by
restating what the fixture author expected — so a regression in either
shows up as a diff here and in
`test/services/simulator/riscv_formal_fixtures_test.dart`.

## The required cases

The guard test asserts this list by name, so a case cannot quietly
disappear and narrow the coverage:

- `insn_add_pass` — a clean bounded proof. **The only case that may report
  pass** except `cover_multi_trace`.
- `insn_sub_counterexample` — `FAIL` with a counterexample VCD. This is
  the WaveCrux counterexample hand-off case.
- `pc_fwd_unknown` — `UNKNOWN`. The solver did not decide, so **nothing was
  proved**; it must report `fail`.
- `reg_timeout` — `TIMEOUT`. SymbiYosys's own solver budget expired; it
  must report `fail`, and it must **not** be `TestStatus.timeout`, which
  means "SimCrux killed the job".
- `causal_error` — `ERROR`. The proof never ran.
- `liveness_no_outcome` — **the sharpest trap**: the log ends with no
  `DONE (…)` line at all and the process exits **0**. Classifying from the
  exit code would report a proof that never happened as green.
- `cover_multi_trace` — `PASS` in `cover` mode with two traces, which is
  what makes `riscv.formal.trace_count` observable.
