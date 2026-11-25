// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/remote/simcrux_cxp_overrides.dart';

/// Records what the CXP runtime asked the platform for.
class _RecordingHandoff implements WindowForegroundHandoff {
  final List<int> yielded = <int>[];
  final List<String> taken = <String>[];

  @override
  Future<String?> yieldForegroundTo(int processId) async {
    yielded.add(processId);
    return 'token-$processId';
  }

  @override
  Future<bool> takeForeground(String activationToken) async {
    taken.add(activationToken);
    return true;
  }
}

/// Pumps a scope with the CXP overrides `bootstrap()` spreads into the root
/// scope and returns what it answers for [cruxCxpForegroundHandoffProvider].
Future<CruxCxpForegroundHandoff?> _rootScopeHandoff(WidgetTester tester) async {
  CruxCxpForegroundHandoff? seen;
  await tester.pumpWidget(
    ProviderScope(
      overrides: simcruxCxpOverrides(
        launch: const CruxCxpSettings(enabled: false, port: 0),
      ),
      child: Consumer(
        builder: (context, ref, _) {
          seen = ref.watch(cruxCxpForegroundHandoffProvider);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return seen;
}

void main() {
  late WindowForegroundHandoff original;

  setUp(() => original = windowForegroundHandoff);
  tearDown(() => windowForegroundHandoff = original);

  testWidgets(
    'the root scope wires the foreground hand-off on a desktop',
    (tester) async {
      final recording = _RecordingHandoff();
      windowForegroundHandoff = recording;

      final handoff = await _rootScopeHandoff(tester);

      expect(
        handoff,
        isNotNull,
        reason:
            'Without the override a directed cross-probe leaves the target '
            'behind and Settings hides the bring-forward switch.',
      );
      // Both halves reach crux_window_chrome's hand-off, the one the runner's
      // crux_window_chrome/foreground channel answers.
      expect(await handoff!.yieldTo(4242), 'token-4242');
      expect(await handoff.take('token-4242'), isTrue);
      expect(recording.yielded, <int>[4242]);
      expect(recording.taken, <String>['token-4242']);
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets(
    'no hand-off off the desktop, where CXP does not run',
    (tester) async {
      expect(await _rootScopeHandoff(tester), isNull);
    },
    variant: TargetPlatformVariant.mobile(),
  );
}
