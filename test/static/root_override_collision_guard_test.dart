// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Guard: nothing that boots the app overrides a provider the root scope
// already overrides.
//
// `bootstrap()` builds one root container from its own overrides and the
// caller's `extraOverrides`. Riverpod refuses to build a container that
// overrides one provider twice, so an extra override of a provider in
// `simcruxCxpOverrides` is not "the later one wins": the app never boots. The
// integration suite runs weekly, so its CXP lifecycle test sat red for a week
// on exactly that before anything said so; this runs on every push.
//
// The integration tests are read as parsed syntax, so a provider named in a
// comment does not count.

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/remote/simcrux_cxp_overrides.dart';

/// The receiver of every `receiver.overrideWith…(…)` call in one file.
class _OverriddenProviders extends RecursiveAstVisitor<void> {
  final Set<String> seen = <String>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target != null && node.methodName.name.startsWith('overrideWith')) {
      seen.add(target.toSource());
    }
    super.visitMethodInvocation(node);
  }
}

Set<String> _overriddenIn(String path) {
  final visitor = _OverriddenProviders();
  parseString(
    content: File(path).readAsStringSync(),
    path: path,
    throwIfDiagnostics: false,
  ).unit.accept(visitor);
  return visitor.seen;
}

const _launch = CruxCxpSettings(enabled: true, port: 0);

void main() {
  test('the CXP root overrides name each provider once', () {
    final origins = simcruxCxpOverrides(
      launch: _launch,
    ).map((o) => o.origin).toList();
    expect(origins.toSet(), hasLength(origins.length));
  });

  test('the launch settings reach the container through `launch`', () {
    final container = ProviderContainer(
      overrides: simcruxCxpOverrides(launch: _launch),
    );
    addTearDown(container.dispose);
    expect(container.read(cruxCxpLaunchSettingsProvider), _launch);
  });

  // Why the guard below exists: an extra override is refused, not layered.
  // If Riverpod ever starts accepting it, this fails and the guard can relax.
  test('a second override of the launch settings is refused', () {
    expect(
      () => ProviderContainer(
        overrides: [
          ...simcruxCxpOverrides(launch: _launch),
          cruxCxpLaunchSettingsProvider.overrideWithValue(
            const CruxCxpSettings(enabled: false, port: 1),
          ),
        ],
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('no integration test overrides a provider the CXP root overrides '
      'already bind', () {
    final rootBound = _overriddenIn(
      p.join('lib', 'features', 'remote', 'simcrux_cxp_overrides.dart'),
    );
    expect(
      rootBound,
      contains('cruxCxpLaunchSettingsProvider'),
      reason: 'the scan must see the root overrides it guards',
    );

    final dir = Directory('integration_test');
    expect(dir.existsSync(), isTrue, reason: 'run from the package root');
    final offenders = <String>[
      for (final entity in dir.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          for (final name in _overriddenIn(entity.path).intersection(rootBound))
            '${entity.path}: $name',
    ]..sort();
    expect(
      offenders,
      isEmpty,
      reason:
          'bootstrap() already overrides these at the root, so an extra '
          'override stops the app from booting. Pass launch settings as '
          'bootSimcrux(cxpLaunchSettings: ...).',
    );
  });
}
