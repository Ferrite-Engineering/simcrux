# Use in VS Code

The **SimCrux extension** puts your regression in VS Code's Test Explorer, runs it as a task, and — when a bounded proof fails — opens the counterexample trace in a waveform tab beside the failing property.

It installs from the [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=ferrite-engineering.simcrux) and from [Open VSX](https://open-vsx.org/extension/ferrite-engineering/simcrux), which is where Cursor, Windsurf, VSCodium and Theia install from. To install all four EDACrux extensions at once, install the [EDACrux Suite](https://marketplace.visualstudio.com/items?itemName=ferrite-engineering.edacrux) pack.

## What it does { #what-it-does }

- **Your regression as a test tree.** Open a workspace containing a `simcrux.yaml` and its suites and tests appear in the Test Explorer before anything has run. After a run, the results file decorates each test with its state, duration and failure message. The extension works against `simcrux.yaml` by default; set `edacrux.sim.projectFile` to use a different config.
- **Run it from the editor.** **EDACrux: Run Regression** (or the `simcrux` task) runs `simcrux <config> --ci`, which writes the results the tree reads — see [Command line & CI](cli.md). The extension runs the `simcrux` found on your `PATH` unless `edacrux.sim.executable` names another. Source references and trace announcements in the output are clickable.
- **Formal verdicts stay distinct.** SymbiYosys results that VS Code would show as a plain failure keep their verdict — a counterexample found is not the same as an undecided proof — in the test's description, a filterable tag, and the failure message.
- **Counterexample beside the property.** Right-click a failing formal property and choose **Open Counterexample in WaveCrux** to open its trace in a WaveCrux tab next to the test tree. This needs the [WaveCrux extension](https://marketplace.visualstudio.com/items?itemName=ferrite-engineering.wavecrux); without it, the extension says so and links to it.

## What stays in the desktop app { #desktop }

Run history — trends, flaky-test detection, run-to-run comparison — needs the database the desktop app keeps. **EDACrux: Open This Project in SimCrux Desktop** opens the project there; see [Trends, flaky tests & seeds](trends-and-flaky.md).

Your VS Code window also joins the suite's cross-probe network as **one** peer, however many of the EDACrux extensions you install: a desktop app can ask it to open a source file at a line, and **EDACrux: Send Selection to Crux App** / **EDACrux: Highlight Selection in Crux App** send the identifier under your cursor to a running EDACrux app. See [Cross-probe & the suite](integrations.md).

## Commands, settings and telemetry { #reference }

The extension's listing on the [Marketplace](https://marketplace.visualstudio.com/items?itemName=ferrite-engineering.simcrux) has the full list of commands and settings. The extension sends usage statistics only while VS Code's own telemetry setting is on.
