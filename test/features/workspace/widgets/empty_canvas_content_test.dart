// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/features/workspace/widgets/empty_canvas_content.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Fixed build metadata for the version-line test, so the assertion does not
/// track the real `pubspec.yaml` version.
const _testBuildInfo = ApplicationBuildInfo(
  version: '9.9.9',
  buildNumber: '7',
  gitShortSha: 'abc1234',
  os: 'macos',
  architecture: 'arm64',
  flutterSdkVersion: '3.44.8',
  dartSdkVersion: '3.12.2',
);

Future<void> _pumpWith({
  required WidgetTester tester,
  required Locale locale,
  required crux.WorkspaceService<SimcruxTabPayload> workspaceService,
  AppSettings settings = const AppSettings(),
  ApplicationBuildInfo? buildInfo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(
          _FakeSettingsNotifier.factory(settings),
        ),
        simcruxWorkspaceServiceProvider.overrideWithValue(workspaceService),
        if (buildInfo != null)
          aboutBuildInfoProvider.overrideWith((ref) async => buildInfo),
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
        home: const Scaffold(body: EmptyCanvasContent()),
      ),
    ),
  );
  // The header's GlowingAppIcon runs perpetual AnimationControllers
  // (.repeat), so pumpAndSettle never completes. Advance a bounded number of
  // frames instead — the same constraint WaveCrux's welcome test documents.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _FakeSettingsNotifier extends AppSettingsNotifier {
  _FakeSettingsNotifier(this._settings);
  final AppSettings _settings;
  static AppSettingsNotifier Function() factory(AppSettings settings) =>
      () => _FakeSettingsNotifier(settings);
  @override
  Future<AppSettings> build() async => _settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late crux.WorkspaceService<SimcruxTabPayload> workspaceService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('simcrux-ws-empty-');
    workspaceService = crux.WorkspaceService<SimcruxTabPayload>(
      codec: const SimcruxWorkspaceCodec(),
      directoryFactory: () async => tempDir,
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('EmptyCanvasContent — locale sweep', () {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders without overflow for $locale (no recent configs)', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pumpWith(
          tester: tester,
          locale: locale,
          workspaceService: workspaceService,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('shows recent-configs section when settings have entries', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const settings = AppSettings(
        recentProjectPaths: ['/projects/cpu/simcrux.yaml'],
        recentSessionPaths: ['/sessions/last.simcrux-session'],
      );
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        settings: settings,
        workspaceService: workspaceService,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('/projects/cpu/simcrux.yaml'), findsOneWidget);
      expect(find.text('/sessions/last.simcrux-session'), findsOneWidget);
    });

    testWidgets(
      'long recents lists stay bounded and scrollable — the Open '
      'actions remain on the card, not pushed off by list growth',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final settings = AppSettings(
          recentProjectPaths: [
            for (var i = 0; i < 10; i++) '/projects/p$i/simcrux.yaml',
          ],
          recentSessionPaths: [
            for (var i = 0; i < 10; i++) '/sessions/s$i.simcrux-session',
          ],
        );
        await _pumpWith(
          tester: tester,
          locale: const Locale('en'),
          settings: settings,
          workspaceService: workspaceService,
        );
        expect(tester.takeException(), isNull);
        // Both lists are capped (bounded boxes with visible scrollbars)…
        expect(find.byType(Scrollbar), findsNWidgets(2));
        for (final list in tester.widgetList(find.byType(ListView))) {
          final size = tester.getSize(find.byWidget(list));
          expect(size.height, lessThanOrEqualTo(180));
        }
        // …so the primary actions stay within the 800px-tall viewport
        // no matter how many recents accumulate.
        expect(find.text('Open Config…'), findsOneWidget);
        expect(
          tester.getBottomLeft(find.text('Open Config…')).dy,
          lessThanOrEqualTo(800),
        );
      },
    );

    testWidgets(
      'default 800x500 window with long recents lists: no overflow',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final settings = AppSettings(
          recentProjectPaths: [
            for (var i = 0; i < 10; i++) '/projects/p$i/simcrux.yaml',
          ],
          recentSessionPaths: [
            for (var i = 0; i < 10; i++) '/sessions/s$i.simcrux-session',
          ],
        );
        await _pumpWith(
          tester: tester,
          locale: const Locale('en'),
          settings: settings,
          workspaceService: workspaceService,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('renders the three primary Open actions in en', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        workspaceService: workspaceService,
      );
      expect(find.text('Open Config…'), findsOneWidget);
      expect(find.text('Open Session…'), findsOneWidget);
      expect(find.text('Open Workspace…'), findsOneWidget);
      // The discredited "New Config" button (opened an empty, unpopulatable
      // config tab) has been removed — the welcome offers only real Opens.
      expect(find.text('New Config'), findsNothing);
    });

    testWidgets('renders the version line under the subtitle', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        workspaceService: workspaceService,
        buildInfo: _testBuildInfo,
      );
      final versionText = find.byKey(const Key('empty_canvas_version'));
      expect(versionText, findsOneWidget);
      expect(tester.widget<Text>(versionText).data, 'Version 9.9.9');
    });

    testWidgets('omits the version line until build info resolves', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // No aboutBuildInfoProvider override: the real provider is async, so
      // `.value` stays null here and nothing should render.
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        workspaceService: workspaceService,
      );
      expect(find.byKey(const Key('empty_canvas_version')), findsNothing);
    });
  });
}
