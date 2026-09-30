// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_projects/crux_projects.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/project_workspace_sync.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../../support/answered_telemetry.dart';

/// In-memory multi-project registry double (the open-core
/// [NoopProjectRegistry] has replace-on-open semantics, which can't
/// exercise the multi-tab recorder paths). Mutation counters let the
/// convergence test assert the sync settles instead of ping-ponging.
class _FakeMultiRegistry implements ProjectRegistry {
  @override
  Future<void> shutdownAll() async {}

  ProjectWorkspace _ws = ProjectWorkspace.empty();
  final StreamController<ProjectWorkspace> _controller =
      StreamController<ProjectWorkspace>.broadcast();

  int openCalls = 0;
  int closeCalls = 0;
  int setActiveCalls = 0;

  int get totalMutations => openCalls + closeCalls + setActiveCalls;

  void _emit() => _controller.add(_ws);

  ProjectDescriptor? _byPath(String path) {
    for (final d in _ws.openProjects) {
      if (d.projectPath == path) return d;
    }
    return null;
  }

  @override
  ProjectWorkspace get current => _ws;

  @override
  Stream<ProjectWorkspace> watch() => _controller.stream;

  @override
  Future<ProjectDescriptor> openProject(String projectPath) async {
    openCalls++;
    final existing = _byPath(projectPath);
    if (existing != null) {
      _ws = ProjectWorkspace(
        openProjects: _ws.openProjects,
        activeProjectId: existing.id,
        recentProjects: _ws.recentProjects,
      );
      _emit();
      return existing;
    }
    final descriptor = ProjectDescriptor(
      id: ProjectDescriptor.idForPath(projectPath),
      displayName: projectPath.split('/').last,
      projectPath: projectPath,
      loadedAt: DateTime(2026),
      lastAccessedAt: DateTime(2026),
    );
    _ws = ProjectWorkspace(
      openProjects: [..._ws.openProjects, descriptor],
      activeProjectId: descriptor.id,
      recentProjects: [
        for (final d in _ws.recentProjects)
          if (d.projectPath != projectPath) d,
      ],
    );
    _emit();
    return descriptor;
  }

  @override
  Future<void> closeProject(String projectId, {bool hardClose = false}) async {
    closeCalls++;
    ProjectDescriptor? closing;
    for (final d in _ws.openProjects) {
      if (d.id == projectId) closing = d;
    }
    if (closing == null) return;
    final remaining = [
      for (final d in _ws.openProjects)
        if (d.id != projectId) d,
    ];
    _ws = ProjectWorkspace(
      openProjects: remaining,
      activeProjectId: _ws.activeProjectId == projectId
          ? (remaining.isNotEmpty ? remaining.last.id : null)
          : _ws.activeProjectId,
      recentProjects: hardClose
          ? _ws.recentProjects
          : [closing.copyWith(isPinned: false), ..._ws.recentProjects],
    );
    _emit();
  }

  @override
  Future<void> closeAllProjects() async {
    for (final d in [..._ws.openProjects]) {
      if (!d.isPinned) await closeProject(d.id);
    }
  }

  @override
  Future<void> setActiveProject(String projectId) async {
    setActiveCalls++;
    if (!_ws.openProjects.any((d) => d.id == projectId)) return;
    if (_ws.activeProjectId == projectId) return;
    _ws = ProjectWorkspace(
      openProjects: _ws.openProjects,
      activeProjectId: projectId,
      recentProjects: _ws.recentProjects,
    );
    _emit();
  }

  @override
  Future<void> pinProject(String projectId, {required bool pinned}) async {}

  @override
  Future<void> reorderProjects(List<String> newOrderIds) async {}

