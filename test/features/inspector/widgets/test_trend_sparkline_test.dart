// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/theme/simcrux_theme.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/inspector/widgets/test_trend_sparkline.dart';

void main() {
  group('TestTrendSparkline', () {
    Widget host(List<TestStatus> statuses) => MaterialApp(
      theme: SimcruxTheme.dark(),
      home: Scaffold(
        body: Center(child: TestTrendSparkline(statuses: statuses)),
      ),
    );

    testWidgets('renders one cell per status', (tester) async {
      await tester.pumpWidget(
        host(const [
          TestStatus.pass,
          TestStatus.fail,
          TestStatus.timeout,
          TestStatus.skipped,
        ]),
      );
      expect(tester.takeException(), isNull);
      // Container count: each status renders one Container with a
      // BoxDecoration whose color we color-mapped.
      final containers = tester.widgetList<Container>(find.byType(Container));
      expect(containers.length, greaterThanOrEqualTo(4));
    });

    testWidgets('renders nothing visible for empty input', (tester) async {
      await tester.pumpWidget(host(const <TestStatus>[]));
      expect(tester.takeException(), isNull);
    });
  });
}
