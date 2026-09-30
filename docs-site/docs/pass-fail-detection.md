# Pass/fail detection

Every team has its own convention for "did this test pass?" — an exit code, a
magic string, a UVM report summary, an xUnit report. SimCrux supports all of
them as configurable detectors, set per project, suite or test with
`pass_fail:`, or reused from a shared library.

## The detectors {#detectors}

Eight detector types ship today. A test with no `pass_fail:` anywhere in its
inheritance chain uses `exit_code`.

| Detector | Config | Passes when |
|---|---|---|
| Exit code | `type: exit_code` | The process exits `0`. The default. |
| String match | `type: string_match`<br>`pass_string:` / `fail_string:` | The output contains `pass_string` and does not contain `fail_string`. At least one of the two is required. |
| Regex | `type: regex`<br>`pass_pattern:` / `fail_pattern:` | The pass pattern matches and the fail pattern does not. |
| UVM report | `type: uvm_report` | The UVM report summary shows fewer `UVM_FATAL` / `UVM_ERROR` / `UVM_WARNING` messages than their thresholds. |
| Cocotb summary | `type: cocotb` | Cocotb's end-of-run summary reports no failures and accounts for every test. `allow_no_tests: true` lets a run reporting `TESTS=0` pass. |
| Golden compare | `type: golden_compare` | A file the test wrote matches a reference file, under the selected profile. |
| Composite | `type: composite` | Combines other detectors with `all_of` / `any_of`. |
| Named reference | `type: use` | Reuses a detector defined once in the detector library. |

```yaml
defaults:
  pass_fail:
    type: string_match
    pass_string: TEST PASSED
    fail_string: TEST FAILED
```

**How a verdict is reached.** When a detector finds a signal of its own, its
verdict stands. When it finds none — only a `fail_string` was configured and it
never appeared, or the log has no UVM summary — the test takes the driver's
verdict, which for Icarus, Verilator and GHDL is the simulator's exit code.

### `exit_code` {#exit-code}

```yaml
pass_fail:
  type: exit_code
```

Exit code 0 → pass; any other code → fail.

### `string_match` {#string-match}

```yaml
pass_fail:
  type: string_match
  pass_string: TEST PASSED   # at least one of pass_string / fail_string
  fail_string: TEST FAILED   # fail wins when both appear
```

Matches are plain substrings of `stdout` or `stderr`. A `fail_string` that
appears fails the test even if the `pass_string` also appears. A configured
`pass_string` that never appears is a fail. With only a `fail_string`, its
absence gives no verdict, and the exit code decides.

### `regex` {#regex}

```yaml
pass_fail:
  type: regex
  pass_pattern: '^TEST_PASSED$'
  fail_pattern: '^(?:ERROR|UVM_FATAL):'
```

Multi-line mode is on, so `^` / `$` match line boundaries. The precedence is the
same as `string_match`. Patterns use Dart (JavaScript-style) syntax, which has
**no** PCRE `(?i)` prefix — use a scoped `(?i:error)` group or a character class
(`[Ee][Rr][Rr]`) to match case variants. Only the last 1 MiB of the log is
scanned, and a pattern that runs longer than one second is abandoned rather than
hanging the run.

