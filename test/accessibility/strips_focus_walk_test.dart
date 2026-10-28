// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_a11y/crux_a11y.dart';
import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:crux_license/crux_license.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simcrux/core/update/simcrux_update_strings.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_gate.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The strips `app.dart` draws in `MaterialApp.builder`, above the router's
/// `Navigator`, walked from the keyboard: Tab must run from the page through
/// every strip and back, each stop named, without a strip taking focus on its
/// own. The builder here stacks the same gates in the same order around
/// [CruxRoutedContent], as `app.dart` does.

final _config = CruxUpdateConfig(
  productName: 'SimCrux',
  manifestUri: 'https://updates.example.test/manifest.json',
  downloadPageUri: 'https://example.test/download',
);

class _AvailableUpdate extends UpdateStatusNotifier {
  @override
  UpdateStatus build() => const UpdateStatusAvailable(
    UpdateInfo(
      version: '9.9.0',
      changelogUrl: 'https://example.test/releases/9.9.0',
    ),
  );

  @override
  Future<void> runScheduledCheck() async {}
}

Widget _app() {
  final router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {},
              child: const Text('Open File'),
            ),
          ),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      betaExpiryStatusProvider.overrideWithValue(
        BetaExpiryStatus.expiringSoon,
      ),
      betaExpiryDaysRemainingProvider.overrideWithValue(4),
      cruxUpdateConfigProvider.overrideWithValue(_config),
      updateStatusProvider.overrideWith(_AvailableUpdate.new),
      updateUrlLauncherProvider.overrideWithValue((_) async => true),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: L10N.localizationsDelegates,
      supportedLocales: L10N.supportedLocales,
      builder: (context, child) => BetaExpiryGate(
        child: ProviderScope(
          overrides: [
            cruxUpdateStringsProvider.overrideWithValue(
              SimcruxUpdateStrings(L10N.of(context)),
            ),
          ],
          child: UpdateBanner(
            isWeb: false,
            child: CruxRoutedContent(child: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Tab runs from the page through both strips and back', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final l10n = await L10N.delegate.load(const Locale('en'));

    final walk = await walkFocus(tester);
    expectCleanFocusWalk(walk);
    final names = walk.stops.map((stop) => stop.name).toList();
    // One stop on the page, two on the beta strip, three on the update
    // strip (both strips have a Dismiss).
    expect(names, hasLength(6), reason: walk.transcript);
    expect(
      names,
      containsAll(<String>[
        'Open File',
        l10n.betaExpiryBannerAction,
        l10n.betaExpiryDismissLabel,
        l10n.updateNowAction,
        l10n.updateViewChangesAction,
        l10n.updateDismissLabel,
      ]),
      reason: walk.transcript,
    );

    final back = await walkFocus(tester, reverse: true);
    expectCleanFocusWalk(back);
    expect(back.stops, hasLength(6), reason: back.transcript);
    handle.dispose();
  });

  test('app.dart mounts the routed content in CruxRoutedContent', () {
    // Without it every stop on a strip above the Navigator is silent: a
    // route's modal barrier blocks the semantics painted before it in the
    // window's container. The walk above holds only while app.dart keeps
    // the wrapper around the builder's child.
    final source = File('lib/app.dart').readAsStringSync();
    expect(
      RegExp(r'CruxRoutedContent\(\s*child:\s*child,?\s*\)').hasMatch(source),
      isTrue,
    );
  });
}
