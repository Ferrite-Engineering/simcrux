// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
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

void main() {
  group('AutoReloadSnackbarHost', () {
    testWidgets('renders its child and no prompt while nothing pends', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_SeedableAutoReloadNotifier.new));
      await tester.pump();

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byKey(kCruxReloadPromptKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the shared banner when a change pends', (tester) async {
      late _SeedableAutoReloadNotifier notifier;
      await tester.pumpWidget(
        _wrap(() => notifier = _SeedableAutoReloadNotifier()),
      );
      await tester.pump();

      notifier.seedPending({'/proj/alu.sv'});
      await tester.pumpAndSettle();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.byKey(kCruxReloadPromptKey), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text(l10n.watcherAutoReloadBanner), findsOneWidget);
      expect(find.text(l10n.watcherAutoReloadActionRerun), findsOneWidget);
      expect(find.text(l10n.fileWatcherIgnore), findsOneWidget);
    });

    testWidgets('Ignore closes it and clears the pending paths', (
      tester,
    ) async {
      // The prompt used to be a snackbar whose only button was Re-run now,
      // which never timed out and could not be declined.
      late _SeedableAutoReloadNotifier notifier;
      await tester.pumpWidget(
        _wrap(() => notifier = _SeedableAutoReloadNotifier()),
      );
      await tester.pump();
      notifier.seedPending({'/proj/alu.sv'});
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kCruxReloadPromptIgnoreKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kCruxReloadPromptKey), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AutoReloadSnackbarHost)),
      );
      expect(
        container.read(autoReloadNotifierProvider).pendingPaths,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Re-run now closes it and clears the pending paths', (
      tester,
    ) async {
      late _SeedableAutoReloadNotifier notifier;
      await tester.pumpWidget(
        _wrap(() => notifier = _SeedableAutoReloadNotifier()),
      );
      await tester.pump();
      notifier.seedPending({'/proj/alu.sv'});
      await tester.pumpAndSettle();

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      await tester.tap(find.text(l10n.watcherAutoReloadActionRerun));
      await tester.pumpAndSettle();
      expect(find.byKey(kCruxReloadPromptKey), findsNothing);
      // With no active config rerun() is a no-op, and the pending set is
      // still cleared: either choice settles the prompt.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AutoReloadSnackbarHost)),
      );
      expect(
        container.read(autoReloadNotifierProvider).pendingPaths,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a second change while it is up does not stack a banner', (
      tester,
    ) async {
      late _SeedableAutoReloadNotifier notifier;
      await tester.pumpWidget(
        _wrap(() => notifier = _SeedableAutoReloadNotifier()),
      );
      await tester.pump();
      notifier.seedPending({'/proj/alu.sv'});
      await tester.pumpAndSettle();
      notifier.seedPending({'/proj/alu.sv', '/proj/tb.sv'});
      await tester.pumpAndSettle();
      expect(find.byKey(kCruxReloadPromptKey), findsOneWidget);
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
        await tester.pumpAndSettle();
        expect(find.byKey(kCruxReloadPromptKey), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
