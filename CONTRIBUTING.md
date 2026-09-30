# Contributing to SimCrux

Thanks for your interest in contributing to SimCrux. This document describes
how to file issues, submit pull requests, run the project's quality gates,
and certify the origin of your contributions.

SimCrux open core is licensed under the [Apache License 2.0](LICENSE). All
contributions you submit to this repository are accepted under that same
licence, and require a signed Contributor License Agreement — see
[Contributor License Agreement](#contributor-license-agreement-cla) below.

## Filing issues

Open issues at <https://github.com/Ferrite-Engineering/simcrux/issues>. A
useful issue includes:

- A short, descriptive title.
- The version of SimCrux you are using (or a Git commit SHA).
- The platform (Linux/macOS/Windows/Web) and version.
- **The simulator and its exact version** (`iverilog -V`, `verilator
  --version`, `ghdl --version`, `cocotb-config --version`). SimCrux drives
  these as external subprocesses, and their output formats differ across
  versions — a version-specific parse failure is a common bug class.
- Steps to reproduce, ideally with a minimal `simcrux.yaml` plus the
  smallest testbench that shows the problem.
- The expected behavior and the actual behavior you observed.
- The raw simulator stdout/stderr SimCrux captured, if any.

For security issues, please do **not** file a public issue. Contact the
maintainers privately via the email address listed in the Ferrite
Engineering GitHub organization profile.

## Submitting pull requests

1. **Fork** the repository and create a topic branch off `main`. Branch
   names follow `feature/short-description` or `fix/short-description` per
   the project's git conventions.
2. **Make your changes** following the conventions documented in
   [`CLAUDE.md`](CLAUDE.md) (the engineering manual for AI-assisted
   contributors and human reviewers alike) and
   [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). The most load-bearing
   rules:
   - **No hardcoded user-facing strings** — every string goes through the
     localization system. The five ARB files in `lib/l10n/` (`en`, `zh_CN`,
     `zh`, `ja`, `ko`) must stay in sync, and `app_zh.arb` mirrors
     `app_zh_CN.arb` byte-for-byte.
   - **Tests are mandatory** — every new or modified file in `lib/` has a
     corresponding test in `test/` mirroring the directory layout. Widget
     tests include a locale sweep across `en`, `zh_CN`, `ja`, `ko`.
   - **Riverpod providers are hand-written** — SimCrux ships zero
     `@riverpod`-annotated providers and no `.g.dart` output. Do not
     introduce `riverpod_generator` codegen for a single provider.
   - **Simulators run as subprocesses, never in-process** — every
     `SimulatorDriver` extends `ProcessBackedSimulatorDriver` and spawns an
     OS process. `dart:ffi`-style in-process loading of a simulator or a
     driver plugin is forbidden; see
     [`include/simcrux_driver_plugin_abi.md`](include/simcrux_driver_plugin_abi.md)
     for the licensing and crash-isolation rationale. A PR that links a
     simulator into the app process will not be merged.
   - **Open-core extension point first** — Pro features that need a hook in
     this repo land the extension-point interface here first; never fork
     code from this repo into the closed-source overlay.
3. **Run the quality gates locally** before pushing (see
   [Quality gates](#quality-gates) below).
4. **Sign the CLA** if you have not already — one time per
   contributor, not per pull request (see
   [Contributor License Agreement](#contributor-license-agreement-cla)
   below). It gates the merge, not the review, so open the pull
   request whenever you are ready.
5. **Open a pull request** against `main`. Use the [Conventional Commits](https://www.conventionalcommits.org/)
   prefix in both the commit subject and the PR title (`feat:`, `fix:`,
   `refactor:`, `docs:`, `test:`, `chore:`).

PRs should be focused — one logical change per PR. Reviewers will ask you
to split mixed PRs.

## Quality gates

Every PR must pass these locally before review:

```bash
# Dependencies (the crux-shared submodule must be checked out first:
# git submodule update --init --recursive)
flutter pub get

# Localization codegen (also runs automatically during build/run)
flutter gen-l10n

# Linting — zero warnings policy. Treat any warning as a blocker.
flutter analyze

# Full test suite. Must be green.
flutter test
```

There is no `build_runner` step — SimCrux uses hand-written Riverpod
providers and generates no `.g.dart` files.

CI runs the same gates on every PR; failures block merge.

## External simulators

SimCrux does **not** bundle, redistribute, or link any simulator. Icarus
Verilog, Verilator, GHDL, and cocotb are separate programs that you install
yourself; SimCrux resolves them on your `$PATH` (or at an explicit path you
configure in `simcrux.yaml`) and spawns them as child processes.

Tests that require a real simulator skip with an explanatory message when
the binary is absent, so `flutter test` is green on a machine with no
simulators installed. To exercise the simulator-backed suites, install the
relevant tool and re-run.

This process boundary is a licensing boundary as well as an engineering
one: Icarus Verilog and GHDL are GPL-licensed, and invoking them as separate
programs is what keeps SimCrux's own Apache-2.0 code cleanly separated from
their terms. See [`NOTICES`](NOTICES) §1.

## Coding conventions

The complete style and architecture guide lives in two places:

- [`CLAUDE.md`](CLAUDE.md) — the day-to-day engineering manual, optimized
  for both human contributors and AI-assisted authoring. Covers Dart style,
  widget architecture, Riverpod conventions, testing requirements,
  localization rules, and the project's git workflow.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the deeper architectural
  reference: layer responsibilities, the job scheduler and process-reaper
  design, the simulator-driver seam, results persistence, and the open-core
  extension points that the closed-source overlay plugs into.
  [`docs/cocotb-strategy.md`](docs/cocotb-strategy.md) records why the
  cocotb integration wraps `make` rather than cocotb's Python runner API.

Read both before submitting non-trivial changes.

## Contributor License Agreement (CLA)

SimCrux requires a signed **Contributor License Agreement** before your
first contribution can be merged. It is a one-time step per contributor, not
per pull request.

The CLA does two things. It confirms you have the right to submit what you
are submitting — that you wrote it, or are permitted to contribute it — and
it grants Ferrite Engineering the licence to distribute your contribution.
**That includes distributing it under commercial licences**, in the paid
editions built on this open core, not only under the Apache 2.0 terms this
repository ships under. That is the difference between this and a Developer
Certificate of Origin, and it is the reason we ask for a signature rather
than a sign-off line. You keep the copyright in your contribution and may
use it however else you like.

It is modelled on the Apache Software Foundation's CLAs, so if you have
signed one of those the shape will be familiar. It is a single form covering
both individual and entity contributors — there is no separate corporate
version. Read it at [`CLA.md`](CLA.md).

### How to sign

Read [`CLA.md`](CLA.md), then write to
[support@ferriteengineering.com](mailto:support@ferriteengineering.com)
with `CLA` in the subject line and we will send you the signing
instructions. If you are contributing as part of your employment, say so
and name the employer: work done on company time usually belongs to the
company, and the CLA's employer clause asks you to confirm you have their
permission to contribute it.

We intend to move this into the pull request itself, so that accepting is a
click rather than an email. Until that is in place, it is email.

Open the pull request whenever you like — the CLA only gates the merge, and
nobody wants you to do the work twice. We will tell you if it is outstanding.

The name you sign under must be your real legal name. A pull request author
and a signatory who cannot be matched to each other is one we cannot merge.

### Licence of submitted code

Your contribution is distributed under the **Apache License 2.0**, the same
licence as the rest of this repository. You retain copyright; the CLA grants
the rights needed to use, modify and redistribute the work.


**Do not paste GPL-licensed code into this repository.** SimCrux drives
GPL simulators across a process boundary; it never incorporates their
source. A contribution that copies code out of Icarus Verilog, GHDL, or any
other GPL project cannot be accepted, because you do not have
the right to submit it under Apache 2.0.

## Questions

If anything about contributing is unclear, open an issue with the
`question` label or start a discussion on the repository's GitHub
Discussions page.
