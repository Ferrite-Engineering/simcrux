# simcrux

Open-core regression runner and results dashboard for HDL simulators, part of Ferrite Engineering's EDACrux suite.

Architecture & engineering manual (read sections explicitly when needed; no auto-load): `docs/ARCHITECTURE.md`

User documentation: `docs-site/docs/`, published at `https://docs.simcrux.app`. Suite-level policy that applies to every product has public pages under `https://edacrux.app/` — licensing, telemetry, privacy, terms, the CXP specification (`https://edacrux.app/cxp`).

**IMPORTANT:** None of the docs referenced here are auto-loaded into context (no `@` prefix). `docs/ARCHITECTURE.md` and the verification guide are long: locate the right anchor with `grep` first, then read the specific section.

## Reference implementation: WaveCrux

WaveCrux is the canonical implementation of this open-core + Pro/Enterprise overlay pattern. When a convention, file layout, naming choice, or architectural seam is unclear in this project, consult WaveCrux's open-core repository first:

- Open-core repo: `wavecrux`
- Open-core conventions: `wavecrux/CLAUDE.md`
- Engineering manual: `wavecrux/docs/ARCHITECTURE.md`

Match WaveCrux's pattern unless this project has a documented reason to diverge. When you find yourself solving a problem that WaveCrux likely already solved, read its implementation before writing a new one.

## Tech Stack

- **Framework:** Flutter (Dart)
- **State Management:** Riverpod, declared **manually** — no code generation. Every provider is a hand-written top-level `final xProvider = ...Provider(...)`. The repo ships zero `@riverpod`-annotated providers and no `.g.dart` output; do not introduce `riverpod_generator`/`build_runner` codegen without converting the whole codebase and updating this section.
- **Domain Models:** Plain immutable Dart classes with `copyWith`/equality (no freezed)
- **Lints:** `very_good_analysis` (zero-warnings policy)

The rest of the stack is chosen: `go_router` for routing, the `panes` split-pane layout through the shared `crux_ide_layout` package, SQLite (`sqflite_common_ffi`, opened through `crux_sqlite`) for the trend store, and the `crux-shared` packages for suite chrome, CXP, settings, workspace tabs, updates and telemetry. Simulators are external programs spawned as subprocesses — nothing is linked in-process. `docs/ARCHITECTURE.md` §2 has the detail; default to WaveCrux's choices when adding something the domains share.

## Platform Targets

Desktop-first (Linux/macOS/Windows), plus a **read-only web dashboard viewer**. **Mobile is out of scope; web is not** — a static, read-only results-dashboard viewer ships and is built from this open-core package.

