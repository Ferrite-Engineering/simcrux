// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The subset of `crux_telemetry` a **Flutter-free** entry point can link.
///
/// SimCrux gained a second surface alongside the desktop app: the headless
/// `simcrux` binary that `dart build cli` compiles from `bin/simcrux.dart`
/// (the CI prerequisite for the FuseSoC/Edalize EDAM integration — an
/// Edalize node must run without a window). That binary has no `dart:ui`,
/// so it can import neither `package:flutter/...` nor any Flutter plugin —
/// and `crux_telemetry`'s barrel pulls in both (`flutter_riverpod` for the
/// providers and the consent widgets, `flutter/foundation` for the `os`
/// derivation). Importing the barrel from anything the CLI reaches would
/// fail the CLI build outright.
///
/// So the CLI-reachable half of SimCrux — `CiRunner`,
/// `DashboardBundleWriter`, and everything under `SimcruxCli` — imports
/// **this** file instead. It re-exports only the libraries inside
/// `crux_telemetry` that are pure Dart: the event model, the service
/// interface and its no-op, and the enum-token helper.
/// `tool/build_cli.sh` is what actually proves the Flutter-freeness;
/// `verification/` runs it.
///
/// The `src/` imports are deliberate and are the reason this file exists
/// rather than the imports being spread across the CLI tree —
/// LintCrux's `lib/core/telemetry/crux_telemetry_headless.dart` set the
/// suite pattern, and this file mirrors it. If `crux_telemetry` ever grows
/// a `crux_telemetry_core.dart` barrel of its own, both files collapse
/// into a single re-export of it and nothing else changes.
library;

export 'package:crux_telemetry/src/models/telemetry_event.dart';
export 'package:crux_telemetry/src/services/noop_telemetry_service.dart';
export 'package:crux_telemetry/src/telemetry_enum_token.dart';
export 'package:crux_telemetry/src/telemetry_service.dart';
