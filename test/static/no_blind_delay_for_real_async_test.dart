// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards against the hang shape, not merely a flake shape.
///
/// `tester.runAsync(() => Future.delayed(someFixedDuration))` means "sleep on
/// the real event loop and hope the real async work I did not start finishes
/// inside this window". It fails in the worst possible way. `runAsync`
/// suspends the test body, so while it is running nothing calls `pump()`, so
/// the fake-async zone's microtask queue is never drained. Any future whose
/// completion depends on a continuation queued in that zone — an
/// `AsyncNotifier.build` awaiting file I/O, say — therefore cannot complete
/// inside a later `runAsync`. If the fixed sleep was long enough, the test
/// passes; if it was not, the test does not go red, it **deadlocks**, and
/// nothing bounds it but the default test timeout. That is a ten-minute burn
/// per occurrence at ten-times billing on the macOS runners
/// (`test/flutter_test_config.dart` now caps it at two minutes, which bounds
/// the cost but does not remove the cause).
///
/// The fix is always one of two shapes, never a longer sleep:
///
/// * `runAsync` the real-async **operation itself**, so the awaited future is
///   both created and completed on the real event loop —
///   `await tester.runAsync(() => notifier.openTab(...))`, as
///   `workspace_screen_test.dart` and `simcrux_action_handlers_test.dart` do.
/// * Or remove the real event loop from the test: fake the I/O seam so every
///   future is microtask-bound and a plain `pumpAndSettle()` is exact, as
///   `cli_regression_bootstrapper_test.dart` does — the case where the widget
///   under test starts the async work itself, leaving nothing for the test to
///   wrap.
///
/// A third shape is permitted and not flagged: a **bounded poll loop** that
/// alternates a short `runAsync` slice with a `pump()` and exits on a counter
/// or a condition. That is the honest form of "I cannot wrap this operation" —
/// it drains the fake-async zone between slices and terminates on its own
/// bound rather than on the test timeout. See [_insideBoundedLoop].
///
/// MUTATION: adding `await tester.runAsync(() => Future.delayed(const
/// Duration(milliseconds: 50)));` to any test file makes this guard red.
void main() {
  test('no test waits a fixed duration inside runAsync', () {
    final roots = [
      Directory('test'),
      Directory('integration_test'),
    ].where((d) => d.existsSync()).toList();
    expect(
      roots,
      isNotEmpty,
      reason: 'run from the package root (cwd = simcrux/)',
    );

    final offenders = <String>[];
    for (final root in roots) {
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Don't flag this guard's own description of the shape.
        if (entity.path.endsWith('no_blind_delay_for_real_async_test.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        for (final call in _runAsyncArguments(source)) {
          if (!_isBareDelay(call.argument)) continue;
          if (_insideBoundedLoop(source, call.offset)) continue;
          if (_hasWaiver(source, call.offset)) continue;
          final line =
              '\n'.allMatches(source.substring(0, call.offset)).length + 1;
          offenders.add('${entity.path}:$line');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'runAsync must wrap the real-async operation itself, or the I/O '
          'seam must be faked — a fixed sleep hoping the work lands is a '
          'deadlock waiting to happen. Found:\n${offenders.join('\n')}',
    );
  });

  /// The waiver hatch has to stay expensive to use, or it stops meaning
  /// anything. A marker with no reason — or with "see above" — would let the
  /// shape back in one file at a time.
  test('every blind-delay waiver carries a real reason', () {
    final roots = [
      Directory('test'),
      Directory('integration_test'),
    ].where((d) => d.existsSync());

    final thin = <String>[];
    for (final root in roots) {
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('no_blind_delay_for_real_async_test.dart')) {
          continue;
        }
        final lines = entity.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final reason = _waiverReason(lines[i]);
          if (reason == null) continue;
          if (reason.length < 30) thin.add('${entity.path}:${i + 1}');
        }
      }
    }

    expect(
      thin,
      isEmpty,
      reason:
          'A blind-delay waiver needs a reason that says why no positive '
          'signal exists to poll for — not a marker. Found:\n'
          '${thin.join('\n')}',
    );
  });
}

