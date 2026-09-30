// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: no `setState` runs after an `await` in the same function
// without a `mounted` check in between. The Pro overlay carries its own copy.
//
// `use_build_context_synchronously` covers `context` across an async gap and
// nothing else, so `setState` after an `await` is the residue that lint
// leaves. The State can be disposed while the await is pending — the typical
// await is an OS file picker, a separate window that on Linux (a portal or
// zenity process) and on the web leaves the app live behind it, so the dialog
// that opened it can close first. `setState` on a disposed State throws in
// debug builds and dereferences a null element in release ones: an uncaught
// error, from a user doing nothing wrong.
//
// THE RULE. For every `setState(...)` call, find the last `await` (or
// `await for`) before it in the same function body. If there is one, a
// reference to `mounted` — `mounted`, `!mounted`, `context.mounted` — must
// appear between that await and the call, and not inside a block that always
// exits without reaching it: in `if (bad) { if (!mounted) return; return; }`
// the check guards only its own branch.
//
// WHAT IT DOES NOT SEE. The scan is syntactic and positional, a deliberate
// trade for speed and zero false alarms on this tree:
//  * an await whose block always exits (`if (kIsWeb) { await x; return; }`)
//    is known not to flow onward, except into a `finally`;
//  * a loop that awaits after its `setState` is not treated as reaching the
//    next iteration's `setState`;
//  * a callback registered with `.then(...)`, or a nested non-async function
//    called after an await, is its own body and is not followed.
// The planted samples at the bottom pin what is and is not caught.
//
// When this fails, add `if (!mounted) return;` after the await (or guard the
// call with `if (mounted)`). There is no allowlist: a site that looks safe
// today is one refactor away from not being.

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Source roots scanned.
const _roots = ['lib'];

/// A floor on the `setState` calls found, so a scan that silently stops
/// finding them fails instead of passing vacuously.
const _minimumCalls = 10;

void main() {
  test('no setState runs after an await without a mounted check', () {
    final findings = <String>[];
    var scannedCalls = 0;
    for (final root in _roots) {
      final dir = Directory(root);
      expect(dir.existsSync(), isTrue, reason: 'run from the package root');
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !_isHandWritten(entity.path)) continue;
        final source = entity.readAsStringSync();
        if (!source.contains('setState')) continue;
        final result = scanSetStateAfterAwait(source, path: entity.path);
        scannedCalls += result.calls;
        for (final line in result.unguardedLines) {
          findings.add('${p.normalize(entity.path)}:$line');
        }
      }
    }
    expect(
      scannedCalls,
      greaterThanOrEqualTo(_minimumCalls),
      reason:
          'sanity: far fewer setState calls than expected were scanned, so '
          'the scan, not the tree, changed',
    );
    expect(
      findings,
      isEmpty,
      reason:
          'setState is reachable after an await with no mounted check in '
          'between. The State may have been disposed while the await was '
          'pending; add `if (!mounted) return;` after the await:\n'
          '${findings.join('\n')}',
    );
  });

  group('the rule', () {
    int unguarded(String body) => scanSetStateAfterAwait(
      'class S { Future<void> f() async { $body } }',
    ).unguardedLines.length;

    test('catches setState after an await', () {
      expect(unguarded('await x(); setState(() {});'), 1);
      expect(unguarded('final a = await x(); if (a) setState(() {});'), 1);
      expect(unguarded('await x(); this.setState(() {});'), 1);
    });

    test('catches setState inside and after an await-for loop', () {
      expect(unguarded('await for (final e in s) { setState(() {}); }'), 1);
      expect(unguarded('await for (final e in s) {} setState(() {});'), 1);
    });

    test('catches setState in a catch or finally after an await', () {
      expect(
        unguarded('try { await x(); } catch (_) { setState(() {}); }'),
        1,
      );
      expect(
        unguarded('try { await x(); return; } finally { setState(() {}); }'),
        1,
      );
    });

    test('accepts a mounted check between the await and the call', () {
      expect(unguarded('await x(); if (!mounted) return; setState(() {});'), 0);
      expect(unguarded('await x(); if (mounted) setState(() {});'), 0);
      expect(
        unguarded('await x(); if (!context.mounted) return; setState(() {});'),
        0,
      );
      expect(
        unguarded(
          'try { await x(); } finally { if (mounted) setState(() {}); }',
        ),
        0,
      );
    });

    test('rejects a mounted check that comes before the await', () {
      expect(unguarded('if (!mounted) return; await x(); setState(() {});'), 1);
    });

    test('rejects a mounted check in a branch that always exits', () {
      expect(
        unguarded(
          'final t = await x(); '
          'if (t == null) { if (!mounted) return; snack(); return; } '
          'setState(() {});',
        ),
        1,
      );
      expect(
        unguarded(
          'final t = await x(); if (!mounted) return; '
          'if (t == null) { snack(); return; } setState(() {});',
        ),
        0,
      );
    });

    test('ignores setState before any await', () {
      expect(unguarded('setState(() {}); await x();'), 0);
    });

    test('ignores an await whose block always exits', () {
      expect(
        unguarded('if (w) { await x(); return; } setState(() {});'),
        0,
      );
      expect(
        unguarded(
          "if (w) { await x(); throw StateError('s'); } setState(() {});",
        ),
        0,
      );
    });

    test('scopes the search to the enclosing function body', () {
      expect(
        unguarded('await x(); void g() { setState(() {}); } g();'),
        0,
        reason: 'a nested synchronous function is its own body',
      );
      expect(
        unguarded(
          'final cb = () async { await x(); setState(() {}); }; cb();',
        ),
        1,
        reason: 'an async closure is checked on its own terms',
      );
    });
  });
}

