// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Source-driven scanner backing `lifecycle_ref_use_test.dart`: detects
// `Ref` use inside Riverpod provider lifecycle callbacks.
//
// THE BUG CLASS
// Riverpod guards every lifecycle callback with a callback-stack
// assertion (`riverpod/src/core/ref.dart`: `_debugCallbackStack == 0`,
// "Cannot use Ref or modify other providers inside life-cycles/
// selectors"). Touching `ref` from inside one throws. The throw
// propagates out of the offending statement and ABORTS THE REST OF THE
// CALLBACK, so every teardown step written below the offending line
// silently does not happen: subscriptions stay attached, buffers stay
// unflushed, registries keep stale entries. Nothing surfaces to the
// user and no unit test that builds a flat container ever disposes the
// provider hard enough to notice.
//
// WHICH CALLBACKS (verified empirically against the flutter_riverpod
// version pinned in `pubspec.yaml`, not assumed):
//
//   ref.onDispose          throws  (callback-stack assertion)
//   ref.onCancel           throws  (callback-stack assertion)
//   ref.onResume           throws  (callback-stack assertion)
//   ref.onAddListener      throws  (callback-stack assertion)
//   ref.onRemoveListener   throws  (callback-stack assertion)
//
// The guard is uniform: it keys off the callback stack, not off
// provider liveness, so a hook that runs while the provider is still
// perfectly alive (`onCancel`, `onResume`, the listener hooks) is just
// as unsafe as a dispose hook. All five are therefore scanned.
//
// An `async` callback that reaches for `ref` AFTER an `await` is worse,
// not better: the callback stack has unwound by then, so the assertion
// no longer fires and the read instead hits "Cannot use the Ref of
// <provider> after it has been disposed" — a plain error that survives
// into release builds where assertions are compiled out.
//
// THE THREE SHAPES
//   1. direct       — `ref.read(...)` written in the callback body.
//   2. helper       — the callback calls a method that itself uses
//                     `ref`. This is the shape of the motivating bug
//                     (`_releaseActiveRunToken`), so a scanner that
//                     only caught shape 1 would have missed it.
//   3. tear-off     — the callback IS a stored closure or a method
//                     reference that uses `ref`
//                     (`ref.onDispose(_teardown)`).
// Shapes 2 and 3 resolve transitively through the enclosing class and
// the file's top-level functions to a fixed point.
//
// WHAT IS DELIBERATELY NOT FLAGGED
//   - `ref` use in a callback that merely *registers* during a
//     lifecycle hook but *runs* later (a stream listener attached from
//     the hook). The callback stack is unwound by the time it fires.
//   - `ref` use inside `StreamSubscription`/`Timer` callbacks
//     registered while the provider is alive. Verified safe.
//   - `WidgetRef` use in `ConsumerState.dispose`. A different type with
//     different rules; the `ref.on*` anchor never matches there.
//
// THE FIX the failure message prescribes: resolve the value or service
// EAGERLY, before registering the hook, and close over the result.

import 'dart:io';

/// A single detected use of `Ref` inside a lifecycle callback.
class LifecycleRefUse {
  /// Creates a violation record.
  LifecycleRefUse({
    required this.path,
    required this.line,
    required this.hook,
    required this.shape,
    required this.detail,
  });

  /// Declaring file.
  final String path;

  /// 1-based line of the hook registration.
  final int line;

  /// The lifecycle hook, e.g. `onDispose`.
  final String hook;

  /// Which of the three shapes matched.
  final String shape;

  /// Human-readable evidence: the offending expression, or the helper
  /// chain that reaches `ref`.
  final String detail;
}

/// The lifecycle hooks that run inside Riverpod's callback stack. Every
/// one of these forbids `Ref` use; see the header for the empirical
/// verification.
const List<String> lifecycleHooks = <String>[
  'onDispose',
  'onCancel',
  'onResume',
  'onAddListener',
  'onRemoveListener',
];

final _hookRe = RegExp(
  r'\b(\w+)\s*\.\s*(' + lifecycleHooks.join('|') + r')\s*\(',
);

/// Any use of the `ref` identifier as a receiver or a bare argument —
/// `ref.read(...)`, `ref.watch(...)`, `ref.invalidate(...)`,
/// `ref.container`, or passing `ref` along to a helper. All of them
/// trip the same callback-stack assertion.
final _refUseRe = RegExp(r'(?<![\w$.])(ref|_ref)\s*(\.\s*(\w+)|\)|,)');

/// A method or function invocation: `_foo(`, `foo(`. Used to walk from
/// a callback body into helpers that touch `ref`.
final _callRe = RegExp(r'(?<![\w$.])(_?[a-z]\w*)\s*\(');

