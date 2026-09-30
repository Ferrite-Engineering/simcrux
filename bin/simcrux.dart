// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:simcrux/core/cli/simcrux_cli.dart';

/// The headless `simcrux` binary.
///
/// Deliberately thin: everything testable lives in [SimcruxCli] under
/// `lib/`, so the CI behavior is covered by `flutter test` rather than
/// only by spawning processes. This file owns exactly the two things a
/// `lib/` file must not: reading the real argument vector, and calling
/// [exit]. Mirrors LintCrux's `bin/lintcrux.dart`.
///
/// Build it with:
///
/// ```bash
/// tool/build_cli.sh
/// # single self-contained executable:
/// build/cli/bundle/bin/simcrux --help
/// ```
///
/// (`dart compile exe` refuses to run while any package in the
/// resolution declares a build hook — Flutter plugins pulled in by the
/// desktop app do. `dart build cli` is the supported replacement; the
/// executable it emits under `bundle/bin/` runs standalone.)
Future<void> main(List<String> args) async {
  final cli = SimcruxCli();
  final code = await cli.run(
    args,
    stdoutSink: stdout.writeln,
    stderrSink: stderr.writeln,
  );
  // Flush before exiting: `exit()` does not wait for buffered stdout,
  // and a CI log missing its summary line because the process raced the
  // pipe is a genuinely miserable thing to debug.
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
