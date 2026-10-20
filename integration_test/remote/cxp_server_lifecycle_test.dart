// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/remote/cxp_server_lifecycle_test.dart
//
// CXP server lifecycle (NetCrux-suite port): the live app's shared
// `cruxCxpRuntimeProvider` starts a REAL runtime (real TCP socket) when the
// CXP setting resolves enabled, stops it when the setting flips off, and
// restarts it when it flips back on. The test overrides only the launch
// settings (port 0, so an OS-picked port) and the discovery directory (a temp
// one) — the lifecycle, the settings watch, and the socket bind are all real.

import 'dart:io';

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../helpers/app_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'CXP server starts on boot, stops on disable, restarts on re-enable',
    (tester) async {
      final manifests = Directory.systemTemp.createTempSync('simcrux_cxp_it_');
      addTearDown(() {
        if (manifests.existsSync()) manifests.deleteSync(recursive: true);
      });
      await bootSimcrux(
        tester,
        extraOverrides: [
          // Port 0 → OS-picked free port, so the test never collides with
          // a real SimCrux (or a prior test run) holding 54325, and a temp
          // discovery directory, so it never advertises itself to the
          // machine's real peers. Everything else — the runtime, the
          // settings watch, the socket — is production code.
          cruxCxpLaunchSettingsProvider.overrideWithValue(
            const CruxCxpSettings(enabled: true, port: 0),
          ),
          cruxCxpManifestDirectoryProvider.overrideWith(
            (_) async => manifests.path,
          ),
        ],
      );
      final root = rootContainer(tester);

      // ── Boot: enabled-by-default settings start the server ───────────
      final started = await pumpUntil(
        tester,
        () => root.read(cruxCxpServerStatusProvider).running,
      );
      expect(started, isTrue, reason: 'server must start on boot');
      final first = root.read(cruxCxpRuntimeProvider).value!;
      final firstPort = first.boundPort;
      expect(firstPort, isNotNull, reason: 'started server must be bound');

      // The bound port accepts a real TCP connection.
      final probe = await Socket.connect('127.0.0.1', firstPort!);
      await probe.close();

      // ── Disable: the runtime stops and publishes null ────────────────
      await root
          .read(cruxCxpSettingsProvider.notifier)
          .setEnabled(enabled: false);
      final stopped = await pumpUntil(
        tester,
        () =>
            root.read(cruxCxpRuntimeProvider).value == null &&
            !first.isAvailable,
      );
      expect(
        stopped,
        isTrue,
        reason: 'disable must stop the server and publish null',
      );

      // ── Re-enable: a fresh server starts and binds again ─────────────
      await root
          .read(cruxCxpSettingsProvider.notifier)
          .setEnabled(enabled: true);
      final restarted = await pumpUntil(tester, () {
        final s = root.read(cruxCxpRuntimeProvider).value;
        return s != null && s.isAvailable && s.boundPort != null;
      });
      expect(restarted, isTrue, reason: 're-enable must restart the server');
      final second = root.read(cruxCxpRuntimeProvider).value!;
      expect(identical(second, first), isFalse);
      final probe2 = await Socket.connect('127.0.0.1', second.boundPort!);
      await probe2.close();

      expect(tester.takeException(), isNull);
    },
  );
}