  @override
  Future<void> clearRecentProject(String projectId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeMultiRegistry registry;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('simcrux-sync-');
    registry = _FakeMultiRegistry();
    final service = WorkspaceService<SimcruxTabPayload>(
      codec: const SimcruxWorkspaceCodec(),
      directoryFactory: () async => tempDir,
    );
    container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simcruxWorkspaceServiceProvider.overrideWithValue(service),
        projectRegistryProvider.overrideWithValue(registry),
      ],
    );
    // Hydrate the workspace, then realize the sync (installs both
    // listeners) the way app.dart's provider anchor does. Must be an
    // active *listen* (matching app.dart's `innerRef.watch`) — a bare
    // `read` leaves the element listener-less and Riverpod 3's
    // automatic pausing then suspends its stream subscriptions.
    await container.read(workspaceProvider.future);
    container.listen(projectWorkspaceSyncProvider, (_, _) {});
    await _settle();
  });

  tearDown(() async {
    await container.read(workspaceProvider.notifier).flushPendingSave();
    container.dispose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('recorder (workspace tabs → registry)', () {
    test('opening a tab records the project and makes it active', () async {
      await container
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'a',
            payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
          );
      await _settle();
      expect(
        registry.current.openProjects.map((d) => d.projectPath),
        contains('/proj/a.yaml'),
      );
      expect(
        registry.current.activeProject?.projectPath,
        '/proj/a.yaml',
      );
    });

    test('closing a tab moves the project into recents', () async {
      final notifier = container.read(workspaceProvider.notifier);
      final aId = await notifier.openTab(
        displayName: 'a',
        payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
      );
      await notifier.openTab(
        displayName: 'b',
        payload: SimcruxTabPayload(configPath: '/proj/b.yaml'),
      );
      await _settle();
      await notifier.closeTab(aId);
      await _settle();
      expect(
        registry.current.openProjects.map((d) => d.projectPath),
        ['/proj/b.yaml'],
      );
      expect(
        registry.current.recentProjects.map((d) => d.projectPath),
        contains('/proj/a.yaml'),
      );
    });

    test('switching the active tab sets the matching project active', () async {
      final notifier = container.read(workspaceProvider.notifier);
      final aId = await notifier.openTab(
        displayName: 'a',
        payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
      );
      await notifier.openTab(
        displayName: 'b',
        payload: SimcruxTabPayload(configPath: '/proj/b.yaml'),
      );
      await _settle();
      expect(registry.current.activeProject?.projectPath, '/proj/b.yaml');
      await notifier.setActiveTab(aId);
      await _settle();
      expect(registry.current.activeProject?.projectPath, '/proj/a.yaml');
    });

    test('empty-canvas tabs (no configPath) are not recorded', () async {
      await container
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'empty',
            payload: SimcruxTabPayload(configPath: ''),
          );
      await _settle();
      expect(registry.current.openProjects, isEmpty);
    });
  });

  group('follower (registry → workspace tabs)', () {
    test(
      'registry-originated open (recents Reopen / reopenRecentProject) '
      'opens + activates a workspace tab',
      () async {
        await registry.openProject('/proj/c.yaml');
        await _settle();
        final ws = container.read(workspaceProvider).value!;
        expect(
          ws.tabs.map((t) => t.payload.configPath),
          contains('/proj/c.yaml'),
        );
        final activeTab = ws.tabs.where((t) => t.id == ws.activeTabId).single;
        expect(activeTab.payload.configPath, '/proj/c.yaml');
      },
    );

    test('registry setActiveProject activates the matching tab', () async {
      final notifier = container.read(workspaceProvider.notifier);
      await notifier.openTab(
        displayName: 'a',
        payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
      );
      await notifier.openTab(
        displayName: 'b',
        payload: SimcruxTabPayload(configPath: '/proj/b.yaml'),
      );
      await _settle();
      final aDescriptor = registry.current.openProjects.firstWhere(
        (d) => d.projectPath == '/proj/a.yaml',
      );
      await registry.setActiveProject(aDescriptor.id);
      await _settle();
      final ws = container.read(workspaceProvider).value!;
      final activeTab = ws.tabs.where((t) => t.id == ws.activeTabId).single;
      expect(activeTab.payload.configPath, '/proj/a.yaml');
    });

    test(
      'registry-originated close (switcher per-row Close) closes the tab',
      () async {
        final notifier = container.read(workspaceProvider.notifier);
        await notifier.openTab(
          displayName: 'a',
          payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
        );
        await notifier.openTab(
          displayName: 'b',
          payload: SimcruxTabPayload(configPath: '/proj/b.yaml'),
        );
        await _settle();
        final aDescriptor = registry.current.openProjects.firstWhere(
          (d) => d.projectPath == '/proj/a.yaml',
        );
        await registry.closeProject(aDescriptor.id);
        await _settle();
        final ws = container.read(workspaceProvider).value!;
        expect(
          ws.tabs.map((t) => t.payload.configPath),
          ['/proj/b.yaml'],
        );
      },
    );
  });

  group('single-project (NoopProjectRegistry / open-core) registry', () {
    // Unlike every other group in this file, these tests deliberately do
    // NOT override `projectRegistryProvider` — they exercise the real
    // open-core `NoopProjectRegistry` default (strict replace-on-open,
    // single project) via [_buildNoopContainer]. Regression coverage for a
    // defect this sync's own recorder could self-inflict: recording a
    // second tab replaces the first tab's entry in a replace-on-open
    // registry, and the *next* convergence pass must not misread that
    // self-inflicted change as an external "the user closed/switched
    // projects" signal.

    test(
      'opening a second tab sequentially does not close the first tab',
      () async {
        final ctx = await _buildNoopContainer();
        try {
          final notifier = ctx.container.read(workspaceProvider.notifier);
          await notifier.openTab(
            displayName: 'a',
            payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
          );
          // Let the sync fully record `a` into the registry before opening
          // `b` — this mirrors real usage (and the CLI multi-config open
          // flow) where each tab lands in its own convergence pass rather
          // than a single batched one.
          await _settle();
          await notifier.openTab(
            displayName: 'b',
            payload: SimcruxTabPayload(configPath: '/proj/b.yaml'),
          );
          await _settle();

          final ws = ctx.container.read(workspaceProvider).value!;
          expect(
            ws.tabs.map((t) => t.payload.configPath).toSet(),
            {'/proj/a.yaml', '/proj/b.yaml'},
            reason:
                'both tabs must remain open — recording b into a '
                'replace-on-open registry must not read back as "a was '
                'closed" on the next pass',
          );
          // The active tab must stay on the one the user actually opened
          // last (b), not get forced back to a by a stale activation
          // delta.
          final activeTab = ws.tabs.where((t) => t.id == ws.activeTabId).single;
          expect(activeTab.payload.configPath, '/proj/b.yaml');
        } finally {
          await ctx.dispose();
        }
      },
    );

    test(
      'opening three tabs sequentially keeps all three open '
      '(CLI multi-config shape)',
      () async {
        final ctx = await _buildNoopContainer();
        try {
          final notifier = ctx.container.read(workspaceProvider.notifier);
          for (final name in const ['a', 'b', 'c']) {
            await notifier.openTab(
              displayName: name,
              payload: SimcruxTabPayload(configPath: '/proj/$name.yaml'),
            );
          }
          await _settle();
          await _settle();

          final ws = ctx.container.read(workspaceProvider).value!;
          expect(
            ws.tabs.map((t) => t.payload.configPath).toSet(),
            {'/proj/a.yaml', '/proj/b.yaml', '/proj/c.yaml'},
            reason: 'every CLI-opened tab must survive the registry sync',
          );
        } finally {
          await ctx.dispose();
        }
      },
    );
  });

  group('loop safety', () {
    test('the sync converges — no further mutations after settling', () async {
      final notifier = container.read(workspaceProvider.notifier);
      await notifier.openTab(
        displayName: 'a',
        payload: SimcruxTabPayload(configPath: '/proj/a.yaml'),
      );
      await notifier.openTab(
        displayName: 'b',
        payload: SimcruxTabPayload(configPath: '/proj/b.yaml'),
      );
      await registry.openProject('/proj/c.yaml');
      await _settle();
      final mutationsAfterSettle = registry.totalMutations;
      // A generous extra window: a ping-ponging loop would keep the
      // counters climbing here.
      await _settle();
      await _settle();
      expect(registry.totalMutations, mutationsAfterSettle);
      // And the two sides agree on the active project.
      final ws = container.read(workspaceProvider).value!;
      final activeTab = ws.tabs.where((t) => t.id == ws.activeTabId).single;
      expect(
        activeTab.payload.configPath,
        registry.current.activeProject?.projectPath,
      );
    });
  });
}

