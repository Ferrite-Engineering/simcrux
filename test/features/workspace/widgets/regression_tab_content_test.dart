// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/widgets/regression_tab_content.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/config/config_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RegressionTabContent', () {
    testWidgets('renders the placeholder when payload.configPath is empty', (
      tester,
    ) async {
      final tabId = crux.TabId.generate();
      final paneId = crux.PaneId.generate();
      final tab = crux.WorkspaceTab<SimcruxTabPayload>(
        id: tabId,
        displayName: 'new tab',
        paneId: paneId,
        payload: SimcruxTabPayload(configPath: ''),
      );

      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabContainer = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(tabId),
      );
      addTearDown(tabContainer.dispose);

      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: root,
          child: MaterialApp(
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: UncontrolledProviderScope(
              container: tabContainer,
              child: RegressionTabContent(tab: tab),
            ),
          ),
        ),
      );
      // Don't call pumpAndSettle — the file watcher / SQLite layer
      // would otherwise try to spin up. The first frame is enough to
      // verify the placeholder renders.
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Placeholder body — the projectScreenPlaceholder ARB string.
      expect(find.textContaining('No project loaded'), findsOneWidget);
    });

    testWidgets('a config that fails to load is announced, not only drawn', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final recorder = AnnouncementRecorder.attach(tester);
      final tabId = crux.TabId.generate();
      const path = '/kit/broken.yaml';
      final tab = crux.WorkspaceTab<SimcruxTabPayload>(
        id: tabId,
        displayName: 'broken.yaml',
        paneId: crux.PaneId.generate(),
        payload: SimcruxTabPayload(configPath: path),
      );
      // The real loader, reading YAML that does not parse, so the spoken
      // reason is the one the error pane shows.
      final root = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          configLoaderProvider.overrideWithValue(
            ConfigLoader(readFile: (_) async => 'suites: [unterminated'),
          ),
        ],
      );
      addTearDown(root.dispose);
      final tabContainer = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(tabId),
      );
      addTearDown(tabContainer.dispose);

      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: root,
          child: MaterialApp(
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: UncontrolledProviderScope(
              container: tabContainer,
              child: RegressionTabContent(tab: tab),
            ),
          ),
        ),
      );
      // The tab kicks the loader after its first frame; the load is
      // microtask-bound here, so a few frames settle it.
      for (var i = 0; i < 10 && recorder.messages.isEmpty; i++) {
        await tester.pump();
      }

      final l10n = L10N.of(tester.element(find.byType(RegressionTabContent)));
      final error = tabContainer.read(configLoadErrorProvider);
      expect(error, isNotNull);
      final spoken =
          '${l10n.configLoadFailedTitle}\n'
          '${l10n.configLoadFailedDetail(path, error!.message)}';
      expect(recorder.messages, [spoken]);
      // The pane shows the same failure the screen reader spoke.
      await tester.pump();
      expect(find.text(l10n.configLoadFailedTitle), findsOneWidget);
    });

    testWidgets(
      'locale sweep renders the empty-payload placeholder in '
      'en/zh_CN/zh/ja/ko',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        for (final locale in const [
          Locale('en'),
          Locale('zh', 'CN'),
          Locale('zh'),
          Locale('ja'),
          Locale('ko'),
        ]) {
          final tabId = crux.TabId.generate();
          final tab = crux.WorkspaceTab<SimcruxTabPayload>(
            id: tabId,
            displayName: 'new tab',
            paneId: crux.PaneId.generate(),
            payload: SimcruxTabPayload(configPath: ''),
          );
          final root = ProviderContainer();
          addTearDown(root.dispose);
          final tabContainer = ProviderContainer(
            parent: root,
            overrides: simcruxTabOverrides(tabId),
          );
          addTearDown(tabContainer.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: root,
              child: MaterialApp(
                locale: locale,
                localizationsDelegates: const [
                  L10N.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: L10N.supportedLocales,
                home: UncontrolledProviderScope(
                  container: tabContainer,
                  child: RegressionTabContent(tab: tab),
                ),
              ),
            ),
          );
          // Same single-frame discipline as above: don't let the file
          // watcher / SQLite layer spin up.
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$locale');
        }
      },
    );
  });
}
