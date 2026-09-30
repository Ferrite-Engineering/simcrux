// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:simcrux/features/run/screens/run_screen.dart';
import 'package:simcrux/features/settings/screens/settings_screen.dart';
import 'package:simcrux/features/test_detail/screens/test_detail_screen.dart';
import 'package:simcrux/features/workspace/screens/workspace_screen.dart';

/// Root [ScaffoldMessengerState] key. Held outside the widget tree so
/// app-lifecycle callbacks (workspace hydration, missing-file recovery) can
/// surface snackbars without owning a [BuildContext]. Wired into
/// [MaterialApp.router]'s `scaffoldMessengerKey`.
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>(debugLabel: 'simcrux_root_messenger');

/// Application route table.
///
/// Layout:
///
/// - `/` — `WorkspaceScreen` hosting `crux.PaneHost<SimcruxTabPayload>`
///   (workspace empty-canvas state when no tabs are open; the
///   per-tab regression dashboard scaffold once tabs land).
/// - `/settings` — Settings screen.
/// - `/projects/:projectId/runs/:runId` and `…/tests/:testId` — deep
///   links retained so future browser bookmark / web-dashboard
///   navigation paths still resolve. Tab-aware routing into those
///   surfaces from the workspace lands in a follow-on batch.
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'workspace',
        builder: (context, state) => const WorkspaceScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      // The /projects/:projectId/runs/:runId/tests/:testId tree is
      // retained without the bare /projects/:projectId entry: the
      // workspace is the project landing surface now, and the
      // remaining deep links remain bookmarkable for the eventual web
      // dashboard.
      GoRoute(
        path: '/projects/:projectId/runs/:runId',
        name: 'run',
        builder: (context, state) => RunScreen(
          projectId: state.pathParameters['projectId']!,
          runId: state.pathParameters['runId']!,
        ),
        routes: [
          GoRoute(
            path: 'tests/:testId',
            name: 'testDetail',
            builder: (context, state) => TestDetailScreen(
              projectId: state.pathParameters['projectId']!,
              runId: state.pathParameters['runId']!,
              testId: state.pathParameters['testId']!,
            ),
          ),
        ],
      ),
    ],
  ),
);
