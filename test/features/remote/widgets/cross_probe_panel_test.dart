// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_events_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_originate_gate_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/widgets/cross_probe_panel.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

class _StaticPeersNotifier extends CxpPeersNotifier {
  _StaticPeersNotifier(this._initial);
  final List<CxpPeerManifest> _initial;

  @override
  List<CxpPeerManifest> build() => _initial;
}

class _StaticDialFailuresNotifier extends CxpDialFailuresNotifier {
  _StaticDialFailuresNotifier(this._initial);
  final List<CxpDialFailure> _initial;

  @override
  List<CxpDialFailure> build() => _initial;
}

class _RunningCxpServerNotifier extends CxpServerNotifier {
  _RunningCxpServerNotifier(this._fake);
  final SimCruxCxpServer _fake;

  @override
  Future<SimCruxCxpServer?> build() async => _fake;
}

class _DisabledCxpServerNotifier extends CxpServerNotifier {
  @override
  Future<SimCruxCxpServer?> build() async => null;
}

/// A [SimCruxCxpServer] that records the send and replies with a configurable
/// [RequestHighlightAck] — so the panel's ack-bearing send resolves without a
/// socket, and a rejection can be surfaced as a toast.
class _FakeSimServer extends SimCruxCxpServer {
  _FakeSimServer({
    this.ackHonored = true,
    this.ackReason,
    this.delivered = true,
    this.ackGate,
  }) : super(selfIdentity: buildSimcruxPeerIdentity(processId: 1), port: 0);

  final bool ackHonored;
  final String? ackReason;

  /// False models a peer that vanished before the send: the server reports
  /// `(delivered: false, ack: null)`.
  final bool delivered;

  /// When set, the reply waits on it — the real server's up-to-5 s ack wait.
  final Future<void>? ackGate;
  final List<(String, CxpMessage)> sent = <(String, CxpMessage)>[];

  @override
  Future<({bool delivered, RequestHighlightAck? ack})> requestHighlight(
    String peerId,
    RequestHighlight request, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    sent.add((peerId, request));
    if (!delivered) return (delivered: false, ack: null);
    await ackGate;
    return (
      delivered: true,
      ack: RequestHighlightAck(
        inReplyTo: 'req',
        honored: ackHonored,
        reason: ackReason,
      ),
    );
  }
}

class _NoopDiscoveryNotifier extends CxpDiscoveryNotifier {
  @override
  Future<Null> build() async => null;
}

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

ProviderContainer makeContainer({
  required bool serverEnabled,
  List<CxpPeerManifest> peers = const <CxpPeerManifest>[],
  List<CxpDialFailure> dialFailures = const <CxpDialFailure>[],
}) {
  final fakeServer = SimCruxCxpServer(
    selfIdentity: buildSimcruxPeerIdentity(processId: 1),
    port: 0,
  );
  return ProviderContainer(
    overrides: <Override>[
      // Override the cxpServerProvider itself so the widget test never
      // tries to bind a real TCP socket — testWidgets uses a fake
      // async runtime that ServerSocket.bind cannot complete inside.
      if (serverEnabled)
        cxpServerProvider.overrideWith(
          () => _RunningCxpServerNotifier(fakeServer),
        )
      else
        cxpServerProvider.overrideWith(_DisabledCxpServerNotifier.new),
      cxpDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
      cxpPeersProvider.overrideWith(() => _StaticPeersNotifier(peers)),
      cxpDialFailuresProvider.overrideWith(
        () => _StaticDialFailuresNotifier(dialFailures),
      ),
    ],
  );
}

CxpPeerManifest _peerManifest({
  required String peerId,
  required String productName,
  String host = '127.0.0.1',
  int port = 54322,
}) => CxpPeerManifest(
  identity: PeerIdentity(
    peerId: peerId,
    productName: productName,
    productVersion: '0.1.0',
  ),
  host: host,
  port: port,
  startedAt: DateTime(2026),
  manifestPath: '/tmp/$peerId.json',
);

CxpDialFailure _dialFailure({
  required String peerId,
  String host = '127.0.0.1',
  int port = 54322,
}) => CxpDialFailure(
  peerId: peerId,
  host: host,
  port: port,
  error: const SocketExceptionStub(),
  consecutiveFailures: 3,
  nextRetryAfterTicks: 2,
);

/// Minimal stand-in for the `SocketException` the real connector reports;
/// [CxpDialFailure.error] is typed as `Object`.
class SocketExceptionStub {
  const SocketExceptionStub();
  @override
  String toString() => 'Connection refused';
}

