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
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/recent_lists.dart';
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

/// An in-memory Recent store that remembers what the list saved.
class _MemoryStore implements crux.CruxRecentStore {
  _MemoryStore(this.entries);

  List<String> entries;

  @override
  Future<List<String>> load() async => entries;

  @override
  Future<void> save(List<String> next) async => entries = next;
}

Future<void> _pumpWith({
  required WidgetTester tester,
  required Locale locale,
  required crux.WorkspaceService<SimcruxTabPayload> workspaceService,
  _MemoryStore? store,
  bool Function(String path)? exists,
  ApplicationBuildInfo? buildInfo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recentProjects.storeProvider.overrideWithValue(
          store ?? _MemoryStore(const <String>[]),
        ),
        // The paths below are not on disk: every entry is present unless a
        // test says otherwise.
        recentProjects.existsProvider.overrideWithValue(exists ?? (_) => true),
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

      testWidgets('renders recent projects without overflow for $locale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pumpWith(
          tester: tester,
          locale: locale,
          store: _MemoryStore(const ['/projects/cpu/simcrux.yaml']),
          workspaceService: workspaceService,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('/projects/cpu/simcrux.yaml'), findsOneWidget);
      });
    }
  });

  group('EmptyCanvasContent — the shared Recent list', () {
    testWidgets('shows the recent projects, most recent first, and no '
        'sessions section', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        store: _MemoryStore(const [
          '/projects/cpu/simcrux.yaml',
          '/projects/gpu/simcrux.yaml',
        ]),
        workspaceService: workspaceService,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Recent projects'), findsOneWidget);
      expect(find.text('/projects/cpu/simcrux.yaml'), findsOneWidget);
      expect(find.text('/projects/gpu/simcrux.yaml'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('/projects/cpu/simcrux.yaml')).dy,
        lessThan(tester.getTopLeft(find.text('/projects/gpu/simcrux.yaml')).dy),
      );
      // Nothing ever wrote the recent sessions, so the section is gone.
      expect(find.text('Recent sessions'), findsNothing);
    });

    testWidgets('says so when there are no recent projects', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        workspaceService: workspaceService,
      );
      expect(find.text('No recent projects'), findsOneWidget);
      expect(find.text('Clear Recent Projects'), findsNothing);
    });

    testWidgets('a row has a remove button that drops just that entry and '
        'saves the list', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _MemoryStore(const [
        '/projects/cpu/simcrux.yaml',
        '/projects/gpu/simcrux.yaml',
      ]);
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        store: store,
        workspaceService: workspaceService,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'cruxRecent:recentProjects:/projects/cpu/simcrux.yaml',
            ),
          ),
          matching: find.byKey(const ValueKey('cruxRecentRemove')),
        ),
      );
      await tester.pump();

      expect(find.text('/projects/cpu/simcrux.yaml'), findsNothing);
      expect(find.text('/projects/gpu/simcrux.yaml'), findsOneWidget);
      expect(store.entries, ['/projects/gpu/simcrux.yaml']);
    });

    testWidgets('the Clear Recent Projects button empties the list, saves it '
        'and says so', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _MemoryStore(const ['/projects/cpu/simcrux.yaml']);
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        store: store,
        workspaceService: workspaceService,
      );

      await tester.tap(find.text('Clear Recent Projects'));
      await tester.pump();

      expect(find.text('/projects/cpu/simcrux.yaml'), findsNothing);
      expect(find.text('No recent projects'), findsOneWidget);
      expect(find.text('Recent projects cleared.'), findsOneWidget);
      expect(store.entries, isEmpty);
    });

    testWidgets('a file that has gone is greyed and marked missing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        store: _MemoryStore(const [
          '/projects/cpu/simcrux.yaml',
          '/projects/gone/simcrux.yaml',
        ]),
        exists: (path) => !path.contains('/gone/'),
        workspaceService: workspaceService,
      );

      expect(find.text('Project file not found'), findsOneWidget);
      // The present entry still shows its path; the missing one shows why it
      // is greyed in place of the path.
      expect(find.text('/projects/cpu/simcrux.yaml'), findsOneWidget);
      expect(find.text('/projects/gone/simcrux.yaml'), findsNothing);
    });

    testWidgets('opening a missing file drops it and tells the user', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _MemoryStore(const [
        '/projects/cpu/simcrux.yaml',
        '/projects/gone/simcrux.yaml',
      ]);
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        store: store,
        exists: (path) => !path.contains('/gone/'),
        workspaceService: workspaceService,
      );

      await tester.tap(find.text('Project file not found'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('was removed from Recent Projects'),
        findsOneWidget,
      );
      expect(find.text('Project file not found'), findsNothing);
      expect(store.entries, ['/projects/cpu/simcrux.yaml']);
    });

    testWidgets('a full list of ten fits the default 800x500 window without '
        'overflow, the card scrolling', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpWith(
        tester: tester,
        locale: const Locale('en'),
        store: _MemoryStore([
          for (var i = 0; i < 10; i++) '/projects/p$i/simcrux.yaml',
        ]),
        workspaceService: workspaceService,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('EmptyCanvasContent — primary actions and version', () {
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
