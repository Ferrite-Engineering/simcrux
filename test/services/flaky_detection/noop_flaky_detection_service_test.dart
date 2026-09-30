// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/flakiness_config.dart';
import 'package:simcrux/services/flaky_detection/flaky_detection_service_provider.dart';
import 'package:simcrux/services/flaky_detection/noop_flaky_detection_service.dart';

void main() {
  group('NoopFlakyDetectionService', () {
    const service = NoopFlakyDetectionService();
    const config = FlakinessConfig();

    test('scoreFor always returns null', () async {
      expect(
        await service.scoreFor(testId: 'cpu.alu_test', config: config),
        isNull,
      );
    });

    test('scoresForAll emits no events', () async {
      final scores = await service.scoresForAll(config: config).toList();
      expect(scores, isEmpty);
    });

    test('currentConfig returns the default FlakinessConfig', () {
      expect(service.currentConfig, const FlakinessConfig());
    });
  });

  group('flakyDetectionServiceProvider', () {
    test('open-core default is the NoopFlakyDetectionService', () {
      // The Pro overlay overrides this provider in proOverrides; open-core
      // ships the noop so callers (the dashboard's flaky badge render
      // path, for example) can unconditionally watch the provider without
      // null-checking or licence-tier branching.
      expect(flakyDetectionServiceProvider, isNotNull);
    });
  });
}
