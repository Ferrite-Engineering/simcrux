// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/helpers/app_driver.dart
//
// Open-core SimCrux integration-test helper library. Mirrors the WaveCrux /
// NetCrux harness: `bootSimcrux` launches the real app via `bootstrap` from
// `package:simcrux/app.dart`, and the `pumpUntil` / `rootContainer` /
// workspace round-trip primitives follow the suite-wide conventions (never
// `pumpAndSettle(Duration)` — the live binding treats the pump duration as a
// per-pump interval, not a timeout).
//
// SimCrux boots into a `WorkspaceContainersScope` (the root container above
// the scoped one), so `rootContainer` reads the scoped container, the nearest
// one above `SimcruxApp`.

import 'dart:ui' as ui;

import 'package:crux_eula/crux_eula.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/app.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

/// Suppresses the macOS embedder's mid-test "semantics enabled" signal so
/// integration tests don't trip `_verifySemanticsHandlesWereDisposed` at
/// teardown. Call once in `main()` after `ensureInitialized`.
void suppressPlatformSemanticsLeak() {
  ui.PlatformDispatcher.instance.onSemanticsEnabledChanged = () {};
}

/// Bounded condition-poll — use this, NOT `pumpAndSettle(Duration)`.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  final maxIterations = (timeout.inMilliseconds / interval.inMilliseconds)
      .ceil();
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return true;
    await tester.pump(interval);
  }
  return condition();
}

/// The [ProviderContainer] the live app renders against: the scoped
/// container, the nearest one above [SimcruxApp]. Not the outermost scope —
/// `WorkspaceContainersScope` mounts the root container above it.
ProviderContainer rootContainer(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(SimcruxApp)),
    listen: false,
  );
}

/// The live workspace value, or `null` while it is still hydrating.
Workspace<SimcruxTabPayload>? liveWorkspaceOrNull(WidgetTester tester) =>
    rootContainer(tester).read(workspaceProvider).value;

/// The live workspace value. Throws if it has not hydrated yet.
Workspace<SimcruxTabPayload> liveWorkspace(WidgetTester tester) {
  final ws = liveWorkspaceOrNull(tester);
  if (ws == null) {
    throw StateError('liveWorkspace: workspace has not hydrated yet');
  }
  return ws;
}

/// The number of tabs currently open across every pane.
int tabCount(WidgetTester tester) =>
    liveWorkspaceOrNull(tester)?.tabs.length ?? 0;

/// Loads the persisted `{appSupportDir}/workspace.json` through a FRESH
/// `WorkspaceService` — what the next cold start would hydrate.
Future<Workspace<SimcruxTabPayload>> freshWorkspaceLoad() {
  return WorkspaceService<SimcruxTabPayload>(
    codec: const SimcruxWorkspaceCodec(),
  ).load();
}

/// Deletes the auto-managed `workspace.json` so a fresh launch starts empty.
Future<void> clearPersistedWorkspace() async {
  await WorkspaceService<SimcruxTabPayload>(
    codec: const SimcruxWorkspaceCodec(),
  ).clear();
}

/// Records the current EULA as accepted, so the app under test boots to its
/// UI rather than to the agreement.
///
/// `CruxEulaGate` is right for a real first launch and wrong for a test of
/// anything else: it covers the whole app with a modal barrier that swallows
/// every tap and drag. The symptom is a gesture that "would not hit test" and
/// an assertion about what that gesture should have done, never a visible
/// agreement. Seeding goes through the real `SharedPreferences` store, which
/// `SimcruxEulaStorage` reads, so a broken adapter still fails here.
Future<void> seedEulaAcceptance() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kCruxEulaAcceptedVersionKey, kCruxEulaVersion);
}

/// Records an answer to the first-launch telemetry disclosure, so the app
/// under test boots to its UI rather than to the question.
///
/// The same shape as [seedEulaAcceptance] and for the same reason: with the
/// beta over, an installation that has never answered gets
/// `TelemetryConsentGate`'s modal over the whole app, and a journey then
/// fails on a tap that "would not hit test" rather than on anything it meant
/// to assert. Declined rather than accepted, because a test run has no
/// business reporting usage — and because the gate is answered either way,
/// which is all the seeding is for. The disclosure itself is covered by its
/// own tests, where it is the subject.
Future<void> seedTelemetryConsentAnswered() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    kTelemetryConsentKey,
    TelemetryConsentState.disabled.name,
  );
}

/// Boots the open-core SimCrux app via [bootstrap] and pumps until the
/// workspace hydrates and the first frame settles. Call once per test body.
///
/// The EULA is seeded as accepted and the telemetry disclosure as answered
/// first; see [seedEulaAcceptance] and [seedTelemetryConsentAnswered].
Future<void> bootSimcrux(
  WidgetTester tester, {
  List<String> args = const [],
  List<Override> extraOverrides = const [],
  bool clearWorkspace = true,
  Size surfaceSize = const Size(1600, 1000),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (clearWorkspace) {
    await clearPersistedWorkspace();
    addTearDown(clearPersistedWorkspace);
  }
  await seedEulaAcceptance();
  await seedTelemetryConsentAnswered();
  await bootstrap(args: args, extraOverrides: extraOverrides);
  await tester.pump();
  await pumpUntil(
    tester,
    () => rootContainer(tester).read(workspaceProvider).hasValue,
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
