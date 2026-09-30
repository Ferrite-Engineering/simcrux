// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_updates/crux_updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/update/simcrux_update_config.dart';
import 'package:simcrux/core/update/simcrux_update_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux-side coverage of the shared `UpdateBanner`: the SimCrux string
/// adapter renders through it, the mandatory path offers no dismissal, and the
/// dismissible path suppresses only the dismissed version.
///
/// The banner widget itself is `crux_updates`' — this exercises *SimCrux's*
/// binding of it (strings, config, launcher), not the package's internals.
const _locales = [
  Locale('en'),
  Locale('zh', 'CN'),
  Locale('ja'),
  Locale('ko'),
];

class _StubUpdateStatus extends UpdateStatusNotifier {
  _StubUpdateStatus(this._status);
  final UpdateStatus _status;

  @override
  UpdateStatus build() => _status;

  @override
  Future<void> runScheduledCheck() async {}

  @override
  Future<void> checkNow() async {}
}

Widget _app({
  required UpdateStatus status,
  Locale locale = const Locale('en'),
  List<Uri>? launched,
}) {
  return ProviderScope(
    overrides: [
      cruxUpdateConfigProvider.overrideWithValue(simcruxUpdateConfig),
      updateStatusProvider.overrideWith(() => _StubUpdateStatus(status)),
      updateUrlLauncherProvider.overrideWithValue((uri) async {
        launched?.add(uri);
        return true;
      }),
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
      builder: (context, child) => ProviderScope(
        overrides: [
          cruxUpdateStringsProvider.overrideWithValue(
            SimcruxUpdateStrings(L10N.of(context)),
          ),
        ],
        child: UpdateBanner(child: child ?? const SizedBox.shrink()),
      ),
      home: const Scaffold(body: Text('content')),
    ),
  );
}

void main() {
  group('UpdateBanner — SimCrux binding', () {
    testWidgets('renders nothing when the build is current', (tester) async {
      await tester.pumpWidget(_app(status: const UpdateStatusCurrent()));
      await tester.pump();
      expect(find.text('content'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('renders nothing while a check is in flight', (tester) async {
      await tester.pumpWidget(_app(status: const UpdateStatusChecking()));
      await tester.pump();
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('never nags after a failed check', (tester) async {
      await tester.pumpWidget(_app(status: const UpdateStatusError()));
      await tester.pump();
      expect(find.byIcon(Icons.close), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('announces an available version using SimCrux strings', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          status: const UpdateStatusAvailable(UpdateInfo(version: '2.1.0')),
        ),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(find.text(l10n.updateBannerMessage('2.1.0')), findsOneWidget);
      expect(find.text(l10n.updateNowAction), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MANDATORY updates render no dismiss affordance', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          status: const UpdateStatusAvailable(
            UpdateInfo(version: '2.1.0', mandatory: true),
          ),
        ),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(find.text(l10n.updateBannerMessage('2.1.0')), findsOneWidget);
      expect(
        find.byIcon(Icons.close),
        findsNothing,
        reason: 'a mandatory update must not be dismissible',
      );
    });

    testWidgets('a non-mandatory update is dismissible for the session', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          status: const UpdateStatusAvailable(UpdateInfo(version: '2.1.0')),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      expect(find.text(l10n.updateBannerMessage('2.1.0')), findsNothing);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('Update Now opens the SimCrux download page', (tester) async {
      final launched = <Uri>[];
      await tester.pumpWidget(
        _app(
          status: const UpdateStatusAvailable(UpdateInfo(version: '2.1.0')),
          launched: launched,
        ),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      await tester.tap(find.text(l10n.updateNowAction));
      await tester.pump();

      expect(launched, [simcruxUpdateConfig.downloadPageUri]);
    });

    testWidgets('the banner actions clear the 44 dp touch-target floor', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          status: const UpdateStatusAvailable(UpdateInfo(version: '2.1.0')),
        ),
      );
      await tester.pump();

      final l10n = L10N.of(tester.element(find.text('content')));
      final updateNow = tester.getSize(
        find.ancestor(
          of: find.text(l10n.updateNowAction),
          matching: find.byType(TextButton),
        ),
      );
      expect(updateNow.height, greaterThanOrEqualTo(44.0));
      expect(updateNow.width, greaterThanOrEqualTo(44.0));

      final dismiss = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.close),
          matching: find.byType(IconButton),
        ),
      );
      expect(dismiss.height, greaterThanOrEqualTo(44.0));
      expect(dismiss.width, greaterThanOrEqualTo(44.0));
    });

    for (final locale in _locales) {
      testWidgets('renders without overflow in $locale', (tester) async {
        await tester.pumpWidget(
          _app(
            status: const UpdateStatusAvailable(UpdateInfo(version: '2.1.0')),
            locale: locale,
          ),
        );
        await tester.pump();

        final l10n = await L10N.delegate.load(locale);
        expect(find.text(l10n.updateBannerMessage('2.1.0')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