/// A bare identifier passed as the whole callback argument — the
/// tear-off shape `ref.onDispose(_teardown)`.
final _tearOffRe = RegExp(r'^\s*(_?\w+(?:\.\w+)?)\s*$');

/// Scans every non-generated Dart file under [roots] for `Ref` use
/// inside lifecycle callbacks.
List<LifecycleRefUse> scanLifecycleRefUse(List<Directory> roots) {
  final uses = <LifecycleRefUse>[];
  for (final root in roots) {
    for (final file in dartFiles(root)) {
      uses.addAll(scanSource(file.readAsStringSync(), file.path));
    }
  }
  uses.sort((a, b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : a.line.compareTo(b.line);
  });
  return uses;
}

/// Scans a single source [src] attributed to [path].
///
/// Helper resolution is scoped per class/mixin/extension body rather
/// than per file: two classes in one file routinely declare methods of
/// the same name (`_teardown`, `dispose`), and a file-flat member map
/// lets a clean namesake mask a dirty one, or the reverse.
List<LifecycleRefUse> scanSource(String src, String path) {
  final stripped = stripCommentsAndStrings(src);
  final uses = <LifecycleRefUse>[];
  for (final scope in _scopes(stripped)) {
    uses.addAll(_scanScope(scope, stripped, path));
  }
  uses.sort((a, b) => a.line.compareTo(b.line));
  return uses;
}

/// A lexical scope within which helper names resolve: one
/// class/mixin/extension body, or the file's top-level remainder.
class _Scope {
  _Scope(this.offset, this.text);

  /// Offset of [text] within the stripped source, for line attribution.
  final int offset;

  /// The scope's source text.
  final String text;
}

final _typeDeclRe = RegExp(
  r'(?:^|\n)\s*(?:abstract\s+|base\s+|final\s+|sealed\s+|mixin\s+)*'
  r'(?:class|mixin|extension|enum)\b[^{;]*\{',
);

/// Splits [src] into per-type-declaration scopes plus a top-level
/// remainder holding everything outside them.
List<_Scope> _scopes(String src) {
  final scopes = <_Scope>[];
  final remainder = StringBuffer();
  var cursor = 0;
  for (final m in _typeDeclRe.allMatches(src)) {
    if (m.start < cursor) continue;
    final braceAt = m.end - 1;
    final body = balancedSpan(src, braceAt, '{', '}');
    if (body == null) continue;
    // The type declaration is blanked out of the remainder rather than
    // dropped, keeping newlines so the remainder's offsets stay aligned
    // with [src].
    remainder
      ..write(src.substring(cursor, m.start))
      ..write(_blanked(src.substring(m.start, braceAt + body.length)));
    scopes.add(_Scope(braceAt, body));
    cursor = braceAt + body.length;
  }
  remainder.write(src.substring(cursor));
  scopes.add(_Scope(0, remainder.toString()));
  return scopes;
}

/// [text] with every non-newline character replaced by a space.
String _blanked(String text) {
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    buf.write(text.codeUnitAt(i) == 0x0a ? '\n' : ' ');
  }
  return buf.toString();
}

List<LifecycleRefUse> _scanScope(_Scope scope, String stripped, String path) {
  final src = scope.text;
  final refUsingMembers = _refUsingMembers(src);
  final members = _memberBodies(src);
  final uses = <LifecycleRefUse>[];

  for (final m in _hookRe.allMatches(src)) {
    final receiver = m.group(1)!;
    // Only `Ref` receivers. `ref` / `_ref` are the suite's conventions;
    // anything else (`controller.onCancel(...)`) is a foreign API.
    if (receiver != 'ref' && receiver != '_ref') continue;
    final hook = m.group(2)!;
    final line = _lineOf(stripped, scope.offset + m.start);
    final arg = balancedSpan(src, m.end - 1, '(', ')');
    if (arg == null) continue;
    final inner = arg.substring(1, arg.length - 1);

    // Shape 3: tear-off. `ref.onDispose(_teardown)`.
    final tearOff = _tearOffRe.firstMatch(inner);
    if (tearOff != null) {
      final target = tearOff.group(1)!;
      if (refUsingMembers.containsKey(target)) {
        uses.add(
          LifecycleRefUse(
            path: path,
            line: line,
            hook: hook,
            shape: 'tear-off',
            detail:
                '$hook($target) — $target reaches ref via '
                '${refUsingMembers[target]!.join(' -> ')}',
          ),
        );
      }
      continue;
    }

    // Shape 1: direct `ref.` use in the callback body. Nested hook
    // registrations inside the body are themselves violations, so no
    // exclusion is needed.
    final direct = _refUseRe.firstMatch(inner);
    if (direct != null) {
      uses.add(
        LifecycleRefUse(
          path: path,
          line: line,
          hook: hook,
          shape: 'direct',
          detail: '$hook(...) body uses `${direct.group(0)!.trim()}`',
        ),
      );
      continue;
    }

    // Shape 2: the body calls a helper that reaches `ref`. Skip calls
    // that are themselves declared inside this callback body (local
    // closures are covered by the direct scan above).
    for (final call in _callRe.allMatches(inner)) {
      final name = call.group(1)!;
      final chain = refUsingMembers[name];
      if (chain == null) continue;
      if (!members.containsKey(name)) continue;
      uses.add(
        LifecycleRefUse(
          path: path,
          line: line,
          hook: hook,
          shape: 'helper',
          detail:
              '$hook(...) calls $name(), which reaches ref via '
              '${chain.join(' -> ')}',
        ),
      );
      break;
    }
  }
  return uses;
}

