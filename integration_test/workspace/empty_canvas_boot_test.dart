// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/workspace/empty_canvas_boot_test.dart
//
// Cold-boot smoke + empty-canvas verification. Launches the real app via
// `bootstrap` with no args and asserts the workspace hydrates to zero tabs and
// the empty-canvas content renders. Also the harness smoke test.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/features/workspace/widgets/empty_canvas_content.dart';

import '../helpers/app_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'cold boot with no args lands on the empty-canvas state',
    (tester) async {
      await bootSimcrux(tester);

      expect(tabCount(tester), 0, reason: 'fresh boot opens no tabs');
      expect(find.byType(EmptyCanvasContent), findsOneWidget);
      expect(find.text('No recent configs yet.'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );
}
