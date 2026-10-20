// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_visibility_provider.dart';
import 'package:simcrux/features/remote/widgets/cross_probe_panel.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../../support/cxp_fake_dispatcher.dart';
import '../../../support/cxp_test_overrides.dart';

Widget _wrap(
  Widget child, {
  required ProviderContainer container,
  Locale? locale,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(body: SizedBox(width: 400, height: 600, child: child)),
    ),
  );
}

ProviderContainer _container({
  bool running = true,
  List<PeerIdentity> peers = const <PeerIdentity>[],
  FakeCrossProbeDispatcher? dispatcher,
  List<Override> extra = const <Override>[],
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      ...simcruxCxpTestOverrides(running: running, peers: peers),
      if (dispatcher != null) cxpFakeDispatcherOverride(dispatcher),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SimCruxCrossProbePanel — empty states', () {
    testWidgets('shows the shared no-peers and no-events copy when CXP is '
        'running and nothing has happened', (tester) async {
      final container = _container();
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(find.textContaining('No peers connected'), findsOneWidget);
      expect(find.textContaining('No events yet'), findsOneWidget);
      // Running server: no offline banner.
      expect(find.byKey(const Key('cross_probe_offline_banner')), findsNothing);
    });

    testWidgets('shows the offline banner when CXP is off', (tester) async {
      final container = _container(running: false);
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('cross_probe_offline_banner')),
        findsOneWidget,
      );
    });
  });

  group('SimCruxCrossProbePanel — peers', () {
    testWidgets('lists a connected peer with a direct-send button', (
      tester,
    ) async {
      final container = _container(peers: [cxpTestPeer('wavecrux')]);
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(find.textContaining('wavecrux'), findsWidgets);
      expect(
        find.byKey(const Key('cross_probe_send_wavecrux-1')),
        findsOneWidget,
      );
    });

    testWidgets('the send button sends the selected test, as a test and as '
        'a scope', (tester) async {
      final fake = FakeCrossProbeDispatcher();
      final container = _container(
        peers: [cxpTestPeer('netcrux')],
        dispatcher: fake,
      );
      container
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/test_alu');
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('cross_probe_send_netcrux-1')));
      await tester.pumpAndSettle();

      expect(fake.sent, hasLength(1));
      final (peer, selection) = fake.sent.single;
      expect(peer.productName, 'netcrux');
      expect(
        selection!.candidates.map((c) => (c.kind, c.path)).toList(),
        <(ElementKind, String)>[
          (ElementKind.test, 'cpu_unit/test_alu'),
          (ElementKind.scope, 'cpu_unit/test_alu'),
        ],
      );
      // The shared element-kind table sends NetCrux the scope.
      expect(
        crossProbeElementFor(selection, peer)!.kind,
        ElementKind.scope,
      );
    });

    testWidgets('with no test selected the send reports it', (tester) async {
      final fake = FakeCrossProbeDispatcher();
      final container = _container(
        peers: [cxpTestPeer('netcrux')],
        dispatcher: fake,
      );
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('cross_probe_send_netcrux-1')));
      await tester.pumpAndSettle();

      expect(fake.sent.single.$2, isNull);
    });

    testWidgets('a refused send raises the shared error toast with the '
        "peer's own words", (tester) async {
      final fake = FakeCrossProbeDispatcher(
        kind: CrossProbeOutcomeKind.refused,
        reason: 'test not found in current design',
      );
      final container = _container(
        peers: [cxpTestPeer('wavecrux')],
        dispatcher: fake,
      );
      container
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/test_alu');
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pumpAndSettle();

      expect(
        find.text('Cross-probe to WaveCrux: test not found in current design'),
        findsOneWidget,
      );
    });
  });

  group('the per-peer send button is free on every tier', () {
    // Cross-probing is free across the board, sending as well as receiving.
    // A licence must never stand between a press and the send, before or
    // after the beta, and nothing about upgrading is ever shown.
    for (final beta in <bool>[false, true]) {
      for (final tier in LicenseTier.values) {
        final when = beta ? 'during the beta' : 'post-beta';
        testWidgets('$when at $tier: the send goes through, no upgrade '
            'prompt', (tester) async {
          final fake = FakeCrossProbeDispatcher();
          final container = _container(
            peers: [cxpTestPeer('wavecrux')],
            dispatcher: fake,
            extra: <Override>[
              betaPeriodProvider.overrideWithValue(beta),
              licenseTierProvider.overrideWithValue(tier),
            ],
          );
          container
              .read(selectedTestIdProvider.notifier)
              .select('cpu_unit/test_alu');
          await tester.pumpWidget(
            _wrap(const SimCruxCrossProbePanel(), container: container),
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const Key('cross_probe_send_wavecrux-1')),
          );
          await tester.pumpAndSettle();

          expect(fake.sent, hasLength(1));
          expect(find.textContaining('SimCrux Pro'), findsNothing);
          expect(find.byType(Dialog), findsNothing);
        });
      }
    }
  });

  group('SimCruxCrossProbePanel — dock chrome dedup', () {
    testWidgets('renders NO header of its own: the dock tab owns icon, '
        'label and close', (tester) async {
      final container = _container();
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(find.byKey(const Key('cross_probe_close')), findsNothing);
    });

    testWidgets('closing sets the panel invisible', (tester) async {
      final container = _container();
      container.read(crossProbeVisibleProvider.notifier).set(visible: true);
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      final panel = tester.widget<CruxCrossProbePanel>(
        find.byType(CruxCrossProbePanel),
      );
      panel.onClose();

      expect(container.read(crossProbeVisibleProvider), isFalse);
    });
  });

  group('SimCruxCrossProbePanel — locale sweep', () {
    for (final locale in const <Locale>[
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders without exception in ${locale.toLanguageTag()}', (
        tester,
      ) async {
        final container = _container(peers: [cxpTestPeer('wavecrux')]);
        await tester.pumpWidget(
          _wrap(
            const SimCruxCrossProbePanel(),
            container: container,
            locale: locale,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
