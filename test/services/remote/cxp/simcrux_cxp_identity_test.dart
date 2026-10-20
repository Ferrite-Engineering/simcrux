// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/features/remote/simcrux_cxp_binding.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_identity.dart';
import 'package:simcrux/services/remote/cxp/simcrux_name_resolver.dart';

void main() {
  group('SimCrux CXP identity', () {
    test('the product name is the lower-case build-info name', () {
      expect(simcruxCxpProductName, SimCruxBuildInfo.productName);
      expect(simcruxCxpProductName, 'simcrux');
    });

    test('the default port is the SimCrux slot, 54325', () {
      expect(defaultSimcruxCxpPort, 54325);
    });

    test('the announced version is the build version, not a second literal '
        'to keep in sync', () {
      expect(kSimcruxCxpAdvertisedVersion, SimCruxBuildInfo.productVersion);
    });

    test('announces the simcrux.debug capability', () {
      expect(kSimcruxCxpCapabilities, contains('simcrux.debug'));
    });
  });

  group('kSimcruxCxpBinding', () {
    test('carries the identity constants and the shared settings prefix', () {
      expect(kSimcruxCxpBinding.productName, simcruxCxpProductName);
      expect(kSimcruxCxpBinding.defaultPort, defaultSimcruxCxpPort);
      // The prefix the four CXP settings have always been saved under.
      expect(kSimcruxCxpBinding.prefsPrefix, 'simcrux.');
      expect(
        kSimcruxCxpBinding.settingsCodec.enabledKey,
        'simcrux.cxpServerEnabled',
      );
      expect(kSimcruxCxpBinding.settingsCodec.portKey, 'simcrux.cxpServerPort');
      expect(
        kSimcruxCxpBinding.settingsCodec.requestAttentionKey,
        'simcrux.requestAttentionOnCrossProbe',
      );
      expect(
        kSimcruxCxpBinding.settingsCodec.broadcastSelectionKey,
        'simcrux.broadcastSelectionOnCrossProbe',
      );
    });

    test('resolves names through SimCruxNameResolver', () {
      expect(kSimcruxCxpBinding.nameResolver, isA<SimCruxNameResolver>());
    });

    test('advertises the kinds SimCrux can show, and no others', () {
      expect(
        kSimcruxCxpBinding.advertisedCapabilities,
        containsAll(<String>[
          'simcrux.debug',
          'cxp.accepts:test',
          'cxp.accepts:source',
          'cxp.accepts:signal',
          'cxp.accepts:net',
          'cxp.accepts:port',
          'cxp.accepts:instance',
          'cxp.accepts:scope',
        ]),
      );
      for (final kind in <ElementKind>[
        ElementKind.marker,
        ElementKind.rule,
        ElementKind.breakpoint,
      ]) {
        expect(
          kSimcruxCxpBinding.advertisedCapabilities,
          isNot(contains('cxp.accepts:${kind.name}')),
          reason: 'the request handler declines ${kind.name}',
        );
      }
    });

    test('screens the wire with the floor, not the opened directories', () {
      // One rule screens both `request_open_source` and the hint of a
      // `request_open_artifact`; a rooted one strips the hint for a project
      // SimCrux has never opened.
      expect(kSimcruxCxpBinding.containment.roots, isNull);
    });
  });
}
