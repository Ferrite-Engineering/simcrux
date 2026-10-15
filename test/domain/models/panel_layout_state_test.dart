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
      // The Log panel starts collapsed and has no explicit choice recorded.
      expect(s.logPanelVisible, isFalse);
      expect(s.logPanelChoiceMade, isFalse);
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
      expect(updated.logPanelVisible, isFalse);
      expect(updated.logPanelChoiceMade, isFalse);
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

    test('the log panel choice takes part in equality and copyWith', () {
      const base = PanelLayoutState();
      final chosen = base.copyWith(logPanelChoiceMade: true);
      expect(chosen.logPanelChoiceMade, isTrue);
      expect(chosen.logPanelVisible, base.logPanelVisible);
      expect(chosen, isNot(equals(base)));
      expect(
        chosen,
        equals(const PanelLayoutState(logPanelChoiceMade: true)),
      );
      expect(
        chosen.hashCode,
        equals(const PanelLayoutState(logPanelChoiceMade: true).hashCode),
      );
      expect(chosen.copyWith(logPanelVisible: true).logPanelChoiceMade, isTrue);
    });
  });
}
