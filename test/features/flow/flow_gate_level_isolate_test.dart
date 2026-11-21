// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/flow/flow_actions.dart';
import 'package:simcrux/features/flow/gls_labels.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';

/// Run Gate-Level Simulation through the app's own background runner, a
/// real `Isolate.run`, which every other test replaces with an inline one.
///
/// Its run read once shared a context with the request's scheduler closure,
/// which holds the tab's RegressionRunner: the isolate refused the message
/// as unsendable and the click did nothing (simcrux#57). Here the run
/// directory is empty, so the read answers "run unreadable", and that answer
/// must reach the user.
void main() {
  testWidgets('the run is read on a real isolate, and its answer is shown', (
    tester,
  ) async {
    await _expectRunReached(
      tester,
      entry: 'counter',
      folder: 'counter',
      design: 'counter',
    );
  });

  testWidgets('a LibreLane run finds its entry when the entry is not named '
      'after the folder holding runs/ (simcrux#69)', (tester) async {
    // The run sits in librelane/runs/, so the panel once named its design
    // `librelane`; the entry is counter_sky130. The run is matched to the
    // entry whose run directory holds it, so its gls: tests are found and
    // the run is read (unreadable here), not refused for having no tests.
    await _expectRunReached(
      tester,
      entry: 'counter_sky130',
      folder: 'librelane',
      design: 'librelane',
    );
  });
}

/// Selects run RUN_1 of a project whose LibreLane [entry] keeps its config
/// in [folder], with the selection naming [design], clicks Run Gate-Level
/// Simulation, and expects the empty run's "run unreadable" answer.
Future<void> _expectRunReached(
  WidgetTester tester, {
  required String entry,
  required String folder,
  required String design,
}) async {
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('gls_isolate'),
  ))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final run = Directory(p.join(dir.path, folder, 'runs', 'RUN_1'))
    ..createSync(recursive: true);
  File(p.join(dir.path, folder, 'counter.v')).writeAsStringSync(
    'module counter(input clk, output reg q); '
    'always @(posedge clk) q <= ~q; endmodule\n',
  );
  File(p.join(dir.path, 'tb.v')).writeAsStringSync(
    'module tb; reg clk = 0; counter dut(.clk(clk), .q()); endmodule\n',
  );
  File(p.join(dir.path, folder, 'config.yaml')).writeAsStringSync(
    'DESIGN_NAME: counter\n',
  );
  final yaml = File(p.join(dir.path, 'simcrux.yaml'))
    ..writeAsStringSync('''
version: '1'
defaults:
  simulator: icarus
suites:
  rtl:
    tests:
      - name: smoke
        top: tb
        sources: [$folder/counter.v, tb.v]
flow:
  entries:
    - name: $entry
      kind: librelane
      config: $folder/config.yaml
      gls:
        tests: [smoke]
''');

  final root = ProviderContainer();
  addTearDown(root.dispose);
  final tab = ProviderContainer(parent: root);
  addTearDown(tab.dispose);
  final config = await tester.runAsync(() => ConfigLoader().load(yaml.path));
  tab.read(activeConfigProvider.notifier).replace(config);
  // The tab's runner exists, as it does in the app.
  tab.read(regressionRunnerProvider.notifier);
  tab
      .read(flowSelectedRunProvider.notifier)
      .select(
        FlowRunSelection(
          root: run.path,
          kind: FlowKind.librelane,
          design: design,
        ),
      );

  late BuildContext context;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: root,
      child: MaterialApp(
        localizationsDelegates: L10N.localizationsDelegates,
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  final words = L10N.of(context);

  await tester.runAsync(
    () => FlowActions.runGateLevel(context, tab, root.read),
  );
  await tester.pump();

  expect(find.text(words.flowGlsNoTests), findsNothing);
  expect(
    find.text(
      words.flowGlsCannotRun(
        GlsLabels.reason(words, GlsNotRunReason.runUnreadable),
      ),
    ),
    findsOneWidget,
  );
}