| Platform | Notes |
|----------|-------|
| **Linux** | Primary target; x86_64 (especially CI runners) |
| **macOS** | Universal binary (Intel + Apple Silicon) |
| **Windows** | x86_64 |
| **Web** | Read-only dashboard viewer only — a separate entrypoint, `lib/main_web.dart`. Loads a `simcrux-results.json` / `results.ndjson` document (a run's streaming NDJSON, or the bundle `simcrux export-dashboard` writes) from `?results=<url>`, a same-origin file, or the in-app file picker; deployed to `app.simcrux.app`. Browsers can't spawn simulators, so orchestration, process management, and disk persistence are desktop-only. The web build is Open-Core-only (no paid tiers on web — client-side gating is bypassable). |

There is no `Device Class` system in simcrux — the equivalent rules in WaveCrux exist because WaveCrux runs on phone/tablet/desktop. The desktop app's only layout is the `SimcruxIdeLayout` split-pane host; the web viewer is a single-screen `Scaffold` (`lib/web/web_dashboard_screen.dart`) sized for desktop-class browser viewports. Read WaveCrux's device-class rules as background, but do not import the breakpoint or `MobileMetrics` infrastructure unless and until simcrux gains a phone/tablet target.

## Build & Run Commands

```bash
# Run app (desktop)
flutter run -d macos    # or -d linux, -d windows

# Run the read-only web dashboard viewer (a separate entrypoint)
flutter run -d chrome -t lib/main_web.dart

# Build the headless `simcrux` CLI binary (bin/simcrux.dart → build/cli/bundle/bin/simcrux)
tool/build_cli.sh

# Run all tests
flutter test

# Run single test file
flutter test test/path/to/test_file.dart

# Lint (zero warnings policy — CI runs it with --fatal-infos --fatal-warnings)
flutter analyze --fatal-infos --fatal-warnings

# Generate localization files (flutter gen-l10n)
# Runs automatically during build/run when `generate: true` is set in pubspec
flutter gen-l10n
```

## Coding Conventions

### IMPORTANT: Project config filename is `simcrux.yaml` (NOT a dotfile)

The canonical per-project config file is named `simcrux.yaml` — a named file
with a `.yaml` extension. Do NOT introduce dotfile names like `.simcrux.yaml`,
`.simcrux-config`, etc. for user-visible files. The cross-suite reasoning is
in [crux-shared/docs/adr/0001-project-config-filename-convention.md](crux-shared/docs/adr/0001-project-config-filename-convention.md);
the short version is that macOS Finder and most native file pickers hide
dotfiles by default, so canonical user-facing config files must use a named
pattern. Pure tooling caches (e.g. a hypothetical `.simcrux-cache/`) may
still use a dotfile name; consult the ADR before adding one.

The suite design manifest follows the same rule: it is a user-named
`<design>.crux-project` (crux-shared ADR 0004), opened through
`openConfigAsTab` in `lib/features/workspace/widgets/open_config_tab.dart`.

### IMPORTANT: No Hardcoded Strings

Every user-facing string MUST come from the localization system (ARB files). No string literals displayed to users anywhere in widget, screen, or service code. The only exception is test code.

`lib/app.dart` is real application code — the `bootstrap()` entry point plus `SimcruxApp` wiring theme/localization/router — with no placeholder or `TODO(setup)` strings remaining. Every user-facing string it (and the action-handler map in `lib/core/shortcuts/simcrux_action_handlers.dart`) renders is already ARB-sourced. Keep it that way.

### IMPORTANT: Tests Required for All New Code

Every new or modified Dart file in `lib/` MUST have a corresponding test file in `test/` mirroring the same directory structure. When generating production code, YOU MUST also generate the tests in the same response. Do not wait to be asked — tests are not optional.

- Domain models: Unit tests for equality, copyWith, and any computed properties.
- Services: Unit tests covering happy path, edge cases, and error handling.
- Providers: Unit tests using `ProviderContainer`. Verify state transitions and async behavior.
- Widgets: Widget tests for key interactions and layout. Locale sweep (`en`, `zh_CN`, `ja`, `ko`) — [`test/static/locale_sweep_guard_test.dart`](test/static/locale_sweep_guard_test.dart) checks for it. Use `expect(tester.takeException(), isNull)` after pumping.
- Use `mocktail` (not `mockito`).
- Test file naming: `test/<mirror of the lib/ path>_test.dart`

### IMPORTANT: Widget Architecture

- **One widget per file.** Each public widget class lives in its own `.dart` file in `snake_case`.
- **Keep widgets small.** If `build()` exceeds ~50 lines or has 3+ nesting levels, extract child sections into their own files.
- **Build for reuse.** Leaf widgets accept data and callbacks via constructor.
- **Stateless over stateful.** Prefer `ConsumerWidget` with Riverpod. Only use `StatefulWidget` for local mutable state (animations, focus, gesture handlers).
- **Composition over configuration.** Distinct widget variants over boolean flags.

### IMPORTANT: Screen-reader and keyboard accessibility

An external NVDA screen-reader pass on WaveCrux found the suite unusable by ear in ways every automated guard passed: silence at launch, bare "text" Tab stops, rows of unlabelled check boxes, Space not activating buttons, a failed load announced as nothing. SimCrux's first walk found the same row shape in the results table. These rules are the definition of done for any UI change here.

- **A new or changed surface gets a focus walk.** Follow `test/accessibility/screen_reader_test.dart`: `expectFocusAnnounced` where focus must land, `walkFocus` + `expectCleanFocusWalk`, and for a primary surface a transcript golden under `test/accessibility/goldens/` that you read before committing (`flutter test --update-goldens test/accessibility`). A golden diff is a change in what a blind user hears — review it like a UI diff.
- **Focus always lands somewhere named.** `WorkspaceScreen` is a `CruxFocusRegionScope`: top-level chrome (toolbar, bottom chrome) goes in a `CruxFocusRegion`, the start screen is the primary region, and a tab's IDE layout supplies its own regions — never wrap a region around it. Never add an unnamed `Focus(autofocus: true)` holder around a large subtree — it absorbs every label below it.
- **One name per control, one node per row.** A label or a tooltip, not both. A list row is one named node: the results table names each row's check box with the row sentence, keeps the row gesture out of semantics and focus (`excludeFromSemantics`, `canRequestFocus: false`), and excludes the cells and status icon the sentence already says. Whatever the pointer can do to a row the keyboard must reach from that one stop — Enter on the check box opens the row, Space toggles it. Status drawn only as an icon's color goes into the name.
- **Errors and completions are announced** with `announceCrux` — a snackbar or a red pane is silent on desktop (see the config-load failure in `lib/features/workspace/widgets/regression_tab_content.dart`).
- **Space and Enter belong to the focused control.** A bare-key binding must not consume them when the focused widget accepts `ActivateIntent` (see `lib/core/shortcuts/shortcut_manager_widget.dart`).
- **No arrows or box glyphs in ARB strings** — `test/static/speakable_strings_test.dart` enforces it. Write menu paths as `Settings > AI`.

### Dart Style

- Effective Dart guidelines.
- Files: `snake_case.dart`. Classes: `PascalCase`. Variables/functions: `camelCase`. Constants: `camelCase` (Dart convention). Providers: `camelCase` ending in `Provider`. Private members: `_prefixed`.
- No `!` operator unless the non-null contract is provably guaranteed and documented with a comment.

### Riverpod

- **Declare providers manually** — a top-level `final xProvider = Provider(...)` /
  `NotifierProvider(...)` / `FutureProvider.family(...)`. The codebase uses **no**
  `@riverpod` codegen (no `riverpod_generator`, no `build_runner`, no `.g.dart`);
  match the surrounding manual style. Converting to codegen is an all-or-nothing
  decision, not a per-provider one — don't mix the two.
- Providers live in `providers/` within each feature module. Provider *wiring* is
  a feature-layer concern: a provider that composes feature state (reads settings,
  dashboard, workspace, …) belongs under `features/`, never `services/` — see
  `docs/ARCHITECTURE.md` §6.2 and the layering guard in
  `test/static/import_layering_test.dart`.
- Providers should be thin — delegate logic to services.
- Never use `ref.read` in a widget's `build` method — use `ref.watch`.

### Localization

- 4 locales shipped: English (`en`), Simplified Chinese (`zh_CN`), Japanese (`ja`), Korean (`ko`). Same as WaveCrux.
- ARB files live in `lib/l10n/`. `app_en.arb` is the primary source of truth.
- `app_zh.arb` mirrors `app_zh_CN.arb` (identical translations, `@@locale` set to `zh`) so users on a bare `zh` locale get Simplified Chinese. That mirror makes **five** ARB files for the four locales. Every edit to `app_zh_CN.arb` must be applied to `app_zh.arb` verbatim — the static guard test [`test/static/l10n_house_style_guard_test.dart`](test/static/l10n_house_style_guard_test.dart) enforces both the key parity across all five files **and** the byte-exact zh mirror (plus ICU `=1` plural cases, U+2026 ellipsis, and CJK punctuation width). Run it after any ARB change.
- Every message must have a corresponding `@<key>` metadata entry with a `description` field (in English).
- **Translation house style and glossary:** [`.claude/instructions.md`](.claude/instructions.md) is SimCrux's copy of the suite CJK house style (canonical source: `wavecrux/.claude/instructions.md`) — core principles, the SimCrux glossary (testbench/regression/pass/flaky/trend/seed/simulator/…), suite-wide terms, acronym/brand never-translate lists, ICU plural rules, per-language rules. [`assets/l10n/glossary.json`](assets/l10n/glossary.json) is the machine-readable version. Read both before adding or modifying any CJK string, and point any translation-audit tooling at them first.

Localization is fully set up, with full four-locale parity across the five ARB files. Follow `wavecrux/lib/l10n/`'s conventions for any new strings.

## Project Structure

The layout mirrors WaveCrux's open-core structure:

```
bin/simcrux.dart        # headless CLI entrypoint (built by tool/build_cli.sh)
lib/
├── app.dart            # bootstrap function + root widget
├── main.dart           # calls runSimcrux(args: args) → bootstrap
├── main_web.dart       # read-only web dashboard viewer entrypoint
├── core/               # Theme, router, shortcuts/actions, CLI parsing, update/telemetry glue
├── l10n/               # Localization: ARB source files + generated/
├── domain/             # Pure Dart: models, enums, interfaces — ZERO Flutter imports
├── services/           # Non-UI services — drivers, scheduler, config loader, stores, exporters
├── features/           # Feature modules (each owns its providers, screens, widgets)
├── shared/             # Shared widgets
├── plugins/            # App-level extension-point providers (extra l10n delegates, status-bar widgets)
└── web/                # The web viewer's screen, loaders and widgets
```

## Key Architecture Rules

- **Domain layer has zero Flutter imports.** Pure Dart only. Models, enums, and interfaces live here.
- **Features depend on domain interfaces**, not service implementations.
- **The Pro overlay consumes this repo as a Git submodule.** It registers Pro/Enterprise concrete implementations via Riverpod overrides spread into the `bootstrap()` `ProviderScope`. Do not fork open-core code in the Pro overlay; if a Pro feature needs a new hook, define the extension-point interface here first, push, bump the submodule pin, then add the Pro implementation. See `wavecrux/CLAUDE.md` for the binding rule.
- **Open-core conflict semantics:** open-core overrides come first; Pro overrides spread last; later overrides win. Mirrors WaveCrux.

### IMPORTANT: Verification Documentation Required

The `verification/` folder is the binding pre-release manual-verification reference for every Open Core SimCrux feature. It is **scaffolded from day one** so verification entries are written as features land — not retrofitted later (the WaveCrux mistake we are explicitly not repeating).

- [`verification/VERIFICATION_GUIDE.md`](verification/VERIFICATION_GUIDE.md) — detailed pre-release verification reference for every Open Core feature.
- [`verification/VERIFICATION_CHECKLIST.md`](verification/VERIFICATION_CHECKLIST.md) — quick sign-off bullet list per release.
- [`verification/fixtures/`](verification/fixtures/) — committed fixtures, one directory per family (`orchestration/` scheduler scenarios, `golden_compare/` detector signature pairs, `riscv_formal/` hand-authored `sby` output replayed in demo mode), each regenerated by a `tool/generate_*_fixtures.dart` script.

When you implement a new Open Core feature, add a `SimulatorDriver` adapter, change the test config schema, add an extension-point seam, or make any change visible to a user of the open-core build, the same change set MUST:

1. **Add or update the feature's section** in `verification/VERIFICATION_GUIDE.md`. Populate: what it does (plain language), setup, step-by-step expected behavior, edge cases. The Automation Assessment / Coverage tag is mandatory on every bullet.
2. Add or update the corresponding bullet group in `verification/VERIFICATION_CHECKLIST.md`, including any new fixture references.
3. Commit any new fixtures under `verification/fixtures/<family>/` alongside their expected-output companions, with the regenerator script under `tool/` documented in `verification/fixtures/README.md`.
4. **Pro features go in the Pro overlay verification, not here.** If your work is a Pro/Enterprise feature (flaky-test detection, the dashboard-row cross-probe originate menu, distributed execution, audit logging), the verification entry belongs in the Pro overlay's own verification guide. This open-core guide covers only what every open-core user can see — including "Debug in WaveCrux" from the inspector, which is open core.
5. **Don't ship implementation without its verification entry.** A feature shipping in code without a populated verification entry in the same commit set is a code-review-blocking defect — same rule as WaveCrux.

## User documentation lives in `docs-site/`

`docs-site/docs/` (MkDocs Material) is the source of truth for user
documentation, published at `https://docs.simcrux.app`. A change to
user-visible behaviour — a label, shortcut, flag, config key, file
format, tier or platform availability — updates the affected page in the
same change. Build with `mkdocs build --strict` from `docs-site/` (pinned
versions in `.github/workflows/docs.yml`); CI fails a broken link or
anchor. Keep page file names stable: in-app help links point at them.

## Git Conventions

- Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`
- Branch naming: `feature/xxx`, `fix/xxx`. `main` is always deployable.
- This repository is public. Never reference private repositories, plans or tracker ids in code, comments, tests or docs — state the reason inline or link a public page. [`test/static/no_private_references_test.dart`](test/static/no_private_references_test.dart) enforces it over every tracked file.

## Changes land through pull requests

Until the 1.0 code freeze, maintainers commit directly to `main`. From the
code freeze on, every change — by anyone — lands through a pull request
whose description documents the issue or feature, the fix or
implementation, how it was verified (tests added, CI gates passed), and
the user documentation updated in the same PR. Contributors sign a CLA
before a first merge, as described in `CONTRIBUTING.md`.

## Licensing

Apache License 2.0 — see [`LICENSE`](LICENSE), with third-party attributions in [`NOTICES`](NOTICES) and the name/logo policy in [`TRADEMARK.md`](TRADEMARK.md). Contributions require a signed CLA; see [`CONTRIBUTING.md`](CONTRIBUTING.md). The simulators SimCrux drives are separate programs under their own licenses, which is why they are only ever spawned as subprocesses.

## Suite UI consistency (MANDATORY for any UI change)

The four Crux apps (WaveCrux, NetCrux, LintCrux, SimCrux) are built as if they
were ONE app, with WaveCrux as the canon. The rules for any UI surface:

1. **Mirror-check:** a change to a shared surface (menus, toolbar, status bar,
   docks/panels, welcome screen, window chrome, Settings, dialogs, shortcuts,
   shared l10n keys) must be applied to the OTHER THREE apps in the same
   change set — or explicitly flagged as pending. Never diverge silently. The
   sibling apps are the `wavecrux`, `netcrux` and `lintcrux` open-core
   repositories.
2. **New surface:** adding a dialog / panel / dock tab / settings category /
   banner here requires answering "do the other three apps need this?" — and
   generic chrome starts life in crux-shared (`crux_dock`, `crux_workspace`,
   `crux_settings_ui`, `crux_cxp_ui`, ...), never as an app-local copy.
3. **Canon details:** WaveCrux is canonical unless a documented suite-wide
   exception says otherwise. Workflow dialogs are
   `barrierDismissible: false`; settings categories use WaveCrux's order and
   icons; l10n keys for shared strings use WaveCrux-style names in all four
   apps; the Language picker requires `MaterialApp.locale` wiring.
4. **Verify like CI:** `flutter analyze --fatal-infos --fatal-warnings` (the
   crux-shared Consumer CI fails on infos; plain `dart analyze` won't) + the
   full test suite for every repo you touched.
5. **User docs:** if you changed a user-visible usage model (panel
   behavior, shortcut, settings layout, menu location, dialog flow), update
   `docs-site/docs/` in the same change — grep it for the OLD wording — and
   check the other three products' `docs-site/` when the change was
   suite-wide.
