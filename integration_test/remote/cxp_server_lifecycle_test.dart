// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/remote/cxp_server_lifecycle_test.dart
//
// CXP server lifecycle (NetCrux-suite port): the live app's
// `CxpServerNotifier` starts a REAL `SimCruxCxpServer` (real TCP socket)
// when `cxpServerEnabled` resolves true, stops it when the setting flips
// off, and restarts it when it flips back on. The test overrides only the
// server *factory* so the server binds port 0 (OS-picked) instead of the
// production 54325 — the notifier lifecycle, the settings watch, and the
// socket bind are all real.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../helpers/app_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    'CXP server starts on boot, stops on disable, restarts on re-enable',
    (tester) async {
      await bootSimcrux(
        tester,
        extraOverrides: [
          // Port 0 → OS-picked free port, so the test never collides with
          // a real SimCrux (or a prior test run) holding 54325. Everything
          // else — notifier, settings watch, socket — is production code.
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) =>
                SimCruxCxpServer(selfIdentity: selfIdentity, port: 0),
          ),
        ],
      );
      final root = rootContainer(tester);

      // ── Boot: enabled-by-default settings start the server ───────────
      final started = await pumpUntil(
        tester,
        () => root.read(cxpServerProvider).value?.isRunning ?? false,
      );
      expect(started, isTrue, reason: 'server must start on boot');
      final first = root.read(cxpServerProvider).value!;
      final firstPort = first.boundPort;
      expect(firstPort, isNotNull, reason: 'started server must be bound');

      // The bound port accepts a real TCP connection.
      final probe = await Socket.connect('127.0.0.1', firstPort!);
      await probe.close();

      // ── Disable: the notifier stops the server and publishes null ────
      await root
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: false);
      final stopped = await pumpUntil(
        tester,
        () => root.read(cxpServerProvider).value == null && !first.isRunning,
      );
      expect(
        stopped,
        isTrue,
        reason: 'disable must stop the server and publish null',
      );

      // ── Re-enable: a fresh server starts and binds again ─────────────
      await root
          .read(appSettingsProvider.notifier)
          .updateCxpServerEnabled(enabled: true);
      final restarted = await pumpUntil(tester, () {
        final s = root.read(cxpServerProvider).value;
        return s != null && s.isRunning && s.boundPort != null;
      });
      expect(restarted, isTrue, reason: 're-enable must restart the server');
      final second = root.read(cxpServerProvider).value!;
      expect(identical(second, first), isFalse);
      final probe2 = await Socket.connect('127.0.0.1', second.boundPort!);
      await probe2.close();

      expect(tester.takeException(), isNull);
    },
  );
}
