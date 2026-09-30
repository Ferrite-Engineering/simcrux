# Migration guides

SimCrux replaces the *orchestration* layer around your simulators, not
the simulators themselves. Whatever runs your tests today —
a Makefile, VUnit, FuseSoC — the RTL and the testbenches are unchanged.
What moves is the description of *which* tests exist, *how* they are
built, and *what counts as a pass*.

| Coming from | Guide |
| --- | --- |
| Hand-written Makefiles | [Migrating from Makefiles](from-makefiles.md) |
| VUnit | [Migrating from VUnit](from-vunit.md) |
| FuseSoC | [Importing FuseSoC files](../fusesoc-import.md) — automated |

## What every migration has in common

Read this before either guide; it is the part people get wrong.

### There is no discovery

SimCrux does **not** scan directories for testbenches, does not expand
globs in `sources:`, and does not infer tests from filenames. Every test
is declared explicitly in `simcrux.yaml`. If your current flow relies on
"anything matching `tb_*.sv` is a test", you will be writing that list
out — once — by hand or with a script.

This is a deliberate trade: an explicit list is diffable, reviewable, and
cannot silently stop running a test because a file got renamed.

### Three levels of inheritance

`defaults:` → `suites.<name>:` → the individual test. The test wins last.
Most of what feels repetitive in a Makefile collapses into `defaults:`
(simulator, pass/fail rule, waveform policy, timeout) and the suite level
(shared `sources:`, `include_dirs:`, `defines:`, `resources:`, which
`defaults:` does not accept).

For `sources:`, `include_dirs:` and `resources:`, the suite-level list is
**merged** with the test's own. For `defines:`, the maps merge and the
test's value wins. For scalars (`simulator`, `timeout`, `pass_fail`,
`waveform`), the innermost declaration wins outright.

### Reuse across projects with `includes:`

```yaml
includes:
  - ../common/house-defaults.simcrux.yaml
```

Resolved relative to the including file, recursive, with cycle detection.
On a conflict (same suite name, same simulator id), the **root** file
wins. The root file's `defaults:` fill gaps in an included file, except
`timeout`, which does not carry across
([a known issue](../projects-and-simulators.md#includes)). This is the
replacement for a shared `rules.mk`.

### Filelists still work

Any `sources:` entry ending in `.f` is expanded after parsing. The
expander understands one-path-per-line, `#` and `//` comments,
`+incdir+`, `+define+K=V`, `-I<path>` / `-I <path>`, and
`-D<K=V>` / `-D <K=V>`. Paths inside the `.f` resolve relative to the
`.f`'s own directory.

So if your Makefile already builds a `.f`, you can keep doing that and
point SimCrux at it.

### What SimCrux does not have

Be clear-eyed about these before you plan the move:

- **No test discovery** (above).
- **No tags.** Filtering is by test-id substring only (`--filter`), and
  in the GUI by status / suite / simulator / name substring. If you rely
  on `--tag nightly`, encode it in the suite name or the test name and
  filter on that.
- **Raw flags for Verilator only.** You get `include_dirs`, `defines` and
  per-simulator `env` (environment variables). SimCrux builds each command
  line itself — Icarus always gets `-g2012`, GHDL always
  `--std=08 --ieee=synopsys` — and only Verilator takes extra flags, through
  `simulators.verilator.options.args`. Otherwise `simulators.<id>.options` is
  read only by the cocotb driver.
- **Parameters are not passed to the simulator.** `parameters:` forms the
  unique test id and drives sweeps; no driver emits them as `-G` / `-g` /
  `-pvalue+`. (The cocotb driver reads a few reserved keys such as `sim`,
  `TOPLEVEL_LANG` and `MODULE`.) If your tests are parameterized at
  elaboration time, use `defines:` where you can, and treat parameter
  sweeps as an id/organization mechanism for now.
- **Sweeps are a Pro feature.** An open-core build runs a `seeds:` list or a list-valued
  parameter once, and `--ci` expands them at the tier of the license it is
  given (see [Parameterization & seed sweeps](../trends-and-flaky.md#sweeps)).
- **Concurrency is not a YAML key.** It comes from `--max-parallel` / `-j`
  in `--ci` mode; the GUI uses 4.
- **Only one level of grouping.** Suites do not nest and have no ordering
  or dependency relationships.
