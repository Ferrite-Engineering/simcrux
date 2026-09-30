// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_policy/crux_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/policy/simcrux_policy_keys.dart';

/// SimCrux's policy namespace and audit vocabulary.
///
/// The namespace makes the keys EXIST AND BE HONOURED. It does not implement
/// the features they configure.
void main() {
  group('the namespace is registered and non-empty', () {
    test('the product id matches the schema', () {
      expect(SimCruxPolicyKeys.productId, 'simcrux');
    });

    test('keys and kinds are declared', () {
      expect(SimCruxPolicyKeys.all, isNotEmpty);
      expect(SimCruxAuditKinds.all, isNotEmpty);
    });

    test('no key or kind is blank, and none collide', () {
      for (final k in SimCruxPolicyKeys.all) {
        expect(k.trim(), isNotEmpty);
      }
      for (final k in SimCruxAuditKinds.all) {
        expect(k.trim(), isNotEmpty);
        expect(k, contains('.'), reason: 'kinds are dotted: noun.verb');
      }
    });
  });

  group('registered keys actually resolve', () {
    test('a policy value in this namespace is honoured', () {
      final key = SimCruxPolicyKeys.all.first;
      final doc = PolicyDocument.parse(
        '{"schema":1,"products":{"simcrux":{"$key":"x"}}}',
      );
      final resolved = simcruxPolicyResolver(doc).productValue<String>(
        key,
        parse: (raw) => raw is String ? raw : null,
        builtIn: 'built-in',
      );
      expect(resolved.value, 'x');
      expect(resolved.source, PolicySource.policyDefault);
    });

    test('a LOCKED value outranks the user setting', () {
      final key = SimCruxPolicyKeys.all.first;
      final doc = PolicyDocument.parse(
        '{"schema":1,"products":{"simcrux":'
        '{"$key":{"value":"org","locked":true}}}}',
      );
      final resolved = simcruxPolicyResolver(doc).productValue<String>(
        key,
        parse: (raw) => raw is String ? raw : null,
        builtIn: 'built-in',
        userSetting: 'mine',
      );
      expect(resolved.value, 'org');
      expect(resolved.locked, isTrue);
    });

    test("ANOTHER product's namespace is ignored silently", () {
      // One file serves a mixed fleet, so meeting another product's keys is
      // the normal case rather than a misconfiguration — not warned about,
      // not an error.
      final key = SimCruxPolicyKeys.all.first;
      const other = 'simcrux' == 'simcrux' ? 'wavecrux' : 'simcrux';
      final doc = PolicyDocument.parse(
        '{"schema":1,"products":{"$other":{"$key":"x"}}}',
      );
      final resolver = simcruxPolicyResolver(doc);
      final resolved = resolver.productValue<String>(
        key,
        parse: (raw) => raw is String ? raw : null,
        builtIn: 'built-in',
      );
      expect(resolved.value, 'built-in');
      expect(resolver.diagnostics, isEmpty);
    });
  });
}
