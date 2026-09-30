# Updates, usage statistics & issue reporting

Three pieces of plumbing the SimCrux desktop app carries. None of them
exists in the read-only web dashboard.

## Update checks

SimCrux checks a release manifest and tells you when a newer version is
out. It never downloads or installs anything by itself.

**What happens.** On launch, once every 24 hours while the app is
running, and when the app returns to the foreground, SimCrux fetches
`https://updates.simcrux.app/manifest.json` (10-second timeout). If the
latest version is newer than the running build, a strip appears above the
app content:

> **SimCrux x.y.z is available.** &nbsp; [View Changes] &nbsp;
> [Update Now] &nbsp; ✕

- **View Changes** opens the release changelog, when the manifest carries
  one.
- **Update Now** opens `https://simcrux.app/download` in your browser.
  There is no in-app download and no self-update.
- **✕** dismisses the banner for this session and this version only. A
  release flagged mandatory has no dismiss button.

**Turning it off.** `Settings → General → Automatically check for
updates` (on by default). It gates the launch check, the daily check and
the on-resume check — but never the manual one.

**Checking by hand.** `Help → Check for Updates` (on macOS, in the
SimCrux application menu), the command palette, or the **Check for
Updates** button in the About box. You get a "Checking for updates…"
notice, then either the banner, "You're on the latest version (x.y.z)",
or "Couldn't check for updates".

**What is sent.** A plain `GET` for a static manifest whose `User-Agent`
header carries only the app name, its version and your operating system.
Never project, design or result data.

## Usage statistics

SimCrux can send anonymous usage statistics. This section describes what it
sends and how you control it.

**Where you decide.** On first launch a one-time notice, **Help make
SimCrux better**, shows a **Send anonymous usage statistics** switch above
**Continue**; **See exactly what's collected** opens the full field list at
[edacrux.app/telemetry](https://edacrux.app/telemetry). The switch starts
on, except where the machine's regional settings place it in the EEA, the
UK, Switzerland or South Korea, where it starts off. Change your answer at
any time in `Settings → Privacy`, which also shows the random
**Installation ID** — the only identifier attached to what is sent — so you
can ask support to delete that installation's data.

**What is sent.** Feature and error counters, app and OS version, form
factor, language and license tier. An error the app did not handle is
counted by its kind alone (for example, a state error in the widgets
library), never with its message or stack trace. Never test names, log
contents, file paths or personal information. Events are queued on disk and
sent in batches.

**Headless runs.** `simcrux --ci` and `simcrux export-dashboard`, run
through the desktop app's executable, send counters only if usage
statistics are switched on in that app on the same machine; they never ask,
so a build agent where the app has never been opened sends nothing. The
standalone `simcrux` CLI binary never sends anything.

## Reporting issues

The fastest way to get something fixed is the built-in issue reporter —
`Help → Submit Issue…`, the command palette, or the About box.

1. **Give the issue a short title.**
2. **Choose what to attach.** SimCrux assembles the diagnostic context as
   four categories, each with a live preview of exactly what will be
   included:

   | Category | What it attaches |
   | --- | --- |
   | **App & Environment** *(always included)* | App name, version and build number, build SHA, platform, OS, architecture, screen DPI, locale, Flutter and Dart SDK versions. |
   | **Session State** | Open project-tab count; whether a project is loaded; config schema version; suite and test **counts**; the simulator ids the project uses; the **number** of `simulators:` binary overrides; the registered driver ids; detected simulator versions (path-scrubbed); run state; tests in the run; and results recorded / passed / failed. |
   | **Diagnostics** | The last 100 warning-or-higher log entries plus the last 20 entries at any level, captured this session. |
   | **Screenshot** | A PNG of the app window, saved to disk and revealed in your file manager so you can drag it in. Desktop only. |

3. **Submit.** SimCrux copies a well-formed report to your clipboard and
   opens a pre-filled issue on the `Ferrite-Engineering/simcrux` GitHub
   repository.
   Short reports are pre-filled into the body; otherwise paste from the
   clipboard.

Opening the reporter probes each built-in driver for its version, so the
dialog may take a moment on first open. That probe is deliberately lazy —
it never runs at startup.

### Privacy posture

Every field is a count, a fixed enumeration value, a simulator id, or a
scrubbed version string. The report never contains:

- the project file path — often the employer or project name;
- suite names, test names or `top` module names — those are your
  identifiers;
- stdout/stderr/waveform paths, or failure messages;
- the *values* of your simulator binary overrides or recent-project
  paths — only how many there are;
- the Tab Diagnostics report ("Copy tab diagnostics report"), which is
  deliberately excluded because it opens with an absolute config path.

Detected version banners are scrubbed: any whitespace-delimited token
containing `/`, `\` or a Windows drive prefix is replaced with
`(redacted)`, because a locally built toolchain can print its install
prefix in its `--version` output. A named regression test enforces the
no-paths property.

Everything except **App & Environment** is a toggle, and nothing leaves
your machine until you press Submit.
