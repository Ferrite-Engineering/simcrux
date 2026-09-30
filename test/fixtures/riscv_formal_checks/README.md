# riscv-formal check-set importer fixture

A **miniature** `checks/` directory of the shape [riscv-formal][rf]'s
`checks/genchecks.py` writes:

```text
cores/<core>/checks/
  insn_add_ch0.sby
  insn_sub_ch0.sby
  pc_fwd_ch0.sby
  reg_ch0.sby
  cover_ch0.sby
```

Five generated job files across four property groups (`insn`, `pc_fwd`,
`reg`, `cover`), which is enough to exercise everything
`RiscvFormalCheckImporter.importChecks` does — the `checks/` subdirectory
detection, the `.sby` filter, `RiscvFormalConfig.groupForCheck` derivation,
the `--groups` filter, the `[tasks]` fan-out, and the deterministic sort.

## Why not a real riscv-formal checkout

`genchecks.py` writes these files *from* a `checks.cfg` plus the core's
Verilog. Vendoring a core to regenerate them would pull in an entire CPU
implementation to test a directory scan. The importer never runs `sby` and
never elaborates any HDL: it reads the section headers and the `[tasks]`
names via `SbyScript.parse` and nothing else. So generated-shaped files are
exactly as good a test as generated files, and they stay readable.

The `[script]` / `[files]` sections below name sources that do not exist in
this repository, deliberately: the importer must not check for them, and
their absence is part of the assertion. Nothing here is runnable by `sby`.

## Deliberate contents

- `insn_add_ch0.sby`, `insn_sub_ch0.sby` — two checks in one group, so the
  emitted `insn` suite has more than one entry and the sort is observable.
- `pc_fwd_ch0.sby` — a group whose name itself contains an underscore, so
  the `_ch\d+` strip must not also eat `_fwd`.
- `reg_ch0.sby` — `mode prove`, the other proof mode.
- `cover_ch0.sby` — the only file carrying a **`[tasks]` section** (two
  tasks). One `sby` invocation over both would print two `DONE (…)` lines
  into one result row, so the importer must expand it into two tests and
  raise `multi_task_sby`. That expansion is the whole reason this fixture
  is not four files.

[rf]: https://github.com/YosysHQ/riscv-formal