/// Maps every method / top-level function / closure-valued field in
/// [src] that reaches `ref` — directly or through another member in the
/// same file — to the chain proving it. Computed to a fixed point so an
/// arbitrarily deep helper stack still resolves.
Map<String, List<String>> _refUsingMembers(String src) {
  final bodies = _memberBodies(src);
  final chains = <String, List<String>>{};

  // Seed: members whose own body names `ref`.
  for (final entry in bodies.entries) {
    if (_refUseRe.hasMatch(_withoutNestedHooks(entry.value))) {
      chains[entry.key] = <String>[entry.key];
    }
  }
  // Propagate: calling a ref-reaching member makes you ref-reaching.
  var changed = true;
  while (changed) {
    changed = false;
    for (final entry in bodies.entries) {
      if (chains.containsKey(entry.key)) continue;
      for (final call in _callRe.allMatches(entry.value)) {
        final name = call.group(1)!;
        if (name == entry.key) continue;
        final downstream = chains[name];
        if (downstream == null) continue;
        chains[entry.key] = <String>[entry.key, ...downstream];
        changed = true;
        break;
      }
    }
  }
  return chains;
}

/// Removes lifecycle-hook argument spans from [body] before testing it
/// for `ref` use. A helper that only touches `ref` *outside* the hooks
/// it registers is safe to call from a live code path; the hooks it
/// registers are scanned on their own by [scanSource].
String _withoutNestedHooks(String body) {
  final buf = StringBuffer();
  var i = 0;
  while (i < body.length) {
    final m = _hookRe.firstMatch(body.substring(i));
    if (m == null) {
      buf.write(body.substring(i));
      break;
    }
    buf.write(body.substring(i, i + m.start));
    final arg = balancedSpan(body, i + m.end - 1, '(', ')');
    i = arg == null ? i + m.end : i + m.end - 1 + arg.length;
  }
  return buf.toString();
}

/// A bare `name(` occurrence — a *candidate* declaration head. Kept
/// deliberately simple (no optional return-type clause) because any
/// pattern that tries to spell a Dart type ahead of the name needs
/// alternating "word / whitespace" quantifiers, which backtrack
/// catastrophically on real sources. Declarations are separated from
/// call sites structurally instead, by what follows the parameter list.
final _declHeadRe = RegExp(
  r'(?<![\w$.])(_?[a-zA-Z]\w*)\s*(?:<[^<>()]*>)?\s*\(',
);

/// Maps member name → body text, for every method, top-level function
/// and constructor-like declaration in [src]. Bodies are the balanced
/// `{ … }` block or the `=> …;` expression.
///
/// A candidate `name(...)` is a declaration iff what follows its
/// balanced parameter list is a body opener — `{`, `=>`, or an
/// `async`/`sync` modifier — rather than the `;`, `)` or `,` that ends
/// an invocation. That test costs one balanced scan and no backtracking.
Map<String, String> _memberBodies(String src) {
  final bodies = <String, String>{};
  for (final m in _declHeadRe.allMatches(src)) {
    final name = m.group(1)!;
    if (_keywords.contains(name)) continue;
    final params = balancedSpan(src, m.end - 1, '(', ')');
    if (params == null) continue;
    var i = m.end - 1 + params.length;
    // Skip whitespace, `async`/`async*`/`sync*`, and constructor
    // initializer lists to reach the body opener.
    while (i < src.length) {
      final ch = src[i];
      if (ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r' || ch == '*') {
        i++;
        continue;
      }
      if (src.startsWith('async', i)) {
        i += 5;
        continue;
      }
      if (src.startsWith('sync', i)) {
        i += 4;
        continue;
      }
      break;
    }
    if (i >= src.length) continue;
    if (src.startsWith('=>', i)) {
      final semi = src.indexOf(';', i);
      bodies[name] = semi == -1 ? src.substring(i) : src.substring(i, semi);
      continue;
    }
    if (src[i] == '{') {
      final block = balancedSpan(src, i, '{', '}');
      if (block != null) bodies[name] = block;
    }
  }
  return bodies;
}

