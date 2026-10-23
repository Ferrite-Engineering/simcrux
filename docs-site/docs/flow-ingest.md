# Ingesting runs, from 1.2

From SimCrux 1.2, SimCrux can list and read implementation runs it did not
launch: a run a colleague made, a run a CI job left behind, the artifact of a
pipeline. Ingesting is **read-only**. SimCrux writes nothing inside a run it
reads, and it never starts a tool to do it. This page is part of
[Implementation flow](flow.md).

<!-- vocabulary-guard: disclaimer begin -->
Results are findings, not signoff.
<!-- vocabulary-guard: disclaimer end -->

## What can be ingested {#what}

| You give SimCrux | It reads |
|---|---|
| A nextpnr run directory | The run's `report.json`, and beside it, when they are there, `synth.json`, `post.json` and `pnr.log` |
| A `report.json` on its own | The report, without a netlist, so its paths are listed [unmapped](flow-runs.md#mapping) and the panel says so |
| A directory that holds runs | Every run found under it |
| A zipped CI artifact | The runs inside it, after the archive passes the checks [below](#zip) |

A LibreLane run directory is read too, by the reader for the release its
`resolved.json` names. A release the readers are not
[verified for](flow-librelane.md#reading) is labelled **reader not verified**,
read best-effort, and said so before its verdict.

## In the app {#app}

- **Tools → Ingest Run Directory…** asks for a directory, lists the runs under
  it and adds them to the [Flow Runs panel](flow-runs.md).
- **Tools → Ingest Zipped Artifact…** does the same for a `.zip`.

Each reports in a toast: "Ingested 3 runs", "No runs found", or why nothing was
ingested.

## In the project {#project}

A project can list runs it should always show:

```yaml
flow:
  ingest:
    - runs/                          # a directory of runs
    - build/fpga/report.json         # one report
    - artifacts/gds-logs.zip         # a zipped artifact
```

A path in `ingest:` must be inside the project directory, with symbolic links
resolved. One that is not is refused and counted in the panel's problems line
("1 ingest path named no run"), whose tooltip names it. A path you choose in
the dialog may be anywhere, and is read within itself.

## From a terminal {#cli}

```bash
simcrux flow ingest runs/ build/fpga/report.json
```

One line for each run: its kind, tag and verdict, then ` (reader not verified)`
when that applies, then the directory. `--json` prints one document
(`simcrux-flow-ingest/1`) with every run and the exit code. It writes nothing.

The exit code follows [the flow contract](flow-ci.md#exit-codes): `0` when
every run is met, `1` when any is violated, `2` when any could not be
evaluated (which outranks `1`), `64` for a path that does not exist, and `65` for
input that exists but cannot be converted.

## Zipped artifacts {#zip}

A zipped artifact is extracted into SimCrux's own scratch directory (a
`simcrux/ingest/` folder inside the system temporary directory), never into your
project, under a name made from the file's path, size and modification time.
Ingesting it again reuses that copy and files the runs under the same ids.

Before anything is written, SimCrux checks the whole archive and refuses all of
it if any entry:

- has an absolute, drive-letter or UNC path, or a `..` segment written with
  either separator;
- is a symbolic link, or has a name with a NUL in it;
- is nested more than 64 segments deep, or the archive has more than 50,000
  entries;
- is larger than 1 GiB, or the entries together are larger than 4 GiB, or the
  archive file itself is larger than 4 GiB.

Decompression is counted as it happens, so an entry that understates its size
stops at the cap. A file that is not a zip is refused as unreadable.

## What a run is read for {#read}

A run is read for its verdict, its metrics, its steps (when the flow records
them) and its worst timing paths. The panel names the reader that read each run
and its version. See [The Flow Runs panel](flow-runs.md).
