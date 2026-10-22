// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';

import 'flow_panel_harness.dart';

/// The worst-paths provider hands the run's flow entry's `netlist:` to the
/// mapping: the entry the run's design names, and no other.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory tmp;

  setUp(
    () => tmp = Directory(
      Directory.systemTemp
          .createTempSync('flow_provider_')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A run of fixture `path_ice40_met` whose netlist is `named.json` and
  /// `other.json` (so neither is the only one), read through the provider
  /// for design [design] in a project whose entries are [entries].
  Future<bool> mapped({
    required List<FlowEntry> entries,
    required String design,
  }) async {
    final root = Directory(p.join(tmp.path, 'runs', 'adder', 't1'))
      ..createSync(recursive: true);
    File('$fixtures/path_ice40_met/report.json').copySync(
      p.join(root.path, 'report.json'),
    );
    for (final name in ['named.json', 'other.json']) {
      File('$fixtures/path_ice40_met/netlist.json').copySync(
        p.join(root.path, name),
      );
    }
    final container = ProviderContainer(
      overrides: [
        flowBackgroundRunnerProvider.overrideWithValue(
          <T>(task) async => await task(),
        ),
        activeConfigProvider.overrideWith(
          () => FixedFlowConfig(
            RegressionConfig(
              projectFilePath: p.join(tmp.path, 'simcrux.yaml'),
              schemaVersion: '1',
              suites: const [],
              simulatorBinaries: const {},
              flow: FlowConfig(entries: entries),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final paths = await container.read(
      flowWorstPathsProvider((
        run: FlowRunRef(
          kind: FlowKind.nextpnr,
          root: root.path,
          tag: 't1',
          readerVersion: 'nextpnr-report',
          verified: true,
        ),
        design: design,
      )).future,
    );
    return paths.mapped;
  }

  FlowEntry adder({String? netlist}) =>
      FlowEntry(name: 'adder', kind: FlowKind.nextpnr, netlist: netlist);

  test("the entry's netlist: is the netlist the paths map through", () async {
    expect(
      await mapped(
        entries: [adder(netlist: 'named.json')],
        design: 'adder',
      ),
      isTrue,
    );
  });

  test('without it, two netlists in the run map nothing', () async {
    expect(await mapped(entries: [adder()], design: 'adder'), isFalse);
  });

  test("another entry's netlist: is not this run's", () async {
    expect(
      await mapped(
        entries: [adder(netlist: 'named.json')],
        design: 'other',
      ),
      isFalse,
    );
  });
}