const Set<String> _keywords = <String>{
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'assert',
  'super',
  'this',
  'do',
  'else',
  'new',
  'await',
  'yield',
  'throw',
  'case',
  'when',
};

/// The balanced [open]…[close] span of [src] beginning at the [open]
/// character at [start], inclusive of both delimiters. Null when
/// unbalanced.
String? balancedSpan(String src, int start, String open, String close) {
  if (start < 0 || start >= src.length || src[start] != open) return null;
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    final ch = src[i];
    if (ch == open) depth++;
    if (ch == close) {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return null;
}

/// Blanks out comments and string literals, preserving offsets and
/// newlines so reported line numbers stay accurate. Prevents a `ref.`
/// mentioned in a doc comment from reading as a violation.
String stripCommentsAndStrings(String src) {
  final out = List<int>.filled(src.length, 0x20);
  var i = 0;
  void keep(int at) => out[at] = src.codeUnitAt(at);
  while (i < src.length) {
    final ch = src[i];
    if (src.startsWith('//', i)) {
      while (i < src.length && src[i] != '\n') {
        if (src[i] == '\n') keep(i);
        i++;
      }
      continue;
    }
    if (src.startsWith('/*', i)) {
      var depth = 0;
      while (i < src.length) {
        if (src.startsWith('/*', i)) {
          depth++;
          i += 2;
          continue;
        }
        if (src.startsWith('*/', i)) {
          depth--;
          i += 2;
          if (depth == 0) break;
          continue;
        }
        if (src[i] == '\n') keep(i);
        i++;
      }
      continue;
    }
    if (ch == "'" || ch == '"') {
      final triple = src.startsWith(ch * 3, i);
      final delim = triple ? ch * 3 : ch;
      i += delim.length;
      while (i < src.length) {
        if (src[i] == r'\') {
          i += 2;
          continue;
        }
        if (src.startsWith(delim, i)) {
          i += delim.length;
          break;
        }
        if (src[i] == '\n') keep(i);
        i++;
      }
      continue;
    }
    keep(i);
    i++;
  }
  return String.fromCharCodes(out);
}

/// Sorted newline offsets of [src], cached per source so line
/// attribution is a binary search rather than a rescan per hook.
final Map<String, List<int>> _lineIndexCache = <String, List<int>>{};

List<int> _lineIndex(String src) {
  return _lineIndexCache.putIfAbsent(src, () {
    final offsets = <int>[];
    for (var i = 0; i < src.length; i++) {
      if (src.codeUnitAt(i) == 0x0a) offsets.add(i);
    }
    return offsets;
  });
}

int _lineOf(String src, int offset) {
  final offsets = _lineIndex(src);
  var lo = 0;
  var hi = offsets.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (offsets[mid] < offset) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo + 1;
}

/// Formats the failure report for [uses].
String formatLifecycleRefReport(List<LifecycleRefUse> uses) {
  final buf = StringBuffer()
    ..writeln('`Ref` used inside Riverpod lifecycle callback(s):')
    ..writeln();
  for (final u in uses) {
    buf
      ..writeln('  ${u.path}:${u.line}  [${u.shape}]')
      ..writeln('    ${u.detail}')
      ..writeln();
  }
  buf
    ..writeln(
      'Riverpod forbids touching `ref` from inside a lifecycle callback '
      '(`_debugCallbackStack == 0`: "Cannot use Ref or modify other '
      'providers inside life-cycles/selectors").',
    )
    ..writeln()
    ..writeln(
      'The throw ABORTS THE REST OF THE CALLBACK. Every teardown step '
      'written below the offending line silently does not run — '
      'subscriptions stay attached, buffers stay unflushed, registries '
      'keep stale entries. Nothing surfaces to the user.',
    )
    ..writeln()
    ..writeln('FIX: resolve the value or service EAGERLY, before the hook:')
    ..writeln()
    ..writeln('    // in build()')
    ..writeln('    final registry = ref.read(registryProvider);')
    ..writeln('    ref.onDispose(() => registry.unregister(token));')
    ..writeln()
    ..writeln('NOT:')
    ..writeln()
    ..writeln('    ref.onDispose(() {')
    ..writeln('      ref.read(registryProvider).unregister(token); // throws')
    ..writeln('      subscription.cancel();                       // skipped')
    ..writeln('    });');
  return buf.toString();
}

/// All non-generated Dart files under [dir].
Iterable<File> dartFiles(Directory dir) sync* {
  if (!dir.existsSync()) return;
  for (final e in dir.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    if (e.path.endsWith('.g.dart')) continue;
    if (e.path.endsWith('.freezed.dart')) continue;
    yield e;
  }
}
