// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';

void main() {
  group('PanelLayoutState', () {
    test('defaults match the engineering baseline', () {
      const s = PanelLayoutState();
      expect(s.testBrowserVisible, isTrue);
      expect(s.runDetailsVisible, isTrue);
      expect(s.logPanelVisible, isTrue);
      expect(
        s.testBrowserFraction,
        equals(PanelLayoutState.defaultLeftFraction),
      );
      expect(
        s.runDetailsFraction,
        equals(PanelLayoutState.defaultRightFraction),
      );
      expect(
        s.logPanelFraction,
        equals(PanelLayoutState.defaultBottomFraction),
      );
    });

    test('copyWith replaces only the specified fields', () {
      const base = PanelLayoutState();
      final updated = base.copyWith(
        testBrowserVisible: false,
        runDetailsFraction: 0.5,
      );
      expect(updated.testBrowserVisible, isFalse);
      expect(updated.runDetailsFraction, equals(0.5));
      // Unchanged fields retain their values.
      expect(updated.runDetailsVisible, isTrue);
      expect(updated.logPanelVisible, isTrue);
      expect(
        updated.testBrowserFraction,
        equals(PanelLayoutState.defaultLeftFraction),
      );
    });

    test('value-based equality and hashCode', () {
      const a = PanelLayoutState(
        testBrowserVisible: false,
        runDetailsFraction: 0.4,
      );
      const b = PanelLayoutState(
        testBrowserVisible: false,
        runDetailsFraction: 0.4,
      );
      const c = PanelLayoutState();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
