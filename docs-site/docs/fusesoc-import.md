# Importing FuseSoC `.core` Files

SimCrux reads — but never writes — [FuseSoC CAPI2 `.core` files][capi2]
as a one-way migration aid. Point the importer at a `.core`; get back a
`<name>.simcrux.yaml` next to it. Edit the result by hand if needed.
The native YAML stays the canonical project format.

[capi2]: https://fusesoc.readthedocs.io/en/stable/user/build_system/capi2_files.html

## Where the output lands

The synthesized file is written next to the source `.core` and named
after it: `servant.core` produces `servant.simcrux.yaml`, `serv.core`
produces `serv.simcrux.yaml`. The stem comes from the `name` field of
`vendor:library:name:version`, falling back to the `.core` file's own
basename.

This matters because multi-core directories are the norm — SERV ships
`serv.core`, `servant.core`, `servile.core` and `serving.core` side by
side. Re-importing the *same* core overwrites its own output, which is
what you want; importing a sibling leaves it alone.

## Triggering the import

Three equivalent entry points:

- **GUI:** `File → Import FuseSoC .core File…` (also on the toolbar and in
  the command palette). SimCrux writes the result next to the `.core`,
  opens it as a tab, and reports how many warnings the import raised.
- **CLI:** `simcrux --import-fusesoc path/to/my_design.core`. Writes
  the result next to the source, prints the output path and each warning
  on stdout, exits without launching the UI.
- **Keyboard:** `Ctrl+I` / `Cmd+I` — a global binding, available anywhere in the app.

## What translates cleanly

| CAPI2 field                          | SimCrux mapping                                |
|--------------------------------------|------------------------------------------------|
| `name: vendor:lib:name:ver`          | recorded in the header comment; the `name` field also names the output file (`<name>.simcrux.yaml`) |
| `filesets.<n>.files`                 | per-test `sources:`                            |
| `filesets.<n>.file_type`             | language hint (Verilog/SystemVerilog/VHDL)     |
| `filesets.<n>.depend`                | entries naming another fileset in the same file are resolved dependency-first; dependencies on other cores are not fetched (`unknown_fileset`) |
| `targets.<n>.toplevel`               | test `top:`                                    |
| `targets.<n>.filesets`               | merged source list (after `depend` expansion)  |
| `targets.<n>.default_tool: icarus`   | `simulator: icarus`                            |
| `targets.<n>.default_tool: verilator`| `simulator: verilator`                         |
| `targets.<n>.default_tool: ghdl`     | `simulator: ghdl`                              |
| `targets.<n>.default_tool: cocotb`   | `simulator: cocotb`                            |
| `targets.<n>.flow: sim`              | selects the simulator from `flow_options.tool` |
| `targets.<n>.parameters[]`           | `defines:` (vlogdefine) or `parameters:` (vlogparam / generic) |
| `parameters.<n>.paramtype`           | routes the corresponding override above        |
| `parameters.<n>.datatype: int/real`  | numeric value preserved                        |
| `parameters.<n>.datatype: str/bool`  | string value preserved                         |

## Only simulation targets become suites

SimCrux runs testbenches, so a CAPI2 target translates to a suite only
when it describes a simulation. Three kinds of target are dropped:

- **Packaging targets** — no `toplevel:`. Skipped silently.
- **Non-`sim` flows** — `flow: synth`, `flow: lint`, `flow: vivado`,
  `flow: icestorm`, and so on.
- **Synthesis / place-and-route backends** — `default_tool:` naming
  `vivado`, `ise`, `quartus`, `icestorm`, `trellis`, `diamond`,
  `libero`, `openlane`, `nextpnr`, `yosys`, and friends.

The last two surface a `non_simulation_target` warning naming the target
and the backend, so nothing disappears without a record.

This matters for board-support core files. SERV's `servant.core`
declares roughly forty FPGA targets alongside two simulations; the
import yields the two simulation suites, not forty-two suites of which
forty could never pass.

Simulators SimCrux can't drive yet (`modelsim`, `questa`, `xsim`, `vcs`)
are a different case — they still import, falling back to `icarus` with
an `unsupported_tool` warning. Substituting one Verilog simulator for
another is lossy but coherent; running a bitstream flow under a
simulator is not.

If a `.core` file contains no simulation target at all, the import
raises rather than emitting an empty project.

## Conditional expressions

CAPI2 gates list entries on flags:

```yaml
files:
  - "tool_quartus? (servant/servant_ram_quartus.sv)" : {file_type: systemVerilogSource}
  - "!tool_quartus? (servant/servant_ram.v)"
```

The importer evaluates these per target, in `files`, `depend`, a
target's `filesets` and `parameters`, and `toplevel`:

