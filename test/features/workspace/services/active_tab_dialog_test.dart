// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/diagnostics/widgets/tab_diagnostics_drawer.dart';
import 'package:simcrux/features/search/widgets/search_dialog.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_containers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/active_tab_scope.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import '../../../support/answered_telemetry.dart';

// A dialog on the root navigator is outside every tab's
// `UncontrolledProviderScope`, and SimCrux used to give one that reads a tab's
// providers (the log viewer, the search dialog) a SECOND scope over the tab's
// container. Riverpod flushes a container's pending rebuilds from inside the
// build of every scope that mounts it; the dialog's scope builds first and
// flushes into the tab content, which it is not an ancestor of, so a per-tab
// write while the dialog was open marked the tab's widgets dirty mid-build
// ("setState() or markNeedsBuild() called during build"). The dialogs are now
// pushed on the tab's own navigator, under the one scope the pane host mounts.

/// A per-tab DERIVED provider, as the dashboard and the inspector are: a
/// derived provider's rebuild is the one Riverpod defers to a scope's build,
/// which is where the assertion fired.
final Provider<String> _tabHeadlineProvider = Provider<String>(_headline);

String _headline(Ref ref) =>
    ref.watch(activeConfigProvider)?.projectFilePath ?? 'nothing';

RegressionConfig _config(String path) => RegressionConfig(
  projectFilePath: path,
  schemaVersion: '1',
  suites: const [],
  simulatorBinaries: const {},
);

/// The tab content: the derived provider, watched, and the buttons the menu
/// would use to open the surfaces under test.
class _TabBody extends ConsumerWidget {
  const _TabBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final headline = ref.watch(_tabHeadlineProvider);
    return Column(
      children: [
        Text('tab shows $headline'),
        ElevatedButton(
          onPressed: () => unawaited(SimcruxSearchDialog.open(context)),
          child: const Text('open search'),
        ),
        ElevatedButton(
          onPressed: () => unawaited(TabDiagnosticsDrawer.open(context)),
          child: const Text('open drawer'),
        ),
      ],
    );
  }
}

