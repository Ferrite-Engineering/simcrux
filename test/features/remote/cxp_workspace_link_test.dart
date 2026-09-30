// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../../support/answered_telemetry.dart';

/// Running-server stub so the producer's CXP-running gate passes without
/// binding a real socket.
class _RunningCxpServerNotifier extends CxpServerNotifier {
  _RunningCxpServerNotifier(this._fake);
  final SimCruxCxpServer _fake;

  @override
  Future<SimCruxCxpServer?> build() async => _fake;
}

class _DisabledCxpServerNotifier extends CxpServerNotifier {
  @override
  Future<SimCruxCxpServer?> build() async => null;
}

/// Exposes a container-bound [Ref] so the producer helper (which takes a `Ref`)
/// can be driven directly from a test.
final Provider<Ref> _refProbe = Provider<Ref>((ref) => ref);

ProviderContainer _makeContainer({
  required bool serverRunning,
  required String workspaceDir,
}) {
  final fake = SimCruxCxpServer(
    selfIdentity: buildSimcruxPeerIdentity(processId: 1),
    port: 0,
  );
  return ProviderContainer(
    overrides: <Override>[
      ...answeredTelemetryOverrides(),
      if (serverRunning)
        cxpServerProvider.overrideWith(() => _RunningCxpServerNotifier(fake))
      else
        cxpServerProvider.overrideWith(_DisabledCxpServerNotifier.new),
      cxpWorkspaceStoreProvider.overrideWithValue(
        CxpWorkspaceStore(workspaceDirectory: workspaceDir),
      ),
    ],
  );
}

