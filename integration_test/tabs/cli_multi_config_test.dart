// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/tabs/cli_multi_config_test.dart
//
// CLI multi-config open → tab structure. `simcrux a.simcrux.yaml
// b.simcrux.yaml c.simcrux.yaml` must open each config as a SEPARATE tab in
// the active pane (any number of positional configs is permitted; each one
// opens as a tab — see `lib/core/cli/cli_arg_parser.dart`
// and `lib/features/dashboard/widgets/cli_regression_bootstrapper.dart`).
//
// Each config is deliberately suite-less (`suites: {}`) so `ConfigLoader`
// fails fast and deterministically with "No suites found" — no real
// simulator process is ever spawned and the outcome does not depend on the
// host machine's toolchain. The assertion is on tab structure, not
// regression content. Ported from NetCrux's
// `integration_test/tabs/cli_multi_file_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../helpers/app_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'three positional configs on the CLI open three tabs',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('simcrux_cli_multi_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final paths = <String>[];
      for (final name in const ['a', 'b', 'c']) {
        final f = File('${dir.path}/$name.simcrux.yaml')
          ..writeAsStringSync("version: '1'\nsuites: {}\n");
        paths.add(f.path);
      }

      await bootSimcrux(tester, args: paths);

      // The CLI bootstrapper opens one tab per positional config after the
      // first frame.
      await pumpUntil(
        tester,
        () => tabCount(tester) == 3,
        timeout: const Duration(seconds: 20),
      );
      expect(
        tabCount(tester),
        3,
        reason: 'each CLI-supplied config opens its own tab',
      );

      // Each tab references exactly one of the three config files.
      final opened = liveWorkspace(
        tester,
      ).tabs.map((t) => t.payload.configPath).toSet();
      expect(opened, containsAll(paths));

      // Each tab mounts its content and kicks off `startFromConfigPath`.
      // With no suites declared, the loader raises "No suites found"
      // synchronously; drain a settle window here so that handled failure
      // completes inside the test body rather than after it returns.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      tester.takeException();
    },
  );
}
