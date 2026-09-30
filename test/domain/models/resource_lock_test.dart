// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/resource_lock.dart';

void main() {
  group('ResourceLock', () {
    test('equality is name-based', () {
      const a = ResourceLock(name: 'fpga_board_0');
      const b = ResourceLock(name: 'fpga_board_0');
      const c = ResourceLock(name: 'fpga_board_1');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