| Flag | Value at import time |
|---|---|
| `is_toplevel` | true — importing a core means running *it* |
| `target_<name>` | true for the target being translated |
| `tool_<id>` | true for the tool the target resolved to |
| anything else | unset, matching FuseSoC without `--flag=+name` |

An entry whose condition fails is **dropped**, not emitted verbatim.
This is not cosmetic: a `sources:` entry reading
`tool_quartus? (servant/servant_ram_quartus.sv)` is a filename with a
`?` and a space in it, and both Icarus and Verilator fail on the first
one they touch.

A conditional may hold several whitespace-separated values —
`tool_icarus? (a.v b.v)` contributes both files when it matches.

Dropping on an unset *user* flag raises `conditional_flag_unset` naming
the flag, so `--flag=+mdu` territory is greppable. A `tool_*` mismatch
is silent: that one is a fact, not an assumption.

## What surfaces as a warning

The importer never throws on unsupported features; it logs a warning
and continues. Every warning has a stable machine-readable `code` for
filtering in CI; the human-readable message is reproduced as a `#`
comment at the top of the synthesized `simcrux.yaml`.

| Code                       | When it fires                                                                     |
|----------------------------|-----------------------------------------------------------------------------------|
| `unsupported_vpi`          | `vpi:` block present — VPI hooks aren't part of SimCrux's surface                  |
| `unsupported_generator`    | `generators:` block present — FuseSoC's preprocessor isn't run                     |
| `unsupported_scripts`      | `scripts:` block (pre/post run hooks)                                              |
| `unsupported_tool`         | `default_tool:` references a *simulator* SimCrux can't run on Open Core (`modelsim`, `questa`, `xsim`, `vcs`, …). Falls back to `icarus`. |
| `non_simulation_target`    | The target is a synthesis, lint or place-and-route flow — dropped, not imported. See above. |
| `conditional_flag_unset`   | Entries gated on a user-defined flag (`mdu? (…)`) were dropped because the importer has no `--flag=+mdu` to act on. One per flag per target. |
| `unresolved_toplevel`      | Every `toplevel:` candidate was suppressed by its condition — the target is skipped. |
| `complex_parameter`        | A parameter declares `datatype: file` / `file_list` — skipped entirely             |
| `unknown_parameter`        | A target references a parameter not declared at the project level — treated as `defines:` |
| `plusarg_parameter`        | A parameter has `paramtype: plusarg` or `cmdlinearg` — emitted under `parameters:` for manual review |
| `non_hdl_file_type`        | A fileset entry has a non-HDL `file_type` (`xdc`, `tclSource`, …) — kept in `sources:` but flagged |
| `include_file_demotion`    | A file is marked `is_include_file: true` — emitted under `sources:`, not `include_dirs:` |
| `unknown_fileset`          | A target or `depend:` references a fileset that isn't defined in this file — skipped |
| `invalid_filesets` / `invalid_fileset` / `invalid_files` / `invalid_file_entry` / `invalid_target` | Structural error in the relevant block — skipped |

## What the importer refuses

These CAPI2 files produce a structured exception rather than a warning,
and nothing is written (the CLI exits `2`):

- **No `CAPI=2:` header.** The first line that is neither blank nor a
  `#` comment must be `CAPI=2:`.
- **Unparseable YAML**, or a document whose root is not a map.
- **Missing `targets:` block**, or one that is not a map.
- **No simulation target** — every target is packaging-only (no
  `toplevel:`), a non-`sim` flow, or a synthesis / place-and-route
  backend.

## Round-trip discipline

Round-tripping is not a goal. SimCrux is not a CAPI2 producer. If you
import a `.core`, edit the synthesized `simcrux.yaml`, and want to
re-import after the source `.core` changes, re-run the importer and
diff. The native format is the canonical surface for ongoing
maintenance; the import is a migration on-ramp.

## Examples

A minimal CAPI2 file:

```yaml
CAPI=2:

name: ::demo:0.1.0

filesets:
  rtl:
    files:
      - rtl/counter.v
    file_type: verilogSource
  tb:
    files:
      - tb/counter_tb.v
    file_type: verilogSource
    depend:
      - rtl

targets:
  sim:
    filesets: [tb]
    toplevel: counter_tb
    default_tool: icarus
```

… produces:

```yaml
# Generated by SimCrux FuseSoC importer from demo.core.
# Review before committing: SimCrux reads CAPI2 but only consumes a subset.
# Source: /path/to/demo.core

version: '1'

defaults:
  simulator: icarus
  pass_fail:
    type: exit_code
  waveform:
    capture: on_failure

suites:
  sim:
    description: Imported from FuseSoC target `sim`.
    simulator: icarus
    tests:
      - name: sim_main
        top: counter_tb
        sources:
          - rtl/counter.v
          - tb/counter_tb.v
```
