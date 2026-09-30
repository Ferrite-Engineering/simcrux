// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Structural guardrail against the "per-tab provider scope leak" bug class,
// scanning the open-core `lib/` with resolved-AST analysis (see
// `scope_leak_scanner.dart` for the model).
//
// SimCrux gives every open tab its own child `ProviderContainer`. In OPEN-CORE
// mode a provider is per-tab IFF it is overridden per tab in `simcruxTabOverrides`
// (`lib/features/workspace/providers/simcrux_tab_overrides.dart`). Widgets in a
// tab's subtree read providers from that child container.
//
// THE BUG CLASS:
// A provider whose body reads a per-tab provider (activeConfigProvider,
// resultStoreProvider, selectedTestIdProvider, …) via `ref.watch/read/listen`,
// but which is NOT itself made per-tab, is hoisted to the ROOT container and
// reads the DORMANT root-scope versions of those providers. The symptom is
// silent: no exception, just wrong output for every tab.
//
// WHY UNIT TESTS DON'T CATCH IT:
// Every provider unit test builds a single FLAT `ProviderContainer` with the
// per-tab dependency overridden inline. With no parent container there is no
// fallthrough, so the scoping defect is structurally invisible. This is why the
// guard is static and source-driven.
//
// PER-MODE VALIDATION (the SimCrux twist):
// The per-tab set differs between open-core and Pro modes — the Pro overlay
// replaces the per-tab factory with `proTabOverrides` and re-homes the dropped
// providers as root per-project delegates. This file validates the OPEN-CORE
// effective list over the open-core `lib/`; the Pro overlay's sibling test
// validates the Pro-mode effective list over both `lib/` trees.
//
// COST: resolving the tree costs a few seconds; the file carries a raised
// timeout and runs in the default suite.

@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'scope_leak_scanner.dart';

/// Providers that read per-tab state but are *intentionally* root-scoped, with
/// the reason they are exempt. Keep this list tiny and well-justified.
///
/// `notifySelectionEmitterProvider` is a root-hosted CXP outbound emitter that
/// tracks the ACTIVE tab and subscribes to that tab's container, re-attaching
/// on active-tab change. It additionally keeps a plain root `ref.listen` on
/// `selectedTestIdProvider` as the no-workspace fallback (headless tests,
/// pre-hydration startup): when no workspace is mounted there is no tab
/// container, so root IS the only scope and reading the root instance is
/// correct rather than a leak. The resolved-AST scanner sees this root read
/// through the emitter's helper method (a blind spot the previous regex scanner
/// could not reach); it is a genuine exemption, not a bug — removing it would
/// break the emitter for every headless caller.
const Map<String, String> allowlist = <String, String>{
  'notifySelectionEmitterProvider':
      'Root-hosted CXP outbound emitter. Subscribes to the ACTIVE tab '
      "container's selectedTestIdProvider (re-attaching on active-tab change); "
      'the root ref.listen is the no-workspace fallback only, correct when no '
      'tab container exists.',
};