void main() {
  late Directory workspaceDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    workspaceDir = Directory.systemTemp.createTempSync('active_tab_dialog');
  });

  tearDown(() {
    if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
  });

  /// The production topology (`createWorkspaceContainers`, so the tab
  /// navigators are registered as a scope reconciler as in the app) around a
  /// pane host built the way `WorkspaceScreen` builds its own: every tab on
  /// its own navigator. [tabs] tabs are open, the first active.
  Future<WorkspaceContainers> pumpWorkspace(
    WidgetTester tester, {
    int tabs = 2,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Built and hydrated inside runAsync: the workspace load is real I/O, and
    // work started in the fake-async zone is never completed by a real-zone
    // await.
    final containers = (await tester.runAsync(() async {
      final built = createWorkspaceContainers(
        rootOverrides: [
          ...answeredTelemetryOverrides(),
          settingsServiceProvider.overrideWithValue(
            SettingsService<AppSettings>(
              const SimcruxSettingsCodec(),
              prefsOverride: prefs,
            ),
          ),
          simcruxWorkspaceServiceProvider.overrideWithValue(
            crux.WorkspaceService<SimcruxTabPayload>(
              codec: const SimcruxWorkspaceCodec(),
              directoryFactory: () async => workspaceDir,
            ),
          ),
          simcruxTabOverridesFactoryProvider.overrideWithValue(
            (id) => [
              ...simcruxTabOverrides(id),
              _tabHeadlineProvider.overrideWith(_headline),
            ],
          ),
        ],
      );
      await built.scoped.read(workspaceProvider.future);
      return built;
    }))!;
    addTearDown(containers.root.dispose);
    addTearDown(containers.managers.dispose);
    addTearDown(containers.scoped.dispose);
    final notifier = containers.scoped.read(workspaceProvider.notifier);
    for (var i = 0; i < tabs; i++) {
      await tester.runAsync(
        () => notifier.openTab(
          displayName: 'tab$i',
          payload: SimcruxTabPayload(configPath: '/w/tab$i.yaml'),
        ),
      );
    }
    if (tabs > 0) {
      final first = containers.scoped.read(workspaceProvider).value!.tabs.first;
      await tester.runAsync(() => notifier.setActiveTab(first.id));
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: containers.scoped,
        child: MaterialApp(
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(
            body: crux.PaneHost<SimcruxTabPayload>(
              provider: workspaceProvider,
              tabs: containers.managers.tabs,
              panes: containers.managers.panes,
              tabNavigators: containers.managers.tabNavigators,
              emptyCanvasContent: const Text('no tabs'),
              tabContentBuilder: (_, _) => const _TabBody(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.runAsync(notifier.flushPendingSave);
    });
    return containers;
  }

  List<crux.WorkspaceTab<SimcruxTabPayload>> tabsOf(
    WorkspaceContainers containers,
  ) => containers.scoped.read(workspaceProvider).value!.tabs;

  Finder search() => find.byType(SimcruxSearchDialog);

  ProviderContainer containerOf(WidgetTester tester, Finder finder) =>
      ProviderScope.containerOf(tester.element(finder), listen: false);

  // Mutation-verified: putting `SimcruxSearchDialog.open` back on the root
  // navigator with an `UncontrolledProviderScope(container: <the tab's>)`
  // around the dialog fails this test on the first write with the field
  // report's assertion ("setState() or markNeedsBuild() called during
  // build", on `_TabBody`, while `UncontrolledProviderScope` was building).
  testWidgets('a per-tab write while a dialog reads the same tab rebuilds '
      'the dialog and the tab content without marking either dirty '
      'mid-build', (tester) async {
    final containers = await pumpWorkspace(tester);
    final alpha = containers.managers.tabs.containerFor(
      tabsOf(containers).first.id,
    );

    await tester.tap(find.text('open search'));
    await tester.pumpAndSettle();
    expect(search(), findsOneWidget);
    // On the tab's own navigator, so under the tab's one scope.
    expect(containerOf(tester, search()), same(alpha));

    for (final name in ['first', 'second', 'third']) {
      alpha.read(activeConfigProvider.notifier).replace(_config('/w/$name'));
      // No duration: the frame builds before the zero-delay timers Riverpod
      // also arms, so the pending rebuild is flushed from inside a scope's
      // build, which is the path the assertion fired on.
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('tab shows /w/$name'), findsOneWidget);
    }
    expect(search(), findsOneWidget);
  });

  testWidgets('a tab dialog covers only its tab, and the tab bar beside it '
      'stays outside the barrier', (tester) async {
    await pumpWorkspace(tester);
    await tester.tap(find.text('open search'));
    await tester.pumpAndSettle();
    expect(search(), findsOneWidget);

    final window = tester.getRect(find.byType(Scaffold).first);
    final area = tester.getRect(find.byType(crux.CruxTabNavigatorHost).first);
    // The dialog route's barrier is the topmost one on the tab's navigator.
    final barrier = tester.getRect(
      find
          .descendant(
            of: find.byType(crux.CruxTabNavigatorHost).first,
            matching: find.byType(ModalBarrier),
          )
          .last,
    );
    expect(barrier, area);
    expect(barrier.top, greaterThan(window.top));
    expect(barrier.height, lessThan(window.height));
  });

  testWidgets('the guard key is per tab, so a second tab opens its own while '
      'the first stays open, hidden with its tab', (tester) async {
    final containers = await pumpWorkspace(tester);
    final notifier = containers.scoped.read(workspaceProvider.notifier);
    final alphaId = tabsOf(containers).first.id;
    final betaId = tabsOf(containers).last.id;
    final alphaKey = ActiveTab.guardKey(
      tester.element(find.text('open search')),
      'search',
    );
    expect(alphaKey, 'search@${alphaId.value}');

    await tester.tap(find.text('open search'));
    await tester.pumpAndSettle();
    expect(ModalGuard.isOpen(alphaKey), isTrue);

    await tester.runAsync(() => notifier.setActiveTab(betaId));
    await tester.pumpAndSettle();
    // Alpha's dialog is offstage with its tab; beta opens its own.
    expect(search().hitTestable(), findsNothing);
    final betaKey = ActiveTab.guardKey(
      tester.element(find.text('open search').hitTestable()),
      'search',
    );
    expect(betaKey, 'search@${betaId.value}');
    expect(ModalGuard.isOpen(betaKey), isFalse);
    await tester.tap(find.text('open search').hitTestable());
    await tester.pumpAndSettle();
    final shown = search().hitTestable();
    expect(shown, findsOneWidget);
    expect(
      containerOf(tester, shown),
      same(containers.managers.tabs.containerFor(betaId)),
    );

    await tester.runAsync(() => notifier.setActiveTab(alphaId));
    await tester.pumpAndSettle();
    final back = search().hitTestable();
    expect(back, findsOneWidget);
    expect(
      containerOf(tester, back),
      same(containers.managers.tabs.containerFor(alphaId)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a tab with its dialog open closes the dialog, '
      'completes its future and frees its guard', (tester) async {
    final containers = await pumpWorkspace(tester);
    final notifier = containers.scoped.read(workspaceProvider.notifier);
    final alphaId = tabsOf(containers).first.id;
    final context = tester.element(find.text('open search'));
    final key = ActiveTab.guardKey(context, 'search');
    expect(key, 'search@${alphaId.value}');

    var completed = false;
    unawaited(SimcruxSearchDialog.open(context).then((_) => completed = true));
    await tester.pumpAndSettle();
    expect(search(), findsOneWidget);
    expect(ModalGuard.isOpen(key), isTrue);

    await tester.runAsync(() => notifier.closeTab(alphaId));
    await tester.pumpAndSettle();

    expect(search(), findsNothing);
    expect(completed, isTrue);
    expect(ModalGuard.isOpen(key), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the diagnostics drawer reads the active tab under its one '
      'scope, survives per-tab writes, follows a tab switch and closes '
      'with the last tab', (tester) async {
    final containers = await pumpWorkspace(tester);
    final notifier = containers.scoped.read(workspaceProvider.notifier);
    final alphaId = tabsOf(containers).first.id;
    final betaId = tabsOf(containers).last.id;
    final alpha = containers.managers.tabs.containerFor(alphaId);
    alpha.read(activeConfigProvider.notifier).replace(_config('/w/a'));
    await tester.pump();

    await tester.tap(find.text('open drawer'));
    await tester.pumpAndSettle();
    final drawer = find.byType(TabDiagnosticsDrawer);
    expect(drawer, findsOneWidget);
    expect(containerOf(tester, drawer), same(alpha));
    expect(ModalGuard.isOpen('tabDiagnostics'), isTrue);

    for (final name in ['first', 'second']) {
      alpha.read(activeConfigProvider.notifier).replace(_config('/w/$name'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await tester.runAsync(() => notifier.setActiveTab(betaId));
    await tester.pumpAndSettle();
    final moved = find.byType(TabDiagnosticsDrawer).hitTestable();
    expect(moved, findsOneWidget);
    expect(
      containerOf(tester, moved),
      same(containers.managers.tabs.containerFor(betaId)),
    );

    await tester.runAsync(() => notifier.closeTab(betaId));
    await tester.pumpAndSettle();
    expect(containerOf(tester, find.byType(TabDiagnosticsDrawer)), same(alpha));
    await tester.runAsync(() => notifier.closeTab(alphaId));
    await tester.pumpAndSettle();
    expect(find.byType(TabDiagnosticsDrawer), findsNothing);
    expect(ModalGuard.isOpen('tabDiagnostics'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no tab the dialog goes on the root navigator and the '
      'guard key is the plain one', (tester) async {
    await pumpWorkspace(tester, tabs: 0);
    final context = tester.element(find.text('no tabs'));
    expect(ActiveTab.navigatorFor(context), isNull);
    expect(ActiveTab.guardKey(context, 'search'), 'search');
  });
}
