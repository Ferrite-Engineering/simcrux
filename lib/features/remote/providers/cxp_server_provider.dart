// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

/// Factory the lifecycle controller uses to construct the actual
/// [SimCruxCxpServer] instance.
///
/// Tests override this via [cxpServerFactoryProvider] to inject a
/// server that binds to port `0` (an OS-picked free port) or a stub
/// that captures every invocation.
typedef SimCruxCxpServerFactory =
    SimCruxCxpServer Function({
      required PeerIdentity selfIdentity,
      required int port,
    });

/// The factory the lifecycle controller uses to instantiate the
/// underlying server. Override in tests.
///
/// The default builds a production [SimCruxCxpServer] on the configured port,
/// carrying [kCxpOpenArtifactContainment] — the floor, not the directories
/// the user has opened. `LocalCxpServer` holds one rule for both requests it
/// screens, and a rooted one strips the path hint from a
/// `request_open_artifact` for a project SimCrux has never opened — the very
/// request that route exists to honour. Every editor launch keeps its roots:
/// the inbound request handler applies [cxpPathContainmentProvider] to the
/// path it is about to hand the editor, whatever the wire admitted.
final Provider<SimCruxCxpServerFactory> cxpServerFactoryProvider =
    Provider<SimCruxCxpServerFactory>(
      (ref) =>
          ({required selfIdentity, required port}) => SimCruxCxpServer(
            selfIdentity: selfIdentity,
            port: port,
            // Named although it is the server's default, so the decision is
            // visible where the server is built.
            // ignore: avoid_redundant_argument_values
            containment: kCxpOpenArtifactContainment,
          ),
    );

/// The active [SimCruxCxpServer] instance, or `null` when the server
/// has not been started (or has been stopped via the
/// `cxpServerEnabled` setting).
///
/// `AsyncNotifierProvider` so consumers can render a "starting…" state
/// during the brief bind window. Errors during start surface as
/// `AsyncError` so the cross-probe panel and Settings panel can show
/// the failure reason (typical: port already in use).
final AsyncNotifierProvider<CxpServerNotifier, SimCruxCxpServer?>
cxpServerProvider = AsyncNotifierProvider<CxpServerNotifier, SimCruxCxpServer?>(
  CxpServerNotifier.new,
);

/// Lifecycle controller for the SimCrux CXP server.
///
/// Watches [appSettingsProvider] for `cxpServerEnabled` / `cxpServerPort`
/// changes and restarts the server as needed. When the settings async
/// resolves with `cxpServerEnabled = false`, the underlying server is
/// stopped and the state is `AsyncData(null)`.
///
/// The notifier owns the [SimCruxCxpServer] lifetime — when the
/// provider is disposed (app shutdown), it stops the server cleanly.
class CxpServerNotifier extends AsyncNotifier<SimCruxCxpServer?> {
  /// The previous server's stop, while it is still in flight.
  Future<void>? _stopping;

  @override
  Future<SimCruxCxpServer?> build() async {
    // The two settings this server is made of, and nothing else. Watching the
    // whole settings object restarted the server on every settings write —
    // each project opened (recent projects), each panel toggled — which
    // dropped every connected peer and republished discovery under a new
    // peer id.
    final cxp = ref.watch(
      appSettingsProvider.select((async) {
        final settings = async.value;
        return settings == null
            ? null
            : (
                enabled: settings.cxpServerEnabled,
                port: settings.cxpServerPort,
              );
      }),
    );
    final factory = ref.read(cxpServerFactoryProvider);

    // A restart binds the port the last server may still hold: its stop
    // closes every peer before it closes the listener.
    final stopping = _stopping;
    if (stopping != null) {
      try {
        await stopping;
      } on Object {
        // A stop that failed has released what it could; bind regardless.
      }
    }

    if (cxp == null) {
      // Settings are still loading — no server yet.
      return null;
    }
    if (!cxp.enabled) {
      return null;
    }

    final server = factory(
      selfIdentity: buildSimcruxPeerIdentity(),
      port: cxp.port,
    );
    await server.start();

    // When the notifier is disposed (settings change → rebuild, or
    // app shutdown), stop the server cleanly so the port is released
    // and the inbound stream completes.
    ref.onDispose(() {
      final stop = server.stop();
      _stopping = stop;
      unawaited(
        stop.then<void>((_) {
          if (identical(_stopping, stop)) _stopping = null;
        }, onError: (Object _) {}),
      );
    });

    return server;
  }
}
