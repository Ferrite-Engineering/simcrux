# Waveforms & debug

When a test fails, the next thing you want is the waveform. SimCrux manages
waveform capture as part of the run — which tests dump, in what format, and
where — and hands a failing test's dump to WaveCrux in one click, with a
suggested set of signals.

## Capture policy {#policy}

Dumping every signal on every test is expensive, so SimCrux makes it a policy
with `waveform:` at the `defaults:`, suite or test level:

```yaml
defaults:
  waveform:
    capture: on_failure   # always | on_failure | on_demand | never
    format: fst           # fst | vcd | ghw
```

| `capture:` | Behaviour today |
|---|---|
| `on_failure` (default) | The simulator is asked for a dump on every run. A failing test keeps its dump. |
| `always` | The simulator is asked for a dump on every run, and every test keeps its dump — passing tests included. |
| `on_demand` | No dump is requested. Use **Re-run with waveform** when you need one. |
| `never` | No dump is requested. |

A simulator cannot know it will fail before it runs, so `on_failure` dumps
every run and keeps the dump only where it matters:

- A **failing** test keeps its dump in its retained working directory.
  Retained directories are pruned automatically — the 50 most recent, 2 GiB at
  most — in the desktop app and under `simcrux --ci` alike, and an empty
  `.simcrux-keep` file pins a directory you want to survive pruning.
- A **passing** test's dump is moved, in the desktop app, into a small archive
  (the 25 most recent, 512 MiB at most) so **Debug in WaveCrux** can still open
  it. Under `simcrux --ci` it is deleted with the test's working directory.

With `always`, a passing test keeps its working directory and its dump exactly
as a failing test does, in the app and under `--ci`, so the same pruning
applies: on a large `always` regression the 50-directory cap keeps the most
recent. Pin anything you need to keep with `.simcrux-keep`.

## Format {#format}

`format:` selects the dump format; `fst` is the default.

- **GHDL** writes the dump itself (`--vcd=`, `--fst=`, or `--wave=` for GHW).
  `ghw` is GHDL-only.
- **Icarus** and **Verilator** testbenches must call `$dumpfile` / `$dumpvars`
  themselves. SimCrux only selects the format (`vvp -fst`, `verilator
  --trace-fst` or `--trace`) and records the newest `.fst` / `.vcd` in the
  working directory.

SimCrux does not convert between formats.

## Waveform path tracking {#path}

SimCrux records the dump path on each result and shows it in the Details
panel's **Waveform** field, next to the **Working dir**. You never have to
remember which build directory a given test wrote into — the result knows.

## Debug in WaveCrux {#debug}

With a waveform captured, the Details panel's **Debug in WaveCrux** action hands
that file to [WaveCrux](https://wavecrux.app), the suite's waveform viewer, over
the cross-probe (CXP) link, with a suggested signal list (the test's top module,
`<top>.*`, unless it has a curated list). WaveCrux must be running on the same
machine, and CXP enabled in both apps (**Settings → CXP Cross-Probe**, on by
default). SimCrux then reports what WaveCrux did — for example "Sent to WaveCrux
(…)", "WaveCrux is not connected", or "This test did not capture a waveform". The
full list of notices, and how the hand-off works, is on
[Cross-probe & the suite](integrations.md#deep-link).

## Re-run with waveform {#rerun}

If a test ran under `capture: on_demand` or `never` and then failed, you do not
have a dump yet. The Details panel's **Re-run with waveform** re-runs it with
`capture` forced to `always`; then click **Debug in WaveCrux** on the fresh
result. This is the common path for projects that keep dumps off by default: a
waveform on demand for the one test you are chasing.

It runs only that test. **Re-run Selected Test** does the same with the test's
own capture policy.

## Open testbench source {#source}

**Open testbench source** opens the test's testbench in your editor at line 1 —
the source whose file name matches the `top` module (or `<top>_tb`), otherwise
the first source. Configure the editor in **Settings → Editors**: pick
**VS Code**, **Sublime Text**, **Vim** or **Emacs**, or write a **Custom**
command using the `{file}`, `{line}` and `{column}` placeholders.

## The failure-to-waveform loop {#loop}

1. **Run with on-failure dumping.** Keep the default `capture: on_failure` and
   run (++f5++). Testbenches must dump (`$dumpfile` / `$dumpvars`) for Icarus and
   Verilator.
2. **Select the failure.** Click the **Failures** preset and click the row. The
   Details panel shows a **Waveform** path if one was captured.
3. **No dump? Re-run with waveform.** If the test ran under `on_demand` or
   `never`, click **Re-run with waveform**.
4. **Open it in WaveCrux.** Click **Debug in WaveCrux**. WaveCrux opens the dump
   with the suggested signals; trace the bug from there.

!!! tip "Worked example"
    The [Triage failures & open the waveform](cookbook-triage-failures.md) recipe
    walks this loop end to end.
