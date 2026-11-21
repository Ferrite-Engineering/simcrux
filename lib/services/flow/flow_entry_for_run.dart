// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';

/// The directory [entry] writes its runs into, inside [projectRoot]:
/// `runs/<entry>/` for nextpnr, the `runs/` beside the LibreLane config for
/// LibreLane. Null for a LibreLane entry with no config.
String? flowEntryRunsDir(FlowEntry entry, String projectRoot) {
  switch (entry.kind) {
    case FlowKind.nextpnr:
      return p.join(projectRoot, 'runs', entry.name);
    case FlowKind.librelane:
      final config = entry.config;
      if (config == null) return null;
      final absolute = p.isAbsolute(config)
          ? config
          : p.join(projectRoot, config);
      return p.join(p.dirname(p.normalize(absolute)), 'runs');
  }
}

/// The entry of [entries] that wrote the run at [runRoot]: the one whose run
/// directory holds it. When several entries share that directory (two
/// LibreLane entries on one config folder), the one whose tag prefix the
/// run's tag carries; null when that still leaves none or more than one, or
/// when no entry's directory holds the run.
///
/// A LibreLane run sits in the `runs/` beside its config, so the directory
/// above `runs/` names the config folder, never the entry: this is how a run
/// is matched to its entry (its name, its `gls:` block, its top).
FlowEntry? flowEntryForRun(
  List<FlowEntry> entries, {
  required String projectRoot,
  required String runRoot,
}) {
  final parent = _canonical(p.dirname(p.normalize(p.absolute(runRoot))));
  final owners = <FlowEntry>[
    for (final entry in entries)
      if (flowEntryRunsDir(entry, projectRoot) case final dir?
          when p.equals(_canonical(p.normalize(p.absolute(dir))), parent))
        entry,
  ];
  if (owners.length <= 1) return owners.firstOrNull;
  final tag = p.basename(runRoot);
  final prefixed = <FlowEntry>[
    for (final entry in owners)
      if (tag.startsWith('${entry.tagPrefix}-')) entry,
  ];
  return prefixed.length == 1 ? prefixed.single : null;
}

/// The LibreLane entry whose `gls:` block applies to the run at [runRoot]
/// when none is named: the one that wrote the run ([flowEntryForRun]), else
/// the project's only LibreLane entry; null when neither decides. The
/// command line (`flow gls`) and the app's Run Gate-Level Simulation share
/// it.
FlowEntry? flowGlsEntryForRun(
  List<FlowEntry> entries, {
  required String projectRoot,
  required String runRoot,
}) {
  final librelane = <FlowEntry>[
    for (final entry in entries)
      if (entry.kind == FlowKind.librelane) entry,
  ];
  return flowEntryForRun(
        librelane,
        projectRoot: projectRoot,
        runRoot: runRoot,
      ) ??
      (librelane.length == 1 ? librelane.single : null);
}

/// [path] with symbolic links resolved when it exists, so `/tmp` and
/// `/private/tmp` (macOS) compare equal; as given otherwise.
String _canonical(String path) {
  try {
    return p.normalize(Directory(path).resolveSymbolicLinksSync());
  } on FileSystemException {
    return path;
  }
}
