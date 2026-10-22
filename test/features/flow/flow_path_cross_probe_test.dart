// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_flow/crux_flow.dart' show SrcSpan;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/flow/widgets/flow_dialogs.dart';
import 'package:simcrux/features/flow/widgets/flow_path_actions.dart';
import 'package:simcrux/features/flow/widgets/flow_runs_panel.dart';
import 'package:simcrux/features/remote/simcrux_cxp_binding.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import 'flow_panel_harness.dart';

// The worst-path rows as a cross-probe source and a receive target (free on
// every tier, no badge): moving onto a path makes it what Cross-probe
// Selection sends; Shift+F10 opens the row's menu with "Cross-probe to" and
// "Open statement in editor"; Cmd/Ctrl+Shift+Enter is never taken as
// activation; and a peer's "Show timing paths through this register"
// narrows the table and says so, with the way back.

const PeerIdentity _netcrux = PeerIdentity(
  peerId: 'netcrux-1-1',
  productName: 'netcrux',
  productVersion: '1.2.0',
);

List<Override> _cxp({List<PeerIdentity> peers = const <PeerIdentity>[]}) =>
    <Override>[
      cruxCxpProductBindingProvider.overrideWithValue(kSimcruxCxpBinding),
      cruxCxpTransportAvailableProvider.overrideWithValue(false),
      cruxCxpRuntimeProvider.overrideWith((_) async => null),
      cruxCxpPeersProvider.overrideWithValue(peers),
      cruxCxpServerStatusProvider.overrideWithValue((
        running: peers.isNotEmpty,
        port: peers.isEmpty ? null : 54325,
        problem: null,
      )),
    ];

void main() {
  group('the statement file is resolved inside the project', () {
    late Directory project;
    late Directory outside;
    setUp(() {
      project = Directory.systemTemp.createTempSync('flow_stmt_project_');
      outside = Directory.systemTemp.createTempSync('flow_stmt_outside_');
      File(p.join(project.path, 'rtl', 'div.v'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('module div; endmodule\n');
      File(p.join(outside.path, 'secret.v')).writeAsStringSync('x\n');
      // A symbolic link needs a privilege on Windows; the link case runs on
      // macOS and Linux.
      if (!Platform.isWindows) {
        Link(
          p.join(project.path, 'rtl', 'escape.v'),
        ).createSync(p.join(outside.path, 'secret.v'));
      }
    });
    tearDown(() {
      project.deleteSync(recursive: true);
      outside.deleteSync(recursive: true);
    });
    String root() => project.resolveSymbolicLinksSync();

    test('a relative span, and a span synthesis recorded elsewhere, by its '
        'suffix among the entry sources', () {
      expect(
        resolveFlowStatementFile(
          const SrcSpan(file: 'rtl/div.v', startLine: 3),
          projectRoot: root(),
        ),
        p.join(root(), 'rtl', 'div.v'),
      );
      expect(
        resolveFlowStatementFile(
          const SrcSpan(file: '/build/machine/rtl/div.v', startLine: 3),
          projectRoot: root(),
          designSources: const <String>['rtl/div.v'],
        ),
        p.join(root(), 'rtl', 'div.v'),
      );
    });

    test('never a file outside the project, through a path or a link', () {
      expect(
        resolveFlowStatementFile(
          SrcSpan(file: p.join(outside.path, 'secret.v'), startLine: 1),
          projectRoot: root(),
        ),
        isNull,
      );
      if (!Platform.isWindows) {
        expect(
          resolveFlowStatementFile(
            const SrcSpan(file: 'rtl/escape.v', startLine: 1),
            projectRoot: root(),
          ),
          isNull,
        );
      }
      expect(
        resolveFlowStatementFile(
          const SrcSpan(file: '../x/rtl/missing.v', startLine: 1),
          projectRoot: root(),
        ),
        isNull,
      );
    });
  });

  L10N l10n(WidgetTester tester) =>
      L10N.of(tester.element(find.byType(FlowRunsPanel)));
  Finder table(String id) => find.byKey(ValueKey<String>('$id.semantics'));

  Future<ProviderContainer> openPaths(
    WidgetTester tester, {
    List<PeerIdentity> peers = const <PeerIdentity>[],
    String? register,
  }) async {
    final container = await pumpFlowPanel(tester, extra: _cxp(peers: peers));
    if (register != null) {
      container.read(flowPathRegisterFilterProvider.notifier).set(register);
    }
    await tester.tap(find.text('t2'));
    await tester.pumpAndSettle();
    if (register == null) {
      await tester.tap(find.text(l10n(tester).flowPathsTableLabel));
      await tester.pumpAndSettle();
    }
    return container;
  }

  testWidgets('moving onto a path makes it what Cross-probe Selection sends', (
    tester,
  ) async {
    final container = await openPaths(tester);
    expect(container.read(flowFocusedPathProvider), isNull);
    await tester.tap(find.text('src_a_SB_DFF_Q'));
    await tester.pumpAndSettle();
    final focused = container.read(flowFocusedPathProvider)!;
    expect(focused.row.path.rank, 1);
    expect(focused.timingPathId, 't2/1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(container.read(flowFocusedPathProvider)!.row.path.rank, 2);
  });

  testWidgets('Shift+F10 opens the row menu: Cross-probe to, and Open '
      'statement in editor', (tester) async {
    await openPaths(tester, peers: const <PeerIdentity>[_netcrux]);
    await tester.tap(find.text('src_a_SB_DFF_Q'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crossProbeSubmenu')), findsOneWidget);
    expect(
      find.text(l10n(tester).flowPathOpenStatement),
      findsOneWidget,
      reason: 'offered, though this path has no statement to open',
    );
    // No tier badge on a cross-probe surface.
    expect(find.text('Pro'), findsNothing);
  });

  testWidgets('Cmd/Ctrl+Shift+Enter in the table is not activation', (
    tester,
  ) async {
    await openPaths(tester);
    await tester.tap(find.text('src_a_SB_DFF_Q'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byType(FlowPathDetailDialog), findsNothing);
  });

  testWidgets('a register a peer named narrows the paths and says so, and '
      'Show all paths brings them back', (tester) async {
    final container = await openPaths(tester, register: 'sum_q');
    final words = l10n(tester);
    expect(find.text(words.flowPathsThroughRegister('sum_q')), findsOneWidget);
    expect(
      tester.getSemantics(table('flowPaths')).value,
      contains('src_a_SB_DFF_Q'),
    );
    expect(find.text('in_b'), findsNothing);
    await tester.tap(find.text(words.flowPathsShowAll));
    await tester.pumpAndSettle();
    expect(container.read(flowPathRegisterFilterProvider), isNull);
    expect(find.text('in_b'), findsOneWidget);
  });

  testWidgets('a register no path runs through says that, with the way back', (
    tester,
  ) async {
    await openPaths(tester, register: 'top.u_div.cnt_q');
    final words = l10n(tester);
    expect(
      find.text(words.flowPathsNoneThroughRegister('top.u_div.cnt_q')),
      findsOneWidget,
    );
    expect(find.text(words.flowPathsShowAll), findsOneWidget);
  });
}
