# FuseSoC and Edalize fixture: provenance

One FuseSoC run of the SERV `servant` system on the iCEBreaker target, through
Edalize's `icestorm` flow, with no `--report` passed to nextpnr. It is the
fixture for reading timing out of the nextpnr log alone.

## Tools and date

Captured on 2026-10-21.

| Tool | Version |
|---|---|
| FuseSoC | 2.4.7 |
| Edalize | 0.6.8 |
| SERV core set | commit `f200eb2ed7b69ac1c6b8eddd47654522aeee5ce8` (core `award-winning:serv:servant:1.4.0`) |
| fusesoc-cores | commit `def274ab01abd2f074d8e3c6891cba0181010095` |
| Yosys | 0.69+post (git 143eb14f9), Homebrew |
| nextpnr-ice40 | 0.11.1-77-g6b438a1c, OSS CAD Suite `2026-10-21` |

`versions.txt` holds the lines the regenerator recorded.

Yosys here is not the suite's. Edalize drives Yosys through a Tcl script, and
the darwin-arm64 build of OSS CAD Suite `2026-10-21` has no `tcl` command
(`ERROR: No such command: tcl`). The regenerator's `--yosys-dir` option puts a
Yosys built with Tcl first on `PATH` for that run; nextpnr is still the
suite's. The Linux build the weekly workflow installs is checked in CI, not
here.

## Command

```
tool/flow/regen_fusesoc_fixture.sh --suite <oss-cad-suite dir> --yosys-dir <dir holding a Tcl-enabled yosys>
```

which, in a scratch directory, installs `fusesoc==2.4.7 edalize==0.6.8` into a
virtual environment, checks out the two core repositories at the commits above
and runs:

```
fusesoc --cores-root serv --cores-root fusesoc-cores run --target=icebreaker award-winning:serv:servant
```

The core file's own `nextpnr_options` for that target are `--up5k --freq 16`.
`build/Makefile` shows the exact `yosys` and `nextpnr-ice40` command lines
Edalize generated; neither contains `--report`, and no `report.json` exists.

Captured under `build/`: `yosys.log`, `next.log` (nextpnr's `-l` log, the only
timing evidence), the synthesized netlist `award-winning_serv_servant_1.4.0.json`
(real design, about 1.7 MB), `Makefile` and the Edalize `.eda.yml`. Scratch and
home paths are rewritten and the regenerator fails if one survives.

## Where the expectation comes from

`verdict.expected.json` was written by hand from the PASS on the log's last
`Max frequency` line against the 16 MHz the core file passes to nextpnr. The
test that checks it extracts the line itself and shares no code with the
product's log reader.
