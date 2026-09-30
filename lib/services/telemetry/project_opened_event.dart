// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// Builds the `project.opened` event for a project reached by [source].
///
/// A builder rather than six copies of the same map, because SimCrux has six
/// genuinely distinct routes into a project — the file picker, the FuseSoC
/// importer, either RISC-V importer, the recents list, a `.simcrux-session`,
/// and the command line — and the *only* thing that differs between them is
/// the token. The event name stays a string literal here so the catalog's
/// source-scanning conformance test still sees it.
///
/// [source] must be a member of [kSimcruxProjectSourceTokens]; the assert
/// states the postcondition the Worker enforces, so a typo fails a debug build
/// here rather than silently losing the property in production.
///
/// **The path is never a parameter.** Every caller is holding one when it
/// calls this — that is the nature of opening a project — and a file path is
/// the first thing telemetry never collects. What ships is the route in,
/// not the destination.
TelemetryEvent projectOpenedEvent(String source) {
  assert(
    kSimcruxProjectSourceTokens.contains(source),
    'project.opened.source must be one of $kSimcruxProjectSourceTokens, '
    'got "$source"',
  );
  return TelemetryEvent(
    'project.opened',
    properties: <String, Object?>{'source': source},
  );
}
