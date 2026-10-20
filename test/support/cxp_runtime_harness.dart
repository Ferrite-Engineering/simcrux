// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/remote/simcrux_cxp_binding.dart';

import 'answered_telemetry.dart';
import 'delete_manifest_dir.dart';

/// A temporary suite discovery directory, removed when the test ends.
Directory cxpTestManifestDirectory() {
  final dir = Directory.systemTemp.createTempSync('simcrux_cxp_');
  addTearDown(() => deleteManifestDir(dir));
  return dir;
}

/// Holds the [LocalCxpServer] the runtime built, for a test that needs to
/// look at the server itself (which subscriptions it has recorded).
class CapturedCxpServer {
  /// The server, once the runtime has started.
  LocalCxpServer? server;
}

/// A root container running SimCrux's real binding on the shared CXP
/// runtime, over real loopback sockets and the discovery directory
/// [manifestDirectory]: what the app builds at launch, with an OS-picked port.
///
/// The peer-list, event-log and unreachable-peer providers are kept
/// subscribed, as the toolbar badge and the panel keep them in the app (a
/// stream provider nothing listens to is paused). [capture] receives the
/// server the runtime builds. [serverContainment] replaces the rule the
/// server screens the wire with (the binding's floor), for a test that wants
/// a path the floor refuses, or one every path passes, to reach the handler.
/// [extra] overrides anything, last.
ProviderContainer simcruxCxpRuntimeContainer({
  required Directory manifestDirectory,
  bool enabled = true,
  bool broadcastSelection = true,
  CapturedCxpServer? capture,
  CxpPathContainment? serverContainment,
  List<Override> extra = const <Override>[],
}) {
  final container =
      ProviderContainer(
          overrides: <Override>[
            ...answeredTelemetryOverrides(),
            cruxCxpProductBindingProvider.overrideWithValue(kSimcruxCxpBinding),
            cruxCxpManifestDirectoryProvider.overrideWith(
              (_) async => manifestDirectory.path,
            ),
            cruxCxpTransportAvailableProvider.overrideWithValue(true),
            cruxCxpLaunchSettingsProvider.overrideWithValue(
              CruxCxpSettings(
                enabled: enabled,
                port: 0,
                broadcastSelection: broadcastSelection,
              ),
            ),
            if (capture != null || serverContainment != null)
              cruxCxpRuntimeProvider.overrideWith(
                (ref) async => enabled
                    ? await _startCustom(
                        ref,
                        manifestDirectory,
                        capture,
                        serverContainment,
                      )
                    : null,
              ),
            ...extra,
          ],
        )
        ..listen(cruxCxpPeersProvider, (_, _) {})
        ..listen(cruxCxpEventLogProvider, (_, _) {})
        ..listen(cruxCxpUnreachablePeersProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

Future<CruxCxpRuntime> _startCustom(
  Ref ref,
  Directory manifestDirectory,
  CapturedCxpServer? capture,
  CxpPathContainment? containment,
) async {
  final binding = ref.watch(cruxCxpProductBindingProvider);
  final runtime = CruxCxpRuntime(
    binding: binding,
    productVersion: 'test',
    manifestDirectory: manifestDirectory.path,
    port: 0,
    handler: () => ref.read(cruxCxpRequestHandlerProvider),
    onAttention: () => ref.read(cruxCxpAttentionRequesterProvider)?.call(),
    attentionEnabled: () => ref.read(cruxCxpSettingsProvider).requestAttention,
    serverFactory: (self) {
      final server = LocalCxpServer(
        selfIdentity: self,
        nameResolver: binding.nameResolver,
        containment: containment ?? binding.containment,
      );
      capture?.server = server;
      return server;
    },
  );
  ref.onDispose(() => unawaited(runtime.dispose()));
  await runtime.start();
  return runtime;
}

/// The running runtime of [container], failing the test when there is none.
Future<CruxCxpRuntime> runningCxpRuntime(ProviderContainer container) async {
  final runtime = await container.read(cruxCxpRuntimeProvider.future);
  expect(runtime, isNotNull, reason: 'expected the CXP runtime to be up');
  expect(runtime!.isAvailable, isTrue, reason: runtime.unavailableReason);
  return runtime;
}