bool _isHandWritten(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.endsWith('.dart') &&
      !normalized.endsWith('.g.dart') &&
      !normalized.endsWith('.freezed.dart') &&
      !normalized.contains('/l10n/generated/');
}

/// The outcome of scanning one compilation unit.
class SetStateScan {
  SetStateScan(this.calls, this.unguardedLines);

  /// How many `setState` calls were examined.
  final int calls;

  /// 1-based lines of the `setState` calls that break the rule.
  final List<int> unguardedLines;
}

/// Scans [source] for `setState` calls reachable after an `await` in the same
/// function body with no `mounted` reference in between.
SetStateScan scanSetStateAfterAwait(String source, {String path = 'x.dart'}) {
  final unit = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  ).unit;
  final collector = _Collector();
  unit.accept(collector);

  final lines = <int>[];
  for (final call in collector.setStates) {
    final body = _enclosingBody(call);
    if (body == null || !body.isAsynchronous) continue;
    final inFinally = _isInFinally(call);
    int? lastGap;
    for (final gap in collector.gaps) {
      if (_enclosingBody(gap.node) != body) continue;
      if (gap.end > call.offset) continue;
      if (!inFinally && _alwaysExitsBefore(gap.node, call)) continue;
      if (lastGap == null || gap.end > lastGap) lastGap = gap.end;
    }
    if (lastGap == null) continue;
    final from = lastGap;
    final guarded = collector.mounted.any(
      (m) =>
          m.offset >= from &&
          m.offset < call.offset &&
          !_alwaysExitsBefore(m, call),
    );
    if (!guarded) {
      lines.add(unit.lineInfo.getLocation(call.offset).lineNumber);
    }
  }
  return SetStateScan(collector.setStates.length, lines);
}

/// One asynchronous gap: an `await` expression, or an `await for` loop, whose
/// gap ends at the `await` keyword (every iteration resumes after it).
class _Gap {
  _Gap(this.node, this.end);

  final AstNode node;
  final int end;
}

class _Collector extends RecursiveAstVisitor<void> {
  final setStates = <MethodInvocation>[];
  final gaps = <_Gap>[];
  final mounted = <SimpleIdentifier>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'setState' &&
        (target == null || target is ThisExpression)) {
      setStates.add(node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    gaps.add(_Gap(node, node.end));
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    final keyword = node.awaitKeyword;
    if (keyword != null) gaps.add(_Gap(node, keyword.end));
    super.visitForStatement(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == 'mounted') mounted.add(node);
    super.visitSimpleIdentifier(node);
  }
}

FunctionBody? _enclosingBody(AstNode node) {
  for (var n = node.parent; n != null; n = n.parent) {
    if (n is FunctionBody) return n;
  }
  return null;
}

bool _isInFinally(AstNode node) {
  var child = node;
  for (var n = node.parent; n != null; n = n.parent) {
    if (n is FunctionBody) return false;
    if (n is TryStatement && identical(n.finallyBlock, child)) return true;
    child = n;
  }
  return false;
}

/// Whether [node] — an await, or a `mounted` check — sits in a block that ends
/// in `return` or `throw` and does not also contain [call]: control passing
/// through [node] leaves the function before it can reach the call.
bool _alwaysExitsBefore(AstNode node, AstNode call) {
  for (var n = node.parent; n != null; n = n.parent) {
    if (n is FunctionBody) return false;
    if (n is! Block) continue;
    if (n.offset <= call.offset && call.end <= n.end) return false;
    final statements = n.statements;
    if (statements.isEmpty) continue;
    final last = statements.last;
    if (last is ReturnStatement) return true;
    if (last is ExpressionStatement &&
        (last.expression is ThrowExpression ||
            last.expression is RethrowExpression)) {
      return true;
    }
  }
  return false;
}
