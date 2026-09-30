// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_blocking_overlay.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_gate.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';

const _locales = [
  Locale('en'),
  Locale('zh', 'CN'),
  Locale('ja'),
  Locale('ko'),
];

Widget _app({
  required BetaExpiryStatus status,
  int? daysRemaining,
  Locale locale = const Locale('en'),
  List<int>? exitCodes,
}) {
  return ProviderScope(
    overrides: [
      betaExpiryStatusProvider.overrideWithValue(status),
      if (daysRemaining != null)
        betaExpiryDaysRemainingProvider.overrideWithValue(daysRemaining),
      if (exitCodes != null)
        processExitProvider.overrideWithValue(exitCodes.add),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      builder: (context, child) => BetaExpiryGate(
        child: child ?? const SizedBox.shrink(),
      ),
      home: const Scaffold(body: Text('content')),
    ),
  );
}

void main() {
  final launched = <Uri>[];

  setUp(() {
    launched.clear();
    betaExpiryLaunchUrl = (uri) async {
      launched.add(uri);
      return true;
    };
  });

  group('BetaExpiryGate', () {
    testWidgets('renders the app untouched when expiry is not applicable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.notApplicable),
      );
      await tester.pump();

      expect(find.text('content'), findsOneWidget);
      expect(find.byType(CruxBetaExpiryBanner), findsNothing);
      expect(find.byType(BetaExpiryBlockingOverlay), findsNothing);
    });

    testWidgets('renders the app untouched while still active', (tester) async {
      await tester.pumpWidget(_app(status: BetaExpiryStatus.active));
      await tester.pump();

      expect(find.byType(CruxBetaExpiryBanner), findsNothing);
      expect(find.byType(BetaExpiryBlockingOverlay), findsNothing);
    });

    testWidgets('shows the dismissible warning banner inside the window', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expiringSoon, daysRemaining: 3),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(find.byType(CruxBetaExpiryBanner), findsOneWidget);
      expect(find.text(l10n.betaExpiryBannerMessage(3)), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the shared banner renders SimCrux strings, not the package '
        'English defaults', (tester) async {
      // The banner moved to `crux_license` and takes its strings through a
      // seam whose default is English. This asserts SimCrux actually binds
      // its own ARB — a missing `strings:` argument compiles fine and would
      // silently ship untranslated text to the four non-English locales.
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expiringSoon, daysRemaining: 3),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(find.text(l10n.betaExpiryBannerAction), findsOneWidget);

      // The dismiss button has no visible label and carries its accessible
      // name via Semantics rather than a Tooltip: the strip renders above the
      // Navigator, so a Tooltip would throw for want of an Overlay ancestor.
      // Load-bearing — see the comment in CruxBetaExpiryBanner. The package's
      // own suite asserts the node is announced; what is SimCrux's to prove is
      // that SimCrux's string is the one that reaches it.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == l10n.betaExpiryDismissLabel,
        ),
        findsOneWidget,
      );
    });

    testWidgets('the warning banner is dismissible for the session', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expiringSoon, daysRemaining: 3),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(find.byType(CruxBetaExpiryBanner), findsNothing);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('the banner Download action opens the SimCrux download page', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expiringSoon, daysRemaining: 1),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      await tester.tap(find.text(l10n.betaExpiryBannerAction));
      await tester.pump();

      expect(launched, [Uri.parse(kSimcruxDownloadPageUrl)]);
    });

    testWidgets('shows the blocking modal once expired', (tester) async {
      await tester.pumpWidget(_app(status: BetaExpiryStatus.expired));
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(find.byType(BetaExpiryBlockingOverlay), findsOneWidget);
      expect(find.text(l10n.betaExpiryExpiredTitle), findsOneWidget);
      expect(find.text(l10n.betaExpiryExpiredAction), findsOneWidget);
      expect(find.text(l10n.betaExpiryExpiredQuit), findsOneWidget);
    });

    testWidgets('the expired modal has no dismiss affordance', (tester) async {
      await tester.pumpWidget(_app(status: BetaExpiryStatus.expired));
      await tester.pump();

      expect(
        find.byIcon(Icons.close),
        findsNothing,
        reason: 'the expired modal is not dismissible',
      );
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).first,
      );
      expect(barrier.dismissible, isFalse);
    });

    testWidgets('the expired modal blocks the system back gesture', (
      tester,
    ) async {
      await tester.pumpWidget(_app(status: BetaExpiryStatus.expired));
      await tester.pump();

      // PopScope is generic; match structurally rather than on a type
      // argument the widget never spells out.
      expect(
        find.byWidgetPredicate((w) => w is PopScope && !w.canPop),
        findsWidgets,
      );
    });

    testWidgets('the expired modal Download action opens the download page', (
      tester,
    ) async {
      await tester.pumpWidget(_app(status: BetaExpiryStatus.expired));
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      await tester.tap(find.text(l10n.betaExpiryExpiredAction));
      await tester.pump();

      expect(launched, [Uri.parse(kSimcruxDownloadPageUrl)]);
    });

    testWidgets('the expired modal Quit action terminates via the seam', (
      tester,
    ) async {
      final exitCodes = <int>[];
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expired, exitCodes: exitCodes),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      await tester.tap(find.text(l10n.betaExpiryExpiredQuit));
      await tester.pumpAndSettle();

      expect(
        exitCodes,
        [0],
        reason:
            'quit must route through the AppExitCoordinator + processExit '
            'seam so simulator process trees are reaped, not orphaned',
      );
    });

    testWidgets('every beta-expiry action clears the 44 dp touch target', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expiringSoon, daysRemaining: 2),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      final download = tester.getSize(
        find.ancestor(
          of: find.text(l10n.betaExpiryBannerAction),
          matching: find.byType(TextButton),
        ),
      );
      expect(download.height, greaterThanOrEqualTo(44.0));
      expect(download.width, greaterThanOrEqualTo(44.0));

      final dismiss = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.close),
          matching: find.byType(IconButton),
        ),
      );
      expect(dismiss.height, greaterThanOrEqualTo(44.0));
      expect(dismiss.width, greaterThanOrEqualTo(44.0));
    });

    testWidgets('the expired modal actions clear the 44 dp touch target', (
      tester,
    ) async {
      await tester.pumpWidget(_app(status: BetaExpiryStatus.expired));
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      for (final label in [
        l10n.betaExpiryExpiredAction,
        l10n.betaExpiryExpiredQuit,
      ]) {
        final size = tester.getSize(
          find.ancestor(of: find.text(label), matching: find.byType(SizedBox)),
        );
        expect(
          size.height,
          greaterThanOrEqualTo(44.0),
          reason: '"$label" is below the 44 dp floor',
        );
      }
    });

    for (final locale in _locales) {
      testWidgets('warning banner renders without overflow in $locale', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(
            status: BetaExpiryStatus.expiringSoon,
            daysRemaining: 5,
            locale: locale,
          ),
        );
        await tester.pump();

        final l10n = await L10N.delegate.load(locale);
        expect(find.text(l10n.betaExpiryBannerMessage(5)), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('expired modal renders without overflow in $locale', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(status: BetaExpiryStatus.expired, locale: locale),
        );
        await tester.pump();

        final l10n = await L10N.delegate.load(locale);
        expect(find.text(l10n.betaExpiryExpiredTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the singular day case renders its own plural form', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(status: BetaExpiryStatus.expiringSoon, daysRemaining: 1),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(
        l10n.betaExpiryBannerMessage(1),
        isNot(l10n.betaExpiryBannerMessage(2)),
        reason: 'the ICU =1 case must differ from the other case',
      );
      expect(find.text(l10n.betaExpiryBannerMessage(1)), findsOneWidget);
    });
  });
}