void main() {
  late Directory tmp;
  late String designInputDir; // where simcrux.yaml lives
  late String outputVcdPath; // where the VCD lands (a DIFFERENT dir)
  late String workspaceDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_ws_link_');
    designInputDir = p.join(tmp.path, 'designs', 'cdc_capture');
    await Directory(designInputDir).create(recursive: true);
    // The simcrux.yaml itself need not exist for id derivation, but create it
    // so the derivation resolves the real (symlink-canonical) directory.
    await File(p.join(designInputDir, 'simcrux.yaml')).writeAsString('x');

    // The produced VCD is out-of-tree, in a build dir — NOT under the input
    // dir — exactly the case the design-input-dir key exists to survive.
    final buildDir = p.join(tmp.path, 'build', 'out');
    await Directory(buildDir).create(recursive: true);
    outputVcdPath = p.join(buildDir, 'cdc_capture.vcd');
    await File(outputVcdPath).writeAsString(r'$dumpfile');

    workspaceDir = p.join(tmp.path, 'workspace');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test(
    'a produced VCD is upserted under the design-INPUT-dir design_id so '
    'resolveArtifact(designId, "waveform") finds the real VCD path',
    () async {
      final container = _makeContainer(
        serverRunning: true,
        workspaceDir: workspaceDir,
      );
      addTearDown(container.dispose);
      await container.read(cxpServerProvider.future);
      final ref = container.read(_refProbe);

      // The producer keys off the design's INPUT (simcrux.yaml) directory.
      final designId = cxpDesignIdForPath(
        p.join(designInputDir, 'simcrux.yaml'),
      );

      await publishWaveformWorkspaceArtifact(
        ref,
        designId: designId,
        waveformPath: outputVcdPath,
        topModule: 'cdc_capture',
      );

      // A fresh store over the same directory resolves what was written.
      final store = CxpWorkspaceStore(workspaceDirectory: workspaceDir);
      final artifact = store.resolveArtifact(
        designId,
        kCxpWaveformArtifactKind,
      );
      expect(artifact, isNotNull);
      expect(artifact!.path, outputVcdPath);
      expect(artifact.producer, kSimcruxWorkspaceProducer);
      expect(artifact.topModule, 'cdc_capture');

      // The key derives from the input dir, not the VCD's output dir: an id
      // computed from the VCD's directory must NOT resolve the same artifact.
      final wrongId = cxpDesignIdForPath(outputVcdPath);
      expect(wrongId, isNot(designId));
      expect(
        store.resolveArtifact(wrongId, kCxpWaveformArtifactKind),
        isNull,
      );
    },
  );

  // CXP §11's roots, read through the production provider: every tab's
  // config directory, every recent project's directory, and the directories
  // the active config's tests name (sources up to their first glob segment,
  // include directories). Everything else is refused.
  test('the containment roots are the directories the user opened', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    late final ProviderContainer container;
    final managers = <WorkspaceContainerManagers>[];
    container = ProviderContainer(
      overrides: <Override>[
        ...answeredTelemetryOverrides(),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => Directory(tmp.path),
          ),
        ),
        workspaceContainerManagersProvider.overrideWith((ref) {
          final built = WorkspaceContainerManagers(
            tabs: crux.TabContainerManager(
              rootContainer: container,
              overridesFactory: simcruxTabOverrides,
            ),
            panes: crux.PaneContainerManager(rootContainer: container),
          );
          managers.add(built);
          return built;
        }),
      ],
    );
    addTearDown(() async {
      await container.read(workspaceProvider.notifier).flushPendingSave();
      for (final m in managers) {
        m.dispose();
      }
      container.dispose();
    });
    await container.read(appSettingsProvider.future);
    await container.read(workspaceProvider.future);
    final rule = container.read(cxpPathContainmentProvider);
    expect(
      rule.refuse(_abs('/proj/rtl/cpu.sv')),
      'no directory is open in this session',
    );

    // A background tab contributes its config's directory; the active tab
    // also contributes the directories its loaded config names.
    final workspace = container.read(workspaceProvider.notifier);
    await workspace.openTab(
      displayName: 'background',
      payload: SimcruxTabPayload(configPath: _abs('/tabbed/sim/simcrux.yaml')),
    );
    final activeTab = await workspace.openTab(
      displayName: 'active',
      payload: SimcruxTabPayload(configPath: _abs('/proj/sim/simcrux.yaml')),
    );
    await container
        .read(appSettingsProvider.notifier)
        .addRecentProject(_abs('/recent/sim/simcrux.yaml'));
    container
        .read(workspaceContainerManagersProvider)
        .tabs
        .containerFor(activeTab)
        .read(activeConfigProvider.notifier)
        .replace(
          RegressionConfig(
            projectFilePath: _abs('/proj/sim/simcrux.yaml'),
            schemaVersion: '1',
            suites: <Suite>[
              Suite(
                name: 's',
                tests: <TestSpec>[
                  TestSpec(
                    id: 's/t',
                    name: 't',
                    suiteName: 's',
                    simulatorId: 'icarus',
                    top: 'tb',
                    sources: <String>[
                      _abs('/proj/rtl/**/*.sv'),
                      _abs('/proj/ip/core.v'),
                    ],
                    includeDirs: <String>[_abs('/proj/inc')],
                  ),
                ],
              ),
            ],
            simulatorBinaries: const <String, SimulatorBinaryConfig>{},
          ),
        );

    for (final inside in <String>[
      _abs('/tabbed/sim/tb.sv'),
      _abs('/recent/sim/tb.sv'),
      _abs('/proj/sim/tb.sv'),
      _abs('/proj/rtl/core/alu.sv'),
      _abs('/proj/ip/core.v'),
      _abs('/proj/inc/defs.vh'),
    ]) {
      expect(rule.allows(inside), isTrue, reason: inside);
    }
    for (final outside in <String>[
      _abs('/etc/passwd'),
      _abs('/proj/other/x.v'),
    ]) {
      expect(rule.allows(outside), isFalse, reason: outside);
    }

    // The store carries the very instance the handler reads, since the
    // `crux.design_id` fallback resolves records through it. The production
    // server factory carries the floor instead: its one rule also screens a
    // `request_open_artifact` hint, which must not be rooted
    // (`kCxpOpenArtifactContainment`), so the handler's rooted check is the
    // one that keeps an editor to these directories.
    //
    // MUTATION: handing `SimCruxCxpServer` `cxpPathContainmentProvider` in
    // `cxpServerFactoryProvider` makes this red.
    expect(container.read(cxpWorkspaceStoreProvider).containment, same(rule));
    final server = container.read(cxpServerFactoryProvider)(
      selfIdentity: buildSimcruxPeerIdentity(processId: 1),
      port: 0,
    );
    expect(server.containment, same(kCxpOpenArtifactContainment));
    expect(server.containment.roots, isNull);
  });

  test('the producer is a no-op when the CXP server is not running', () async {
    final container = _makeContainer(
      serverRunning: false,
      workspaceDir: workspaceDir,
    );
    addTearDown(container.dispose);
    await container.read(cxpServerProvider.future);
    final ref = container.read(_refProbe);

    final designId = cxpDesignIdForPath(
      p.join(designInputDir, 'simcrux.yaml'),
    );
    await publishWaveformWorkspaceArtifact(
      ref,
      designId: designId,
      waveformPath: outputVcdPath,
    );

    final store = CxpWorkspaceStore(workspaceDirectory: workspaceDir);
    expect(
      store.resolveArtifact(designId, kCxpWaveformArtifactKind),
      isNull,
    );
    // Nothing should have been written to the workspace directory.
    expect(Directory(workspaceDir).existsSync(), isFalse);
  });
}

/// [posix] as an absolute path on this platform: unchanged on macOS and
/// Linux, and on the working drive on Windows. There a drive-less `/proj` is
/// rooted but not absolute, and the CXP floor refuses it before any root is
/// consulted.
String _abs(String posix) => p.normalize(p.absolute(posix));
