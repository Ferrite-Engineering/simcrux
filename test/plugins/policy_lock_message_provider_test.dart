// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/plugins/policy_lock_message_provider.dart';

void main() {
  test('open core supplies no sentence of its own', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(policyLockMessageProvider), isNull);
  });

  testWidgets('falls back to the shared English sentence', (tester) async {
    late String resolved;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          resolved = policyLockMessage(context, null);
          return const SizedBox();
        },
      ),
    );
    expect(resolved, kCruxPolicyLockNoteEn);
  });

  testWidgets('an override supplies the sentence', (tester) async {
    late String resolved;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          resolved = policyLockMessage(context, (_) => 'localized');
          return const SizedBox();
        },
      ),
    );
    expect(resolved, 'localized');
    expect(tester.takeException(), isNull);
  });
}