Future<void> hydrate(ProviderContainer container) async {
  await container.read(appSettingsProvider.future);
  await container.read(cxpServerProvider.future);
}

/// A container in which, absent a tier gate, a send WOULD go through: the
/// server is running, one foreign peer is discovered, and a test is selected.
ProviderContainer _gatedContainer({
  required bool beta,
  required LicenseTier tier,
  required _FakeSimServer fake,
  List<Override> extra = const <Override>[],
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      betaPeriodProvider.overrideWithValue(beta),
      licenseTierProvider.overrideWithValue(tier),
      cxpServerProvider.overrideWith(() => _RunningCxpServerNotifier(fake)),
      cxpDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
      cxpPeersProvider.overrideWith(
        () => _StaticPeersNotifier([
          _peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux'),
        ]),
      ),
      cxpDialFailuresProvider.overrideWith(
        () => _StaticDialFailuresNotifier(const <CxpDialFailure>[]),
      ),
      ...extra,
    ],
  );
  container.read(selectedTestIdProvider.notifier).select('cpu_unit/test_alu');
  return container;
}

void _localizedToastTests() {
  // The shared panel falls back to English for this toast. Without the app's
  // strings it stayed English in every locale.
  Future<void> sendAndSettle(
    WidgetTester tester, {
    required Locale locale,
    required _FakeSimServer fake,
  }) async {
    final container = ProviderContainer(
      overrides: <Override>[
        // Sending is a Pro capability, and these are about what the user is
        // told when a send that was allowed fails, so the seat is Pro.
        licenseTierProvider.overrideWithValue(LicenseTier.pro),
        cxpServerProvider.overrideWith(() => _RunningCxpServerNotifier(fake)),
        cxpDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
        cxpPeersProvider.overrideWith(
          () => _StaticPeersNotifier([
            _peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux'),
          ]),
        ),
        cxpDialFailuresProvider.overrideWith(
          () => _StaticDialFailuresNotifier(const <CxpDialFailure>[]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await hydrate(container);
    container.read(selectedTestIdProvider.notifier).select('cpu_unit/test_alu');
    await tester.pumpWidget(
      _wrap(
        const SimCruxCrossProbePanel(),
        container: container,
        locale: locale,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
    await tester.pumpAndSettle();
  }

  for (final locale in L10N.supportedLocales) {
    testWidgets('a send that went nowhere, in $locale', (tester) async {
      await sendAndSettle(
        tester,
        locale: locale,
        fake: _FakeSimServer(delivered: false),
      );
      expect(
        find.text(lookupL10N(locale).crossProbeSendFailed('wavecrux')),
        findsOneWidget,
      );
    });

    testWidgets('a send answered with a reason, in $locale', (tester) async {
      const reason = 'test not found in current design';
      await sendAndSettle(
        tester,
        locale: locale,
        fake: _FakeSimServer(ackHonored: false, ackReason: reason),
      );
      expect(
        find.text(lookupL10N(locale).crossProbeSendRefused('wavecrux', reason)),
        findsOneWidget,
        reason: 'the frame is translated; the reason is the peer words',
      );
    });
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('the send-failure toast is in the user language', _localizedToastTests);

  group('the per-peer send button is a route to a Pro capability', () {
    // Origination is sold as Pro. The Pro overlay gates its own route (the
    // dashboard row's cross-probe menu); this panel ships in open core and
    // its send button reaches the same capability, so it has to gate too.
    Future<void> pumpAndSend(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      addTearDown(container.dispose);
      await hydrate(container);
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pumpAndSettle();
    }

    testWidgets('post-beta at Open Core: nothing is sent, and the user is '
        'told why', (tester) async {
      final fake = _FakeSimServer();
      await pumpAndSend(
        tester,
        _gatedContainer(beta: false, tier: LicenseTier.openCore, fake: fake),
      );
      expect(
        fake.sent,
        isEmpty,
        reason:
            'the panel is open core and the send button reaches a Pro '
            'capability; without a gate here the overlay menu gate is a '
            'paywall with a second door',
      );
      expect(
        find.textContaining('requires SimCrux Pro'),
        findsOneWidget,
        reason: 'a denied press is never silent',
      );
    });

    testWidgets('post-beta at Pro: the send goes through', (tester) async {
      final fake = _FakeSimServer();
      await pumpAndSend(
        tester,
        _gatedContainer(beta: false, tier: LicenseTier.pro, fake: fake),
      );
      expect(fake.sent, hasLength(1));
      expect(find.textContaining('requires SimCrux Pro'), findsNothing);
    });

    testWidgets('EDU is feature-equivalent to Pro', (tester) async {
      final fake = _FakeSimServer();
      await pumpAndSend(
        tester,
        _gatedContainer(beta: false, tier: LicenseTier.edu, fake: fake),
      );
      expect(fake.sent, hasLength(1));
    });

    testWidgets('during the beta every tier sends', (tester) async {
      final fake = _FakeSimServer();
      await pumpAndSend(
        tester,
        _gatedContainer(beta: true, tier: LicenseTier.openCore, fake: fake),
      );
      expect(fake.sent, hasLength(1));
      expect(find.textContaining('requires SimCrux Pro'), findsNothing);
    });

    testWidgets('the panel asks the gate seam, so the Pro overlay can bind '
        'its own dialog', (tester) async {
      // The overlay overrides `crossProbeOriginateGateProvider` with its
      // upgrade dialog. That only guards anything if the panel consults the
      // seam rather than the tier directly.
      final fake = _FakeSimServer();
      var asked = 0;
      await pumpAndSend(
        tester,
        // A tier the default gate would ADMIT, so a send that still gets
        // through can only mean the seam was bypassed.
        _gatedContainer(
          beta: true,
          tier: LicenseTier.pro,
          fake: fake,
          extra: [
            crossProbeOriginateGateProvider.overrideWith(
              (ref) => (_) {
                asked++;
                return false;
              },
            ),
          ],
        ),
      );
      expect(asked, 1);
      expect(fake.sent, isEmpty);
    });

    for (final locale in L10N.supportedLocales) {
      testWidgets('denial snack renders without exception in $locale', (
        tester,
      ) async {
        final fake = _FakeSimServer();
        final container = _gatedContainer(
          beta: false,
          tier: LicenseTier.openCore,
          fake: fake,
        );
        addTearDown(container.dispose);
        await hydrate(container);
        await tester.pumpWidget(
          _wrap(
            const SimCruxCrossProbePanel(),
            container: container,
            locale: locale,
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(fake.sent, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('SimCruxCrossProbePanel — empty states', () {
    testWidgets(
      'shows no-peers + no-events copy when CXP is running and nothing has happened',
      (tester) async {
        final container = makeContainer(serverEnabled: true);
        addTearDown(container.dispose);
        await hydrate(container);

        await tester.pumpWidget(
          _wrap(const SimCruxCrossProbePanel(), container: container),
        );
        await tester.pump();

        expect(find.textContaining('No peers connected yet'), findsOneWidget);
        expect(find.text('No cross-probe activity yet.'), findsOneWidget);
        // Running server → no offline banner.
        expect(
          find.byKey(const Key('cross_probe_offline_banner')),
          findsNothing,
        );
      },
    );

    testWidgets('shows the offline banner when CXP is off', (tester) async {
      final container = makeContainer(serverEnabled: false);
      addTearDown(container.dispose);
      await hydrate(container);

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('cross_probe_offline_banner')),
        findsOneWidget,
      );
      expect(find.text('Cross-probe server is offline.'), findsOneWidget);
    });
  });

  group('SimCruxCrossProbePanel — peers', () {
    testWidgets('lists a foreign peer with a direct-send button', (
      tester,
    ) async {
      final container = makeContainer(
        serverEnabled: true,
        peers: [_peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux')],
      );
      addTearDown(container.dispose);
      await hydrate(container);

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

    testWidgets('never lists SimCrux itself as a peer', (tester) async {
      final container = makeContainer(
        serverEnabled: true,
        peers: [
          _peerManifest(peerId: 'self-1', productName: simcruxCxpProductName),
        ],
      );
      addTearDown(container.dispose);
      await hydrate(container);

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('cross_probe_send_self-1')),
        findsNothing,
      );
      expect(find.textContaining('No peers connected yet'), findsOneWidget);
    });

    testWidgets('a rejected send (honored:false ack) raises a panel toast', (
      tester,
    ) async {
      final fake = _FakeSimServer(
        ackHonored: false,
        ackReason: 'test not found in current design',
      );
      final container = ProviderContainer(
        overrides: <Override>[
          // Sending is Pro; this is about the ack of a send that was allowed.
          licenseTierProvider.overrideWithValue(LicenseTier.pro),
          cxpServerProvider.overrideWith(() => _RunningCxpServerNotifier(fake)),
          cxpDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
          cxpPeersProvider.overrideWith(
            () => _StaticPeersNotifier([
              _peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux'),
            ]),
          ),
          cxpDialFailuresProvider.overrideWith(
            () => _StaticDialFailuresNotifier(const <CxpDialFailure>[]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await hydrate(container);
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
        find.byKey(const Key('cross_probe_send_failure')),
        findsOneWidget,
      );
      expect(
        find.textContaining('test not found in current design'),
        findsOneWidget,
      );
      expect(fake.sent, hasLength(1));
      expect(fake.sent.single.$2, isA<RequestHighlight>());
    });

    testWidgets('an HONOURED ack that carries a reason still raises the '
        'toast — a partly-honoured send is not a silent success', (
      tester,
    ) async {
      // CXP §9.4: a receiver that honours the element but cannot resolve the
      // coordinate replies honored:true WITH a reason. Keying the toast on
      // honored:false alone threw those away, which is how the RISC-V
      // counterexample hand-off managed to explain itself to nobody.
      final fake = _FakeSimServer(
        ackReason:
            'the loaded trace exposes no RVFI bundle, so a RISC-V stream '
            'coordinate cannot be resolved in it',
      );
      final container = ProviderContainer(
        overrides: <Override>[
          // Sending is Pro; this is about the ack of a send that was allowed.
          licenseTierProvider.overrideWithValue(LicenseTier.pro),
          cxpServerProvider.overrideWith(() => _RunningCxpServerNotifier(fake)),
          cxpDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
          cxpPeersProvider.overrideWith(
            () => _StaticPeersNotifier([
              _peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux'),
            ]),
          ),
          cxpDialFailuresProvider.overrideWith(
            () => _StaticDialFailuresNotifier(const <CxpDialFailure>[]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await hydrate(container);
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
        find.byKey(const Key('cross_probe_send_failure')),
        findsOneWidget,
      );
      expect(find.textContaining('no RVFI bundle'), findsOneWidget);
    });

    testWidgets('an honoured ack with no reason raises nothing', (
      tester,
    ) async {
      final fake = _FakeSimServer();
      final container = ProviderContainer(
        overrides: <Override>[
          // Sending is Pro; this is about the ack of a send that was allowed.
          licenseTierProvider.overrideWithValue(LicenseTier.pro),
          cxpServerProvider.overrideWith(() => _RunningCxpServerNotifier(fake)),
          cxpDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
          cxpPeersProvider.overrideWith(
            () => _StaticPeersNotifier([
              _peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux'),
            ]),
          ),
          cxpDialFailuresProvider.overrideWith(
            () => _StaticDialFailuresNotifier(const <CxpDialFailure>[]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await hydrate(container);
      container
          .read(selectedTestIdProvider.notifier)
          .select('cpu_unit/test_alu');

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pumpAndSettle();

      // Without this a denied send (no toast either) would pass vacuously.
      expect(fake.sent, hasLength(1));
      expect(find.byKey(const Key('cross_probe_send_failure')), findsNothing);
    });
  });

  group('SimCruxCrossProbePanel — a send that goes nowhere', () {
    Future<ProviderContainer> pumpPanel(
      WidgetTester tester,
      _FakeSimServer fake,
    ) async {
      final container = _gatedContainer(
        beta: true,
        tier: LicenseTier.pro,
        fake: fake,
      );
      addTearDown(container.dispose);
      await hydrate(container);
      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();
      return container;
    }

    testWidgets('an undelivered send (the peer vanished) raises the toast', (
      tester,
    ) async {
      final fake = _FakeSimServer(delivered: false);
      final container = await pumpPanel(tester, fake);

      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pumpAndSettle();

      expect(fake.sent, hasLength(1));
      expect(
        find.byKey(const Key('cross_probe_send_failure')),
        findsOneWidget,
        reason:
            'the user pressed Send; a peer that is no longer there must be '
            'reported, not swallowed',
      );
      expect(
        container.read(crossProbeEventsProvider),
        isEmpty,
        reason: 'nothing left this process, so nothing is logged as sent',
      );
    });

    testWidgets('a second undelivered send to the same peer toasts again', (
      tester,
    ) async {
      final fake = _FakeSimServer(delivered: false);
      await pumpPanel(tester, fake);

      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cross_probe_send_failure')), findsOneWidget);
      // Let the first toast run out.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cross_probe_send_failure')), findsNothing);

      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pumpAndSettle();
      expect(fake.sent, hasLength(2));
      expect(
        find.byKey(const Key('cross_probe_send_failure')),
        findsOneWidget,
        reason:
            'an identical failure does not notify a ValueNotifier, so a '
            'repeat would be silent unless the controller clears it first',
      );
    });

    testWidgets('closing the panel during the ack wait throws nothing', (
      tester,
    ) async {
      final ack = Completer<void>();
      final fake = _FakeSimServer(ackHonored: false, ackGate: ack.future);
      final container = await pumpPanel(tester, fake);

      await tester.tap(find.byKey(const Key('cross_probe_send_wavecrux-1')));
      await tester.pump();
      expect(fake.sent, hasLength(1));

      // The panel closes while the peer has not yet answered.
      await tester.pumpWidget(
        _wrap(const SizedBox.shrink(), container: container),
      );
      ack.complete();
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'the host widget is gone, and so is the ref the send used',
      );
      expect(
        container.read(crossProbeEventsProvider),
        isEmpty,
        reason: 'a send whose panel closed records nothing afterwards',
      );
    });
  });

  group('SimCruxCrossProbePanel — events', () {
    testWidgets('renders an outbound selection event after one is recorded', (
      tester,
    ) async {
      final container = makeContainer(serverEnabled: true);
      addTearDown(container.dispose);
      await hydrate(container);

      container
          .read(crossProbeEventsProvider.notifier)
          .record(
            CrossProbeEvent(
              timestamp: DateTime(2026, 5, 24, 14, 30, 5),
              direction: CrossProbeDirection.outbound,
              kind: CxpMessageKind.notifySelection,
              peerId: 'wavecrux-fake-1',
              summary: 'cpu_unit/test_alu',
            ),
          );

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      // The shared panel folds (kind, direction) into a semantic label.
      expect(find.text('Selection sent'), findsOneWidget);
      expect(find.textContaining('14:30:05'), findsOneWidget);
      expect(find.textContaining('cpu_unit/test_alu'), findsOneWidget);
    });

    testWidgets('Clear button empties the events buffer', (tester) async {
      final container = makeContainer(serverEnabled: true);
      addTearDown(container.dispose);
      await hydrate(container);
      container
          .read(crossProbeEventsProvider.notifier)
          .record(
            CrossProbeEvent(
              timestamp: DateTime(2026),
              direction: CrossProbeDirection.outbound,
              kind: CxpMessageKind.notifySelection,
              peerId: 'p',
              summary: 'x',
            ),
          );

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();
      expect(find.text('Selection sent'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cross_probe_clear_events')));
      await tester.pump();
      expect(container.read(crossProbeEventsProvider), isEmpty);
    });
  });

  group('SimCruxCrossProbePanel — unreachable peers', () {
    testWidgets(
      'shows no unreachable section when there are no dial failures',
      (tester) async {
        final container = makeContainer(serverEnabled: true);
        addTearDown(container.dispose);
        await hydrate(container);

        await tester.pumpWidget(
          _wrap(const SimCruxCrossProbePanel(), container: container),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('cross_probe_unreachable')),
          findsNothing,
        );
      },
    );

    testWidgets('renders the unreachable section when a dial fails', (
      tester,
    ) async {
      final container = makeContainer(
        serverEnabled: true,
        peers: [_peerManifest(peerId: 'wavecrux-1', productName: 'wavecrux')],
        dialFailures: [_dialFailure(peerId: 'wavecrux-1')],
      );
      addTearDown(container.dispose);
      await hydrate(container);

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('cross_probe_unreachable')),
        findsOneWidget,
      );
      expect(find.textContaining('wavecrux-1'), findsWidgets);
    });
  });

  group('SimCruxCrossProbePanel — dock chrome dedup', () {
    testWidgets('renders NO header of its own — the dock tab owns icon, '
        'label and close', (tester) async {
      // showHeader: false under the dock; the panel's old header duplicated
      // all three directly beneath the strip.
      final container = makeContainer(serverEnabled: true);
      addTearDown(container.dispose);
      await hydrate(container);

      await tester.pumpWidget(
        _wrap(const SimCruxCrossProbePanel(), container: container),
      );
      await tester.pump();

      expect(find.byKey(const Key('cross_probe_close')), findsNothing);
      expect(find.text('Cross-probe'), findsNothing);
    });
  });

  group('SimCruxCrossProbePanel — locale sweep', () {
    for (final locale in const <Locale>[
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets(
        'renders without exception in ${locale.toLanguageTag()}',
        (tester) async {
          final container = makeContainer(serverEnabled: true);
          addTearDown(container.dispose);
          await hydrate(container);

          await tester.pumpWidget(
            _wrap(
              const SimCruxCrossProbePanel(),
              container: container,
              locale: locale,
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
