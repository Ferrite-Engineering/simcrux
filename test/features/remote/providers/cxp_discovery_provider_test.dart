// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_discovery.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../../../support/delete_manifest_dir.dart';
import '../../../support/poll_until.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('simcrux_cxp_disc_prov_');
  });

  tearDown(() => deleteManifestDir(tempDir));

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: <Override>[
        cxpServerFactoryProvider.overrideWithValue(
          ({required selfIdentity, required port}) => SimCruxCxpServer(
            selfIdentity: selfIdentity,
            port: 0,
          ),
        ),
        cxpDiscoveryFactoryProvider.overrideWithValue(
          () async => SimCruxCxpDiscoveryService(
            manifestDirectory: tempDir.path,
            scanInterval: const Duration(milliseconds: 200),
          ),
        ),
      ],
    );
  }

  group('cxpDiscoveryProvider', () {
    test('on a platform without CXP discovery (web) it resolves null and '
        'never resolves the manifest directory', () async {
      var factoryCalls = 0;
      final container = ProviderContainer(
        overrides: <Override>[
          cxpDiscoverySupportedProvider.overrideWithValue(false),
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
            ),
          ),
          cxpDiscoveryFactoryProvider.overrideWithValue(() async {
            factoryCalls++;
            return SimCruxCxpDiscoveryService(
              manifestDirectory: tempDir.path,
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      expect(await container.read(cxpDiscoveryProvider.future), isNull);
      expect(factoryCalls, 0);
    });

    test('is supported on the VM', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(cxpDiscoverySupportedProvider), isTrue);
    });

    test('starts the discovery service after the CXP server binds', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container.read(cxpServerProvider.future);
      final service = await container.read(cxpDiscoveryProvider.future);
      expect(service, isNotNull);
      expect(service!.isRunning, isTrue);

      // SimCrux's own manifest is on disk.
      final entries = tempDir.listSync().whereType<File>().toList();
      expect(
        entries.where((f) => f.path.contains('simcrux-')),
        hasLength(1),
      );
    });

    test('returns null when CXP is disabled', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: false);

      await container.read(cxpServerProvider.future);
      final service = await container.read(cxpDiscoveryProvider.future);
      expect(service, isNull);
    });
  });

  group('cxpPeersProvider', () {
    test(
      'starts empty and adds a peer when a foreign manifest appears',
      () async {
        final container = makeContainer();
        addTearDown(container.dispose);

        await container.read(appSettingsProvider.future);
        await container.read(cxpServerProvider.future);
        await container.read(cxpDiscoveryProvider.future);

        // Start with the SimCrux self-manifest present; foreign peers
        // are zero.
        var peers = container.read(cxpPeersProvider);
        final foreignNow = peers
            .where((m) => m.identity.productName != 'simcrux')
            .toList();
        expect(foreignNow, isEmpty);

        // Inject a wavecrux peer. Anchor its pid to THIS live process so the
        // crux_cxp 0.4.2 liveness prune (which reaps manifests whose pid reads
        // dead) keeps it discoverable for the test.
        final writer = CxpManifestWriter(manifestDirectory: tempDir.path);
        final wavecruxPeerId = 'wavecrux-$pid-5';
        final wavecruxId = PeerIdentity(
          peerId: wavecruxPeerId,
          productName: 'wavecrux',
          productVersion: '0.1.0',
        );
        await writer.write(
          identity: wavecruxId,
          host: '127.0.0.1',
          port: 54322,
        );

        // Wait for the watcher to pick it up and the notifier to
        // consume the event.
        List<CxpPeerManifest> foreignPeers() => container
            .read(cxpPeersProvider)
            .where((m) => m.identity.productName != 'simcrux')
            .toList();
        final picked = await pollUntil(() => foreignPeers().length == 1);
        expect(picked, isTrue, reason: 'expected the foreign peer to appear');
        peers = container.read(cxpPeersProvider);
        final foreign = foreignPeers();
        expect(foreign, hasLength(1));
        expect(foreign.single.identity.peerId, wavecruxPeerId);
      },
    );
  });

  group('cxpDialFailuresProvider', () {
    test('starts empty', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container.read(cxpServerProvider.future);
      await container.read(cxpDiscoveryProvider.future);

      expect(container.read(cxpDialFailuresProvider), isEmpty);
    });

    test(
      'surfaces a dial failure when a discovered peer cannot be reached',
      () async {
        final container = makeContainer();
        addTearDown(container.dispose);

        await container.read(appSettingsProvider.future);
        await container.read(cxpServerProvider.future);
        await container.read(cxpDiscoveryProvider.future);

        // Keep the provider active: Riverpod pauses unlistened providers,
        // which would stop its dial-failure subscription from updating.
        final sub = container.listen(cxpDialFailuresProvider, (_, _) {});
        addTearDown(sub.close);

        // Publish a foreign manifest pointing at a port nothing is
        // listening on. The connector dials it on discovery and the dial
        // is refused, producing a CxpDialFailure.
        final writer = CxpManifestWriter(manifestDirectory: tempDir.path);
        const wavecruxId = PeerIdentity(
          peerId: 'wavecrux-unreachable-9',
          productName: 'wavecrux',
          productVersion: '0.1.0',
        );
        await writer.write(
          identity: wavecruxId,
          host: '127.0.0.1',
          port: 1,
        );

        final surfaced = await pollUntil(
          () => container
              .read(cxpDialFailuresProvider)
              .any((f) => f.peerId == 'wavecrux-unreachable-9'),
        );
        expect(
          surfaced,
          isTrue,
          reason: 'expected the unreachable peer to appear in dial failures',
        );
        final failure = container
            .read(cxpDialFailuresProvider)
            .firstWhere((f) => f.peerId == 'wavecrux-unreachable-9');
        expect(failure.port, 1);
        expect(failure.consecutiveFailures, greaterThanOrEqualTo(1));
      },
    );
  });
}
