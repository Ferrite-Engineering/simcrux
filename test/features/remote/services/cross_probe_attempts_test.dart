// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/remote/services/cross_probe_attempts.dart';

import '../../../support/cxp_fake_dispatcher.dart';
import '../../../support/cxp_test_overrides.dart';

CrossProbeSelection _signal(String path) => CrossProbeSelection(
  candidates: <ElementId>[ElementId(kind: ElementKind.signal, path: path)],
);

class _DenyGate implements CrossProbeGate {
  int asked = 0;

  @override
  Future<bool> admit(BuildContext context, PeerIdentity peer) async {
    asked++;
    return false;
  }
}

/// Mounts a button that sends [attempts] and keeps the outcome in [outcome].
Future<void> _pumpSender(
  WidgetTester tester, {
  required FakeCrossProbeDispatcher fake,
  required List<CrossProbeSelection> attempts,
  required List<CrossProbeOutcome> outcome,
  String? allDeclinedReason,
  List<Override> extra = const <Override>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ...simcruxCxpTestOverrides(running: true),
        cxpFakeDispatcherOverride(fake),
        ...extra,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async => outcome.add(
                await sendCrossProbeAttempts(
                  context,
                  ref,
                  peer: cxpTestPeer('netcrux'),
                  attempts: attempts,
                  label: 'NetCrux',
                  allDeclinedReason: allDeclinedReason,
                ),
              ),
              child: const Text('send'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('send'));
  await tester.pumpAndSettle();
}

const _declined = CrossProbeOutcome(
  CrossProbeOutcomeKind.refused,
  reason: 'not in the design',
);

List<String> _paths(FakeCrossProbeDispatcher fake) => <String>[
  for (final (_, selection) in fake.sent) selection!.candidates.single.path,
];

void main() {
  group('sendCrossProbeAttempts', () {
    testWidgets('moves past a declined attempt and stops at the first shown', (
      tester,
    ) async {
      final fake = FakeCrossProbeDispatcher(
        answer: (selection) => selection!.candidates.single.path == 'b'
            ? const CrossProbeOutcome(CrossProbeOutcomeKind.sent)
            : _declined,
      );
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: <CrossProbeSelection>[
          _signal('a'),
          _signal('b'),
          _signal('c'),
        ],
        outcome: outcome,
        allDeclinedReason: 'none of them',
      );
      expect(_paths(fake), <String>['a', 'b']);
      expect(outcome.single.kind, CrossProbeOutcomeKind.sent);
      expect(find.byKey(const ValueKey('crossProbeOutcome')), findsNothing);
    });

    testWidgets('every attempt declined: the reason given replaces the last '
        "one's, and is the toast", (tester) async {
      final fake = FakeCrossProbeDispatcher(
        kind: CrossProbeOutcomeKind.refused,
        reason: 'not in the design',
      );
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: <CrossProbeSelection>[_signal('a'), _signal('b')],
        outcome: outcome,
        allDeclinedReason: 'none of them is open',
      );
      expect(_paths(fake), <String>['a', 'b']);
      expect(outcome.single.kind, CrossProbeOutcomeKind.refused);
      expect(outcome.single.reason, 'none of them is open');
      expect(
        find.text('Cross-probe to NetCrux: none of them is open'),
        findsOneWidget,
      );
    });

    testWidgets("without a reason of its own the peer's stands", (
      tester,
    ) async {
      final fake = FakeCrossProbeDispatcher(
        kind: CrossProbeOutcomeKind.refused,
        reason: 'not in the design',
      );
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: <CrossProbeSelection>[_signal('a'), _signal('b')],
        outcome: outcome,
      );
      expect(outcome.single.reason, 'not in the design');
    });

    testWidgets('an attempt that gets no answer ends the send: the peer is '
        'not asked again', (tester) async {
      final fake = FakeCrossProbeDispatcher(
        kind: CrossProbeOutcomeKind.noResponse,
      );
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: <CrossProbeSelection>[_signal('a'), _signal('b')],
        outcome: outcome,
        allDeclinedReason: 'none of them is open',
      );
      expect(_paths(fake), <String>['a']);
      expect(outcome.single.kind, CrossProbeOutcomeKind.noResponse);
    });

    testWidgets('one attempt is the plain send', (tester) async {
      final fake = FakeCrossProbeDispatcher();
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: <CrossProbeSelection>[_signal('a')],
        outcome: outcome,
      );
      expect(_paths(fake), <String>['a']);
      expect(outcome.single.kind, CrossProbeOutcomeKind.sent);
    });

    testWidgets('no attempts: the shared send is asked about no selection', (
      tester,
    ) async {
      final fake = FakeCrossProbeDispatcher();
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: const <CrossProbeSelection>[],
        outcome: outcome,
      );
      expect(fake.sent.single.$2, isNull);
    });

    testWidgets('a gate that refuses stops the whole sequence once', (
      tester,
    ) async {
      final gate = _DenyGate();
      final fake = FakeCrossProbeDispatcher();
      final outcome = <CrossProbeOutcome>[];
      await _pumpSender(
        tester,
        fake: fake,
        attempts: <CrossProbeSelection>[_signal('a'), _signal('b')],
        outcome: outcome,
        extra: <Override>[crossProbeGateProvider.overrideWithValue(gate)],
      );
      expect(gate.asked, 1);
      expect(fake.sent, isEmpty);
      expect(outcome.single.kind, CrossProbeOutcomeKind.denied);
    });
  });
}
