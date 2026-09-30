// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/cli/cli_args.dart';

/// Holds the [CliArgs] the user passed at launch.
///
/// Overridden by `bootstrap()` in `lib/app.dart` with the result of
/// `CliArgParser().parse(args)`. The Welcome screen, the auto-open
/// project flow, the run dialog's default max-parallel value, and
/// the CI-mode bootstrap path all watch this provider rather than
/// re-parsing `args` themselves.
///
/// Tests override this provider directly with synthetic [CliArgs] —
/// no need to drive the parser end-to-end unless verifying the
/// parser itself.
final Provider<CliArgs> cliArgsProvider = Provider<CliArgs>(
  (ref) => const CliArgs(),
);