void main() {
  late final ScopeGraph graph;

  setUpAll(() async {
    expect(
      Directory('lib').existsSync(),
      isTrue,
      reason: 'run this test from the package root (flutter test)',
    );
    graph = await ScopeGraph.resolve(<Directory>[Directory('lib')]);
  });

  test('resolution covered the tree', () {
    expect(
      graph.unresolved,
      isEmpty,
      reason:
          'these libraries did not resolve, so any provider they declare is '
          'invisible to the scan — run `flutter pub get`',
    );
    expect(
      graph.providers.length,
      greaterThan(80),
      reason:
          'sanity: far fewer providers than expected were registered, which '
          'means the registry, not the tree, changed',
    );
  });

  test(
    'no open-core provider reads per-tab state (directly or transitively) '
    'without being scoped per-tab in simcruxTabOverrides',
    () {
      final perTab = graph.overrideTargets(
        'lib/features/workspace/providers/simcrux_tab_overrides.dart',
        'simcruxTabOverrides',
      );
      expect(
        perTab.length,
        greaterThan(10),
        reason:
            'sanity: expected a sizeable per-tab seed set; did the override '
            'file shape or path change?',
      );
      expect(
        perTab.map(graph.nameOf),
        containsAll(<String>[
          'activeConfigProvider',
          'configLoadErrorProvider',
          'resultStoreProvider',
          'dashboardFilterProvider',
          'selectedTestIdProvider',
          'regressionRunnerProvider',
          'autoReloadNotifierProvider',
        ]),
      );

      final reach = taintClosure(graph.reads(), perTab);

      final violations = <_Leak>[];
      for (final entry in reach.entries) {
        if (perTab.contains(entry.key)) continue;
        final provider = graph.providers[entry.key]!;
        if (allowlist.containsKey(provider.name)) continue;
        violations.add(
          _Leak(
            provider.name,
            provider.path,
            <String>[for (final k in entry.value) graph.nameOf(k)],
            graph.viaFor(entry.value),
          ),
        );
      }

      if (violations.isNotEmpty) {
        violations.sort((a, b) => a.symbol.compareTo(b.symbol));
        final buf = StringBuffer()
          ..writeln('Per-tab provider scope leak(s) detected in open-core:')
          ..writeln();
        for (final v in violations) {
          buf
            ..writeln('  ${v.symbol}')
            ..writeln('    in ${v.path}')
            ..writeln('    per-tab reach: ${v.reach.join(' -> ')}');
          if (v.via.isNotEmpty) {
            buf.writeln('    read reached through: ${v.via.join(' > ')}');
          }
          buf.writeln();
        }
        buf
          ..writeln(
            'Each provider above is hoisted to the ROOT container and will '
            'read the dormant root-scope versions of those per-tab providers, '
            'silently producing wrong output in every tab.',
          )
          ..writeln(
            'Fix by adding `<symbol>.overrideWith(<fn|Notifier.new>)` to '
            '`simcruxTabOverrides`.',
          )
          ..writeln(
            'If the provider is intentionally root-scoped (an app-global '
            'service), add it to the allowlist with a reason.',
          );
        fail(buf.toString());
      }
    },
  );

  test('scope-leak allowlist entries still exist as providers', () {
    final known = graph.providers.values.map((i) => i.name).toSet();
    for (final symbol in allowlist.keys) {
      expect(
        known,
        contains(symbol),
        reason:
            'allowlisted provider `$symbol` no longer exists — remove or '
            'update its entry in the allowlist.',
      );
    }
  });

  test('taint closure propagates through intermediate providers', () {
    // Guards the guard: a two-hop chain (leaf -> middle -> per-tab seed) must
    // flag BOTH hops. A direct-reads-only scan flags `middle` and lets `leaf`
    // through.
    final reads = <String, List<ProviderRead>>{
      'middle': <ProviderRead>[ProviderRead('seed', const <String>[])],
      'leaf': <ProviderRead>[ProviderRead('middle', const <String>[])],
      'unrelated': <ProviderRead>[ProviderRead('root', const <String>[])],
      'self': <ProviderRead>[ProviderRead('self', const <String>[])],
    };

    final reach = taintClosure(reads, <String>{'seed'});

    expect(reach.keys, containsAll(<String>['middle', 'leaf']));
    expect(reach.keys, isNot(contains('unrelated')));
    expect(reach.keys, isNot(contains('self')));
    expect(
      reach['leaf'],
      <String>['leaf', 'middle', 'seed'],
      reason: 'the reported reach must name every hop down to the seed',
    );
  });

  group('reach analysis resolves indirect reads', () {
    late final ScopeGraph shapes;
    late final Map<String, List<ProviderRead>> reads;

    setUpAll(() async {
      shapes = await ScopeGraph.resolve(<Directory>[
        Directory('test/static/scope_leak_shapes'),
      ]);
      expect(shapes.unresolved, isEmpty);
      reads = shapes.reads();
    });

    Set<String> readsOf(String provider) {
      final key = shapes.keyOf(provider);
      expect(key, isNotNull, reason: '`$provider` was not registered');
      return <String>{
        for (final r in reads[key] ?? const <ProviderRead>[])
          shapes.nameOf(r.target),
      };
    }

    // A `Ref` captured on a field is still a `Ref`; matching on the receiver's
    // type rather than the identifier `ref` is what makes this visible.
    test('through a Ref stored on a field', () {
      expect(readsOf('storedRefProvider'), contains('seedProvider'));
    });

    test('through a helper object taking a Ref', () {
      expect(readsOf('helperObjectProvider'), contains('seedProvider'));
    });

    test('through an extension method on Ref', () {
      expect(readsOf('extensionProvider'), contains('seedProvider'));
    });

    // May-analysis: a run-time choice between providers contributes every
    // candidate, so the per-tab one cannot hide behind the branch.
    test('through a run-time provider selection', () {
      expect(readsOf('runtimeSelectedProvider'), contains('seedProvider'));
    });

    test('through a family applied to a run-time argument', () {
      expect(readsOf('familyArgProvider'), contains('familyProvider'));
    });

    test('and reports the helper chain it travelled', () {
      final key = shapes.keyOf('helperObjectProvider')!;
      final read = reads[key]!.firstWhere(
        (r) => shapes.nameOf(r.target) == 'seedProvider',
      );
      expect(read.via, isNotEmpty);
    });

    test('without over-reporting a provider that reads only root state', () {
      expect(readsOf('decoyProvider'), isNot(contains('seedProvider')));
    });

    test('and the closure reaches a two-hop chain', () {
      final seed = shapes.keyOf('seedProvider')!;
      final reach = taintClosure(reads, <String>{seed});
      expect(reach.keys, contains(shapes.keyOf('leafProvider')));
      expect(reach.keys, isNot(contains(shapes.keyOf('decoyProvider'))));
    });
  });
}

class _Leak {
  _Leak(this.symbol, this.path, this.reach, this.via);
  final String symbol;
  final String path;

  /// The reach chain from this provider down to the per-tab seed it depends on.
  final List<String> reach;

  /// The helper declarations the first hop's read was found behind, if any.
  final List<String> via;
}