A pattern that does not compile — such as one starting with `(?i)` — stops the
project from loading, with the file, line and field of the bad pattern. The same
check applies to a [library detector](#library) when a project that uses it
loads.

### `uvm_report` {#uvm-report}

```yaml
pass_fail:
  type: uvm_report
  fatal_threshold: 1      # default 1 — one UVM_FATAL fails the test
  error_threshold: 1      # default 1
  warning_threshold: 0    # default: disabled
```

Parses the UVM report summary out of the simulation log and fails when a
severity count reaches its threshold. A threshold of `0` disables that check.

### `golden_compare` {#golden-compare}

```yaml
pass_fail:
  type: golden_compare
  dut: dump.hex                       # relative paths resolve against the per-test working directory
  reference: /work/golden/dump.hex    # so give files outside it as absolute paths
  profile: generic                    # generic (default) | riscv_signature
```

Compares a file the test wrote against a reference file, word by word.
Whitespace is insignificant; `generic` compares words exactly, while
`riscv_signature` folds case and a `0x` prefix and defaults the two paths to
`signature.dut.sig` / `signature.ref.sig`. A missing or empty file on either
side is a fail, never a pass.

### `use` {#use}

```yaml
pass_fail:
  type: use
  name: house_uvm_policy
```

References a detector from the [detector library](#library) by name, so a
shared policy lives in one place. Cycles are detected at load time.

## Composite rules {#composite}

Combine detectors with boolean **AND** / **OR** for the cases a single rule
cannot express — for example, "passes only if it exits 0 *and* prints `PASS`".

```yaml
pass_fail:
  type: composite
  all_of:
    - { type: exit_code }
    - { type: string_match, pass_string: 'PASS' }
  any_of:
    - { type: regex, pass_pattern: 'coverage > 95' }
```

`all_of` is AND; `any_of` is OR. A single fail in `all_of` short-circuits to
fail. Composites nest. The dashboard shows the resolved status; use the Log
Viewer to find the line a clause matched.

## Resolved statuses {#statuses}

Every run resolves to one status. Beyond **pass** and **fail**, SimCrux
distinguishes:

- **timeout** — the run was killed by its [timeout](running-tests.md#timeouts).
  It counts as a failure in CI but is shown separately from an assertion
  failure.
- **unknown** — SimCrux could not decide: the simulator binary could not be
  started, no driver is registered for the simulator id, or neither the detector
  nor the driver produced a verdict. Always counted as a failure in CI.
- **cancelled** — the test was running when you cancelled the regression.
- **skipped** — reported by a driver that skips a test.
- **vacuous** and **cover** — for results that completed without exercising
  their checks, or that record a coverage hit. No built-in detector or driver
  produces them today; `--fail-on-vacuous` counts vacuous results when a driver
  reports them.

## UVM & cocotb results {#parsers}

- **UVM report** — `uvm_report` reads the report summary block and fails the
  test on `UVM_FATAL` or `UVM_ERROR` counts at or above their thresholds, the way
  a UVM sign-off expects, rather than relying on a hand-rolled string.
- **Cocotb** — the cocotb driver reads the `results.xml` cocotb writes beside
  every run, falling back to cocotb's end-of-run summary table when a run
  produces no report, and records each cocotb testcase's status and simulated
  time on the result. It works with cocotb 1.9 through 2.1. See
  [Cocotb versions and options](projects-and-simulators.md#cocotb).

With no `pass_fail:` configured, a cocotb test needs no detector: the driver's
verdict stands. Cocotb 1.9's `make` exits `0` even when tests fail, so when the
report says a test failed, the driver withholds that `0` from the default
`exit_code` detector (the raw value is kept as the `cocotb.process_exit_code`
metric) and the run is a **fail**. A clean report with a non-zero `make` exit is
still a fail.

`type: cocotb` classifies from the end-of-run summary line, **not** from
`results.xml` — a detector is handed stdout, stderr, the exit code and the
runtime, not the working directory, so it does not open files.

| Situation | Verdict |
|---|---|
| `FAIL` greater than zero | fail |
| `PASS + SKIP + XFAIL` short of `TESTS` | fail — a case ended in a state the summary has no word for |
| `TESTS=0` | fail, unless `allow_no_tests: true` |
| No summary line at all | no verdict — a composite or the exit code decides |
| Otherwise | pass |

XFAIL counts as an expected outcome, so enabling `COCOTB_PREVIEW` does not change
a verdict. The exit code is ignored, because a Makefile can swallow a non-zero
status or return one for reasons unrelated to the tests. When both matter,
compose:

```yaml
defaults:
  pass_fail:
    type: composite
    all_of:
      - type: exit_code
      - type: cocotb
```

## The reusable detector library {#library}

Most teams converge on a handful of detectors used across hundreds of tests.
Define them once in **Settings → Detectors** and reference them by name with
`type: use`, instead of copying the same rule into every project.

1. **Open the library.** Go to **Settings → Detectors**
   (++cmd+comma++ / ++ctrl+comma++). Each entry shows its name and kind.
2. **Add or edit a detector.** Click **Add detector…**, give it a **Name** (for
   example `strict-uvm`) and pick a **Kind**: Exit code, String match, Regex, UVM
   report, Cocotb summary, Golden compare, Composite (with **All of (AND)** and
   **Any of (OR)** children), or Use another. Edit and delete existing entries
   here too.
3. **Reference it from tests.** Point a test at the named detector:
   `pass_fail: { type: use, name: strict-uvm }`. Change the rule once in the
   library and every referencing test picks it up on its next load.

!!! note "`use` under `--ci`"
    The library lives in the desktop app's settings, so `type: use` resolves
    only in runs started from the app. `simcrux --ci` and the standalone
    `simcrux` binary never read those settings — a CI result must not depend on
    one person's app — so they reject the project with an "unknown reusable
    detector" error and exit `2`. Spell the detector out in `simcrux.yaml` for
    anything CI runs.

!!! note "Next"
    Once detectors classify your results, [The results dashboard](results-dashboard.md)
    covers filtering, sorting and triaging them at scale.
