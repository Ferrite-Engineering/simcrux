// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/remote/providers/cxp_presence_provider.dart';
import 'package:simcrux/features/remote/simcrux_cxp_binding.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';

import '../../flow/flow_panel_harness.dart';

// SimCrux tells its peers what each window has open (CXP §8.1
// `active_document`): the active tab's name, so a "Cross-probe to" menu
// with two SimCrux windows says which is which. Nothing else wired it.
//
// MUTATION: set the document once at start and never on a tab change, and
// the switch case fails; drop the watch from the app root and the
// reachability guard fails.

void main() {
  late Directory workspaceDir;
  late Directory manifests;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    workspaceDir = Directory.systemTemp.createTempSync('simcrux_presence_');
    manifests = Directory.systemTemp.createTempSync('simcrux_presence_m_');
  });

  tearDown(() {
    for (final dir in <Directory>[workspaceDir, manifests]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('the active tab is the active document, and follows the tab', () async {
    // Never started: the document is held and announced once it starts.
    final runtime = CruxCxpRuntime(
      binding: kSimcruxCxpBinding,
      productVersion: '1.2.0',
      manifestDirectory: manifests.path,
      port: 0,
      handler: () => const CruxCxpRequestHandler(),
    );
    final container = ProviderContainer(
      overrides: [
        telemetryServiceProvider.overrideWithValue(RecordingTelemetry()),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => workspaceDir,
          ),
        ),
        cruxCxpRuntimeProvider.overrideWith((ref) async => runtime),
        cruxCxpServerStatusProvider.overrideWithValue((
          running: false,
          port: null,
          problem: null,
        )),
      ],
    );
    addTearDown(() async {
      await container.read(workspaceProvider.notifier).flushPendingSave();
      container.dispose();
    });
    await container.read(workspaceProvider.future);
    await container.read(cruxCxpRuntimeProvider.future);
    container.read(simcruxCxpPresenceProvider);
    expect(runtime.activeDocument, isNull, reason: 'no tab open');

    final notifier = container.read(workspaceProvider.notifier);
    final fifo = await notifier.openTab(
      displayName: 'fifo.yaml',
      payload: SimcruxTabPayload(configPath: '/p/fifo/fifo.yaml'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(runtime.activeDocument, 'fifo.yaml');

    await notifier.openTab(
      displayName: 'alu.yaml',
      payload: SimcruxTabPayload(configPath: '/p/alu/alu.yaml'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(runtime.activeDocument, 'alu.yaml');

    await notifier.setActiveTab(fifo);
    await Future<void>.delayed(Duration.zero);
    expect(runtime.activeDocument, 'fifo.yaml');
  });

  test('the active document is the active tab name, or none', () {
    expect(simcruxActiveDocumentOf(null), isNull);
  });
}
