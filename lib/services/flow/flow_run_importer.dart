// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// Turns the `flow:` entries the loader parsed into `TestSpec`s, at load
/// time: one entry is one spec, and the specs form one synthesised suite,
/// [kFlowSuiteName].
///
/// A flow run is a sequence of steps, not a set of independent jobs, so the
/// steps are a sub-model of the run read from its directory and never jobs
/// of their own: one entry, one spec, one result.
///
/// The rules every spec gets:
///
/// - `simulatorId` is the entry's kind, `librelane` or `nextpnr`;
/// - a LibreLane entry holds the `flow` [ResourceLock], so one LibreLane run
///   happens at a time within a regression (the lock is a per-run mutex with
///   no capacity); a nextpnr entry takes no lock and is bounded by
///   `--max-parallel` and the simulator budget like any other test;
/// - the timeout is [kFlowTimeout];
/// - no retry: the scheduler never reruns a spec that carries a flow entry,
///   because a flow run is deterministic and expensive.
class FlowRunImporter {
  /// Creates the importer.
  const FlowRunImporter();

  /// The suite the flow specs belong to. A project with flow entries may not
  /// declare a suite of the same name.
  static const String kFlowSuiteName = 'flow';

  /// The resource lock every LibreLane spec holds.
  static const ResourceLock kFlowLock = ResourceLock(name: 'flow');

  /// The per-run timeout of a flow spec.
  static const Duration kFlowTimeout = Duration(hours: 4);

  /// The spec id of the entry named [name].
  static String specIdFor(String name) => '$kFlowSuiteName/$name';

  /// Resolves [entry]'s project paths against [projectRoot].
  ///
  /// `config`, `constraints` and `sources` become absolute and normalised;
  /// executable paths (`librelane_binary`, `fusesoc.binary`) stay as written,
  /// because they are install locations, not project files.
  FlowEntry resolve(FlowEntry entry, String projectRoot) {
    final root = p.normalize(p.absolute(projectRoot));
    String abs(String path) => p.isAbsolute(path)
        ? p.normalize(path)
        : p.normalize(p.join(root, path));
    final config = entry.config;
    final constraints = entry.constraints;
    return entry.copyWith(
      config: config == null ? null : abs(config),
      constraints: constraints == null ? null : abs(constraints),
      sources: entry.sources.map(abs).toList(growable: false),
      projectRoot: root,
    );
  }

  /// Why [entry] (already [resolve]d) cannot run from this project, or null.
  ///
  /// A LibreLane run directory is `runs/<tag>/` beside its configuration, so
  /// the configuration must lie inside the project: a run root outside the
  /// project would be a directory the project file chose for LibreLane to
  /// write into. Symlinks are judged again, by the filesystem, when the run
  /// starts.
  String? problemFor(FlowEntry entry) {
    final root = entry.projectRoot;
    final config = entry.config;
    if (entry.kind == FlowKind.librelane && root != null && config != null) {
      if (!p.isWithin(root, config)) {
        return 'Flow entry `${entry.name}`: `config` must be inside the '
            'project directory, because LibreLane writes its run directory '
            'beside it.';
      }
    }
    return null;
  }

  /// The spec for one resolved [entry].
  TestSpec specFor(FlowEntry entry) => TestSpec(
    id: specIdFor(entry.name),
    name: entry.name,
    suiteName: kFlowSuiteName,
    simulatorId: entry.kind.wireName,
    // The nextpnr top module; a LibreLane design names its own top in its
    // configuration, so the entry name stands in.
    top: entry.top ?? entry.name,
    sources: entry.sources,
    resources: entry.kind == FlowKind.librelane
        ? const <ResourceLock>[kFlowLock]
        : const <ResourceLock>[],
    timeout: kFlowTimeout,
    flow: entry,
  );

  /// The synthesised suite for [entries], already resolved.
  Suite suiteFor(List<FlowEntry> entries) => Suite(
    name: kFlowSuiteName,
    description: 'Implementation flows',
    tests: entries.map(specFor).toList(growable: false),
  );
}