/// Whether the `runAsync` at [offset] sits inside a bounded poll loop.
///
/// This is the distinction SimCrux's original could not draw, because SimCrux
/// happens not to use the pattern. Two shapes look identical to a regex and
/// are opposites in practice:
///
/// * `await tester.runAsync(() => Future.delayed(300ms)); await tester.pump();`
///   — a single fixed sleep hoping unstarted real-async work lands inside the
///   window. On a loaded runner it does not, and the assertion after it fails
///   with a message about the wrong thing.
/// * `for (var i = 0; i < 60 && !condition; i++) { runAsync(delay); pump(); }`
///   — a poll with a bound. It drains the fake-async zone between slices, it
///   finishes as soon as the work does, and if the work never lands it exits
///   on the counter instead of waiting out the default test timeout.
///
/// The second is the *fix* for the first, so flagging it would push people
/// back toward the shape this guard exists to remove.
///
/// Detection walks backwards from the call to the `{` that opens its enclosing
/// block, then reads the text immediately before that brace. A loop with no
/// braces around a single statement is not recognised and stays flagged —
/// deliberately, since a one-statement sleep loop with no condition in the
/// body is not polling for anything.
/// Whether the call at [offset] carries an explicit, justified waiver.
///
/// Not every wait can be replaced by a poll. Proving a **negative** — "the
/// tier gate short-circuits, so no banner ever appears" — has no positive
/// signal to wait for, and a poll for something that never arrives is just the
/// timeout with extra steps. Those waits are legitimate and rare.
///
/// The escape hatch is deliberately loud rather than silent: a
/// `// blind-delay-ok: <reason>` marker anywhere in the comment block directly
/// above the call, with a reason long enough to be a sentence. A companion test below
/// fails on an empty or token reason, so the hatch cannot decay into a
/// copy-pasted marker that means nothing.
bool _hasWaiver(String source, int offset) {
  // Walk the contiguous comment block immediately above the call, rather than
  // a fixed number of lines. The reason has to be long enough to be a
  // sentence, so it usually wraps, and a fixed lookback silently stops seeing
  // the marker as soon as somebody explains themselves properly.
  final before = source.substring(0, offset).split('\n');
  for (var i = before.length - 2; i >= 0; i--) {
    final line = before[i].trim();
    if (line.isEmpty) continue;
    if (!line.startsWith('//')) break;
    if (_waiverReason(line) != null) return true;
  }
  return false;
}

/// The reason text of a waiver comment on [line], or null if it has none.
String? _waiverReason(String line) {
  final match = RegExp(r'//\s*blind-delay-ok:\s*(.*)$').firstMatch(line);
  return match?.group(1)?.trim();
}

bool _insideBoundedLoop(String source, int offset) {
  var depth = 0;
  var i = offset;
  while (i > 0) {
    i--;
    switch (source[i]) {
      case '}':
        depth++;
      case '{':
        if (depth == 0) return _openerIsLoopHeader(source, i);
        depth--;
    }
  }
  return false;
}

/// Whether the block opening at [braceIndex] is a `for` / `while` body.
///
/// Walks the header backwards with balanced parentheses rather than matching
/// it with a regex: a real loop header contains call parentheses of its own
/// (`i < 100 && find.byType(SnackBar).evaluate().isEmpty`), and a `[^)]*`
/// pattern stops at the first inner `)` and silently decides the block is not
/// a loop. That failure mode is invisible — the guard simply keeps flagging a
/// shape it was supposed to permit — which is why this is spelled out.
bool _openerIsLoopHeader(String source, int braceIndex) {
  var i = braceIndex - 1;
  while (i >= 0 && _isSpace(source[i])) {
    i--;
  }
  if (i < 0 || source[i] != ')') return false;

  var depth = 0;
  for (; i >= 0; i--) {
    if (source[i] == ')') {
      depth++;
    } else if (source[i] == '(') {
      depth--;
      if (depth == 0) break;
    }
  }
  if (i < 0) return false;

  final header = source.substring(i + 1, braceIndex);
  // `while (true)` exits only through its body, so it carries the same
  // never-terminates risk as a bare sleep and stays flagged.
  if (RegExp(r'^\s*true\s*\)?\s*$').hasMatch(header.split(';').first)) {
    return false;
  }

  var j = i - 1;
  while (j >= 0 && _isSpace(source[j])) {
    j--;
  }
  final end = j + 1;
  while (j >= 0 && RegExp('[A-Za-z]').hasMatch(source[j])) {
    j--;
  }
  final keyword = source.substring(j + 1, end);
  return keyword == 'for' || keyword == 'while';
}

bool _isSpace(String c) => c == ' ' || c == '\n' || c == '\t' || c == '\r';

/// One `runAsync(...)` call site: the byte offset of the call and the raw
/// source text of its single argument.
typedef _RunAsyncCall = ({int offset, String argument});

/// Extracts every `runAsync(<arg>)` argument from [source] by walking
/// balanced parentheses, so a nested call in the argument does not truncate
/// it the way a regex would.
Iterable<_RunAsyncCall> _runAsyncArguments(String source) sync* {
  for (final match in RegExp(r'\brunAsync\s*\(').allMatches(source)) {
    var depth = 1;
    var i = match.end;
    while (i < source.length && depth > 0) {
      switch (source[i]) {
        case '(':
          depth++;
        case ')':
          depth--;
      }
      i++;
    }
    if (depth != 0) continue; // unbalanced; not our problem to diagnose
    yield (offset: match.start, argument: source.substring(match.end, i - 1));
  }
}

/// Whether [argument] is a closure whose entire body is a `Future.delayed`.
///
/// Matches both `() => Future<void>.delayed(d)` and
/// `() async { await Future.delayed(d); }`. A closure that delays and then
/// does real work is a different (defensible) shape and is not flagged.
bool _isBareDelay(String argument) {
  final normalized = argument
      .replaceAll(RegExp('//[^\n]*'), '')
      .replaceAll(RegExp(r'\s+'), '');
  return RegExp(
    // `[^;]*` for the duration argument, not `.*`: a body that delays and
    // then goes on to await something real ends in a second statement, and
    // the statement separator is what keeps it out of this match.
    r'^\(\)(?:async)?(?:=>|\{)(?:await)?'
    r'Future(?:<[^>]*>)?\.delayed\([^;]*\);?\}?,?$',
  ).hasMatch(normalized);
}
