// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';

/// A [TelemetryService] that keeps what it was handed.
///
/// Shared by every catalog call-site test in this repository: an event is
/// "recorded" only if it reaches a service, so the fake is the assertion
/// surface rather than a mock of one.
///
/// Lives here rather than beside its first caller because a test file
/// declares `main()`, which makes it an *executable library* — and
/// `unreachable_from_main` then flags any member of this class that the
/// declaring file happens not to call itself, blind to the other suites
/// that do. A support library has no `main()`, so the rule does not apply.
class RecordingTelemetryService implements TelemetryService {
  /// Every event recorded, in order.
  final List<TelemetryEvent> events = <TelemetryEvent>[];

  /// The events named [name].
  List<TelemetryEvent> named(String name) =>
      events.where((event) => event.name == name).toList();

  @override
  void record(TelemetryEvent event) => events.add(event);
}
