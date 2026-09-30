# The web dashboard

SimCrux ships a **read-only Flutter Web build** of its dashboard. The
exported bundle is a static directory you can serve from any HTTP host
— GitHub Pages, S3, Netlify, an internal nginx — and it requires no
SimCrux server. A hosted copy of the viewer runs at
[app.simcrux.app](https://app.simcrux.app/).

This page covers what the web build can and cannot do, and the
operational guarantees of the exported bundle.

## What the web build is

The web build renders the regression results that come bundled with
the site as a static document. It does not run simulators, schedule
work, or store any state.

What you get on the web:

- The results list — one row per test with status, id, suite, simulator
  and runtime; status filter chips (`pass`, `fail`, `timeout`, `skipped`,
  `unknown`) and a free-text query against test id / suite / simulator.
- The inspector dialog — click any row for status, runtime, suite,
  simulator, exit code, failure message, and metrics.
- A status-bar summary line with total / passed / failed / timed out /
  skipped counts.
- An **Open results file…** button that loads a local
  `simcrux-results.json` or `results.ndjson` from your machine. The file
  is read in the browser and never uploaded.
- Deep-linkable URLs via the `?results=<url>` query parameter (see
  below).
- The full localization set — `en`, `zh_CN`, `zh`, `ja`, `ko`. The
  browser's language preference picks the locale automatically.

What the web build **does not** have (these are desktop-only and the
underlying browser model rules them out):

- Live simulator orchestration. No Icarus / Verilator / GHDL / Cocotb
  processes are spawned by the web build.
- Cross-run trend history. It lives in the desktop app's SQLite store,
  which a browser cannot open.
- The file watcher and auto-reload. Both depend on filesystem
  notifications.
- Cross-probe. A browser cannot open the TCP sockets CXP uses.
- The scheduler controls, the settings screen, the diagnostics
  surfaces and the update banner. The web entrypoint
  (`lib/main_web.dart`) does not include them at all.

## Where the results JSON comes from

The web app reads either of two formats from same-origin paths next to
the served `index.html`:

| File | Produced by | Notes |
|---|---|---|
| `simcrux-results.json` | `simcrux export-dashboard <out-dir>` (or your own consolidation script) | The canonical static-site shape. Single JSON object containing the run envelope + per-test list. |
| `results.ndjson` | `simcrux --ci`, which always writes it next to `simcrux.yaml` | The streaming variant — one JSON object per line. The web build decodes this directly when `simcrux-results.json` is missing or a 404. A file cut off mid-run still loads. |

The auto-detection order is:

1. `?results=<url>` query parameter (if set, fetched verbatim).
2. `./simcrux-results.json` (same origin).
3. `./results.ndjson` (same origin) as fallback.

A file opened with **Open results file…** replaces whichever of these
loaded.

## Deep-linking

The web dashboard reads the URL on first paint:

- `?results=https://ci.example.com/runs/42/results.ndjson` — fetch a
  remote document instead of the bundled one. Useful for hosting one
  copy of the dashboard and pointing it at per-PR or per-run artifacts.
  When the document is on a different origin from the dashboard, its
  host must allow cross-origin requests (CORS), or the browser blocks the
  fetch.

`results` is the only parameter read from the URL; filters and the
selected test are not.

## Building the web bundle yourself

In a SimCrux source checkout:

```bash
flutter build web --target lib/main_web.dart --release
```

The `--target` matters: without it Flutter builds `lib/main.dart`, the
desktop app's shell, not the viewer. The bundle lands at `build/web/`.
Drop your `simcrux-results.json` (or `results.ndjson`) into the same
directory and serve.

`simcrux export-dashboard <out-dir>` automates this: it writes
`simcrux-results.json` from a `--results` file and (with
`--web-bundle build/web/`) copies the pre-built bundle alongside. Hosting and
per-run CI recipes are on
[Publishing the results dashboard](ci-integration.md).

## Limitations to be explicit about

- **No live data.** The page is a static snapshot. Reload the URL
  after a new export to see updated results.
- **No logs or waveforms.** stdout / stderr and waveform paths in the
  JSON refer to filesystem locations on the machine that ran the
  regression. They are not served by the web bundle.
- **Paths travel with the results.** The JSON records the config path and
  those per-test paths, plus failure messages. Review them before
  publishing a dashboard on a public host.
- **No editing.** All settings, filter presets, and detector
  configuration UIs are desktop-only.
