// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_arming_coordinator.dart';

void main() {
  group('AutoReloadArmingCoordinator', () {
    test('the first registrant for a key is the active armer', () {
      final coordinator = AutoReloadArmingCoordinator();
      final a = Object();
      final b = Object();
      expect(coordinator.register('p', a, () {}), isTrue);
      expect(coordinator.register('p', b, () {}), isFalse);
      expect(coordinator.isActive('p', a), isTrue);
      expect(coordinator.isActive('p', b), isFalse);
    });

    test('re-registering an active token does not reorder it', () {
      final coordinator = AutoReloadArmingCoordinator();
      final a = Object();
      final b = Object();
      coordinator
        ..register('p', a, () {})
        ..register('p', b, () {});
      // a registers again — must stay active, b must stay standby.
      expect(coordinator.register('p', a, () {}), isTrue);
      expect(coordinator.isActive('p', a), isTrue);
    });

    test('releasing the active armer promotes the next standby', () {
      final coordinator = AutoReloadArmingCoordinator();
      final a = Object();
      final b = Object();
      var bArmed = 0;
      coordinator
        ..register('p', a, () {})
        ..register('p', b, () => bArmed++)
        ..unregister('p', a);

      expect(
        bArmed,
        1,
        reason: 'the promoted standby is told to arm via its callback',
      );
      expect(coordinator.isActive('p', b), isTrue);
    });

    test('releasing a standby does not disturb the active armer', () {
      final coordinator = AutoReloadArmingCoordinator();
      final a = Object();
      final b = Object();
      var aArmed = 0;
      coordinator
        ..register('p', a, () => aArmed++)
        ..register('p', b, () {})
        ..unregister('p', b);
      expect(aArmed, 0, reason: 'the active armer is not re-armed');
      expect(coordinator.isActive('p', a), isTrue);
    });

    test('different project keys elect independent armers', () {
      final coordinator = AutoReloadArmingCoordinator();
      final a = Object();
      final b = Object();
      expect(coordinator.register('p1', a, () {}), isTrue);
      expect(
        coordinator.register('p2', b, () {}),
        isTrue,
        reason: 'a different project has its own election',
      );
    });

    test('releasing the last armer clears the key', () {
      final coordinator = AutoReloadArmingCoordinator();
      final a = Object();
      coordinator
        ..register('p', a, () {})
        ..unregister('p', a);
      // A fresh registrant for the same key is active again (key was
      // cleared, no stale standby ahead of it).
      final b = Object();
      expect(coordinator.register('p', b, () {}), isTrue);
    });
  });
}
