// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('cxpServerProvider', () {
    test('starts a server bound to the configured port when enabled', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0, // tests bind to an OS-picked free port
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Force settings to resolve so the AsyncNotifier rebuilds and
      // sees enabled=true (the default).
      await container.read(appSettingsProvider.future);

      final server = await container.read(cxpServerProvider.future);
      expect(server, isNotNull);
      expect(server!.isRunning, isTrue);
      expect(server.boundPort, isNotNull);

      await container.read(cxpServerProvider.notifier).future;
    });

    test('returns null when cxpServerEnabled is false', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Disable BEFORE first read.
      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: false);

      final server = await container.read(cxpServerProvider.future);
      expect(server, isNull);
    });

    test('toggling cxpServerEnabled stops and restarts the server', () async {
      var built = 0;
      final container = ProviderContainer(
        overrides: <Override>[
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) {
              built++;
              return SimCruxCxpServer(
                selfIdentity: selfIdentity,
                port: 0,
              );
            },
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final server1 = await container.read(cxpServerProvider.future);
      expect(server1, isNotNull);
      expect(built, 1);

      // Disable → server stops.
      await container
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: false);
      final server2 = await container.read(cxpServerProvider.future);
      expect(server2, isNull);

      // Re-enable → new server constructed and started.
      await container
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: true);
      final server3 = await container.read(cxpServerProvider.future);
      expect(server3, isNotNull);
      expect(server3!.isRunning, isTrue);
      expect(built, 2);
    });

    test('a settings write that is not about CXP leaves the server '
        'running', () async {
      // The server watched the whole settings object, so opening a project
      // (which records it in the recent list) or toggling a panel restarted
      // it, dropping every connected peer.
      var built = 0;
      final container = ProviderContainer(
        overrides: <Override>[
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) {
              built++;
              return SimCruxCxpServer(selfIdentity: selfIdentity, port: 0);
            },
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final before = await container.read(cxpServerProvider.future);
      expect(before, isNotNull);

      await container
          .read(appSettingsProvider.notifier)
          .addRecentProject('/abs/simcrux.yaml');
      final after = await container.read(cxpServerProvider.future);

      expect(after, same(before));
      expect(after!.isRunning, isTrue);
      expect(built, 1);
    });

    test('handshake works against the started server', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final server = await container.read(cxpServerProvider.future);
      expect(server, isNotNull);

      final client = LocalCxpClient(
        selfIdentity: const PeerIdentity(
          peerId: 'test-handshake-client',
          productName: 'test',
          productVersion: '0.0.0',
        ),
      );
      await client.connect(
        host: '127.0.0.1',
        port: server!.boundPort!,
        token: cxpProcessAuthToken,
      );
      expect(client.isConnected, isTrue);
      expect(client.remotePeer?.productName, simcruxCxpProductName);
      await client.dispose();
    });
  });
}
