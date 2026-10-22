// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: the shared CXP layer is actually wired into the app.
//
// A unit test of the request handler passes whether or not `bootstrap()` ever
// installs it, and the shared cross-probe surfaces pass their own tests
// whether or not SimCrux calls them. This reads the syntax of `lib/` and
// asserts the calls exist: the root overrides that bind the lifecycle, and a
// real caller for each shared surface SimCrux adopts. Calls are read from a
// parsed tree, so a mention in a comment or a string does not count.

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every invocation in one file: `receiver.name(…)` as `receiver.name`, a bare
/// call as `name`, and a constructor call as the type name.
class _Calls extends RecursiveAstVisitor<void> {
  final Set<String> seen = <String>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    seen.add(
      target == null
          ? node.methodName.name
          : '${target.toSource()}.${node.methodName.name}',
    );
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    seen.add(node.constructorName.type.name.lexeme);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // `SimcruxCxpRequestHandler.new` as a tear-off.
    seen.add(node.toSource());
    super.visitPrefixedIdentifier(node);
  }
}

Set<String> _callsIn(String path) {
  final visitor = _Calls();
  parseString(
    content: File(path).readAsStringSync(),
    path: path,
    throwIfDiagnostics: false,
  ).unit.accept(visitor);
  return visitor.seen;
}

void main() {
  late final Map<String, Set<String>> callsByFile;

  setUpAll(() {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the package root');
    callsByFile = <String, Set<String>>{
      for (final entity in lib.listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            !entity.path.contains('${p.separator}generated${p.separator}'))
          entity.path: _callsIn(entity.path),
    };
  });

  bool libCalls(String name) =>
      callsByFile.values.any((calls) => calls.contains(name));

  group('bootstrap() binds the shared CXP lifecycle', () {
    test('lib/app.dart spreads the CXP overrides into the root scope', () {
      expect(
        callsByFile[p.join('lib', 'app.dart')],
        contains('simcruxCxpOverrides'),
      );
    });

    test('the overrides install the binding, the handler and the rest', () {
      final calls =
          callsByFile[p.join(
            'lib',
            'features',
            'remote',
            'simcrux_cxp_overrides.dart',
          )]!;
      expect(
        calls,
        containsAll(<String>[
          'cruxCxpProductBindingProvider.overrideWithValue',
          'cruxCxpLaunchSettingsProvider.overrideWithValue',
          'cruxCxpRequestHandlerProvider.overrideWith',
          'cruxCxpProductVersionProvider.overrideWith',
          'cruxCxpAttentionRequesterProvider.overrideWithValue',
          'crossProbeSendObserverProvider.overrideWith',
        ]),
      );
    });

    test('the handler override is SimCrux request handler', () {
      final source = File(
        p.join('lib', 'features', 'remote', 'simcrux_cxp_overrides.dart'),
      ).readAsStringSync();
      expect(
        source,
        contains('overrideWith(SimcruxCxpRequestHandler.new)'),
      );
    });

    test(
      'the app root starts the runtime and publishes the project opener',
      () {
        final calls = callsByFile[p.join('lib', 'app.dart')]!;
        // `innerRef..watch(x)` cascades read as bare `watch` calls: the
        // arguments are what matter.
        final source = File(p.join('lib', 'app.dart')).readAsStringSync();
        expect(source, contains('..watch(cruxCxpRuntimeProvider)'));
        expect(source, contains('..watch(cxpProjectOpenerPublisherProvider)'));
        expect(source, contains('..watch(notifySelectionEmitterProvider)'));
        expect(calls, contains('loadCruxCxpLaunchSettings'));
      },
    );

    // The active document (CXP §8.1) and the `project` artifact are
    // published from the workspace by one anchor the app root watches.
    test('the app root announces the active document and publishes each '
        'open project', () {
      final source = File(p.join('lib', 'app.dart')).readAsStringSync();
      expect(source, contains('..watch(simcruxCxpPresenceProvider)'));
      expect(
        callsByFile.values.any(
          (calls) => calls.any((c) => c.endsWith('.setActiveDocument')),
        ),
        isTrue,
      );
      expect(libCalls('publishProjectWorkspaceArtifact'), isTrue);
    });
  });

  group('the Formal and Flow producers have callers in lib/', () {
    for (final producer in const <String>[
      // The counterexample coordinate and its `formal.` keys.
      'formalStreamCoordinateFor',
      'formalHandoffMetadata',
      // "Show in NetCrux" and the per-partition hand-off.
      'formalShowInNetCruxSelection',
      'crossProbeToProduct',
      'eqyPartitionTracePath',
      // The worst-path row's selection, directed and broadcast.
      'flowPathCrossProbeSelection',
      'flowPathNotifySelection',
      'flowPathMenuEntries',
      'openFlowPathStatement',
      // The receive filters.
      'formalRowReads',
      'flowPathThroughRegister',
    ]) {
      test(producer, () {
        expect(
          libCalls(producer),
          isTrue,
          reason: '$producer exists but nothing in lib/ calls it.',
        );
      });
    }
  });

  group('every shared surface SimCrux adopts has a caller in lib/', () {
    for (final surface in const <String>[
      // The "Cross-probe to" submenu, from the row menu.
      'crossProbeMenuEntry',
      // The Cross-probe Selection command.
      'runCrossProbeSelection',
      // The docked panel, the Settings section and the Recent list.
      'CruxCrossProbePanel',
      'CruxCxpSettingsSection',
      'CruxRecentListSection',
      // Clear Recent Projects, from the action handler.
      'clearCruxRecentList',
      // The automatic selection broadcast.
      'broadcastCruxCxpSelection',
    ]) {
      test(surface, () {
        expect(
          libCalls(surface),
          isTrue,
          reason:
              '$surface is adopted from crux-shared but nothing in lib/ '
              'calls it.',
        );
      });
    }
  });

  group('the old per-product lifecycle is gone', () {
    test('no file under lib/ builds a CXP server of its own', () {
      for (final entry in callsByFile.entries) {
        expect(
          entry.value,
          isNot(contains('LocalCxpServer')),
          reason:
              '${entry.key} builds its own LocalCxpServer; the shared '
              'runtime owns the server.',
        );
      }
    });
  });
}
