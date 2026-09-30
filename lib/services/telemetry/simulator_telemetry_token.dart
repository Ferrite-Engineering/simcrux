// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// Folds a `TestSpec.simulatorId` onto the closed `simulator` vocabulary
/// ([kSimcruxSimulatorTokens]).
///
/// A `simulatorId` is a **string from the user's project file**. For the six
/// built-in drivers it is one of our own ids and passes through unchanged; for
/// anything else it is whatever a plugin author (or a typo) put there, and
/// that is arbitrary text — it could be a path, a vendor tool name under NDA,
/// or a hostname. So everything outside the built-in set reports `plugin`.
///
/// This is the "map to a literal in a `switch`" case `telemetryEnumToken`'s
/// documentation carves out: the vocabulary is closed, it is just closed by
/// hand rather than by a Dart `enum`, because the ids arrive as YAML strings.
/// The list is spelled once, in the catalog, and the conformance test holds
/// this function's output inside it.
String simulatorTelemetryToken(String simulatorId) =>
    kSimcruxSimulatorTokens.contains(simulatorId) && simulatorId != 'plugin'
    ? simulatorId
    : 'plugin';

/// The `simulator` token for a whole regression, from the ids of the specs it
/// submitted.
///
/// One engine reports that engine; two or more report `mixed`; an empty run
/// reports `plugin`-free nothing — it returns `null`, and the caller omits the
/// property rather than inventing a value. A run with no specs never reaches
/// the recorder anyway (`RegressionRunner.start` returns early), so `null` is
/// a defensive answer to a case that should not arise.
///
/// `mixed` exists because SimCrux's signature workflow is running one
/// testbench across several engines in a single run. Reporting the majority
/// engine would overstate it and erase the others; reporting the first would
/// be arbitrary.
String? regressionSimulatorToken(Iterable<String> simulatorIds) {
  final tokens = <String>{
    for (final id in simulatorIds) simulatorTelemetryToken(id),
  };
  if (tokens.isEmpty) return null;
  if (tokens.length > 1) return 'mixed';
  return tokens.first;
}
