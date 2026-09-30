// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/features/watcher/widgets/auto_reload_snackbar_host.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Inert stand-in for [AutoReloadNotifier]: skips the file-watcher and
/// settings wiring entirely and lets tests seed pending paths directly.
class _SeedableAutoReloadNotifier extends AutoReloadNotifier {
  @override
  AutoReloadState build() => const AutoReloadState();

  void seedPending(Set<String> paths) {
    state = state.copyWith(pendingPaths: paths);
  }
}

Widget _wrap(
  _SeedableAutoReloadNotifier Function() create, {
  Locale locale = const Locale('en'),
}) {
  // Keyed per locale: ProviderScope keeps its original container (and
  // override closures) when the element is reused, so the sweep must
  // force a fresh scope per iteration.
  return ProviderScope(
    key: ValueKey('auto-reload-scope-$locale'),
    overrides: [autoReloadNotifierProvider.overrideWith(create)],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: const Scaffold(
        body: AutoReloadSnackbarHost(child: SizedBox.expand()),
      ),
    ),
  );
}

/// Drains the snackbar's 8-second display timer plus its exit
/// animation so no timers stay pending at test teardown.
Future<void> _drainSnackbar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 9));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

void main() {
  group('AutoReloadSnackbarHost', () {
    testWidgets('renders its child and no snackbar while nothing pends', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_SeedableAutoReloadNotifier.new));
      await tester.pump();

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the localized snackbar when a change pends', (
      tester,
    ) async {
      late _SeedableAutoReloadNotifier notifier;
      await tester.pumpWidget(
        _wrap(() => notifier = _SeedableAutoReloadNotifier()),
      );
      await tester.pump();

      notifier.seedPending({'/proj/alu.sv'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text(
          '${l10n.watcherAutoReloadPromptTitle} — '
          '${l10n.watcherAutoReloadPromptMessage}',
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.watcherAutoReloadActionRerun), findsOneWidget);

      await _drainSnackbar(tester);
    });

    // Note: on this Flutter SDK a SnackBar with an action defaults to
    // `persist: true`, so the 8-second timeout path never fires; the
    // snackbar only closes via the action (or an explicit hide). The
    // close-clears-pending behavior is therefore exercised through the
    // "Re-run now" action below.
    testWidgets('re-run action closes the snackbar and clears pending paths', (
      tester,
    ) async {
      late _SeedableAutoReloadNotifier notifier;
      await tester.pumpWidget(
        _wrap(() => notifier = _SeedableAutoReloadNotifier()),
      );
      await tester.pump();

      notifier.seedPending({'/proj/alu.sv'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SnackBar), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AutoReloadSnackbarHost)),
      );
      expect(
        container.read(autoReloadNotifierProvider).pendingPaths,
        isNotEmpty,
      );

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      await tester.tap(find.text(l10n.watcherAutoReloadActionRerun));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
      // With no active config, rerun() is a no-op; the closed-snackbar
      // handler treats it as Dismiss and clears the pending set.
      expect(
        container.read(autoReloadNotifierProvider).pendingPaths,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await _drainSnackbar(tester);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        late _SeedableAutoReloadNotifier notifier;
        await tester.pumpWidget(
          _wrap(
            () => notifier = _SeedableAutoReloadNotifier(),
            locale: locale,
          ),
        );
        await tester.pump();
        notifier.seedPending({'/proj/alu.sv'});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: '$locale');
        await _drainSnackbar(tester);
      }
    });
  });
}