/// Lets the listener→mutation→listener cascades drain. The sync's
/// handlers are async (registry + workspace mutations both await), so
/// a few event-loop turns are needed for full convergence. There is
/// no single external condition shared by every call site (16, each
/// waiting on a different downstream state), so — unlike this file's
/// sibling test files — this pumps the event queue for a fixed number
/// of turns rather than polling a specific predicate.
Future<void> _settle() => pumpEventQueue(times: 10);

/// A disposable [ProviderContainer] wired against the real, unoverridden
/// `projectRegistryProvider` default (`NoopProjectRegistry`) — used by the
/// "single-project registry" group, which needs the actual open-core
/// replace-on-open semantics rather than [_FakeMultiRegistry].
class _NoopContainerContext {
  _NoopContainerContext(this.container, this._tempDir);

  final ProviderContainer container;
  final Directory _tempDir;

  Future<void> dispose() async {
    await container.read(workspaceProvider.notifier).flushPendingSave();
    container.dispose();
    if (_tempDir.existsSync()) {
      await _tempDir.delete(recursive: true);
    }
  }
}

Future<_NoopContainerContext> _buildNoopContainer() async {
  final tempDir = await Directory.systemTemp.createTemp('simcrux-sync-noop-');
  final service = WorkspaceService<SimcruxTabPayload>(
    codec: const SimcruxWorkspaceCodec(),
    directoryFactory: () async => tempDir,
  );
  final container = ProviderContainer(
    overrides: [
      ...answeredTelemetryOverrides(),
      simcruxWorkspaceServiceProvider.overrideWithValue(service),
    ],
  );
  await container.read(workspaceProvider.future);
  container.listen(projectWorkspaceSyncProvider, (_, _) {});
  await _settle();
  return _NoopContainerContext(container, tempDir);
}
