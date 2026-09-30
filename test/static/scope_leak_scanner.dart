// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Resolved-AST provider read-graph scanner backing
// `per_tab_provider_scope_leak_test.dart`. Shared as a separate library so the
// open-core test and the Pro overlay's test exercise the exact same extraction
// semantics, and so both can pin the reach analysis against the seeded shapes
// in `scope_leak_shapes/shapes.dart`.
//
// ANALYSIS MODEL
// The scan resolves every library under the source roots with
// `package:analyzer` and works on elements, not on text. Four steps:
//
//  1. PROVIDER REGISTRY. A top-level variable is a provider when its static
//     type, or any supertype, is declared in a riverpod library. That is a
//     type test, so it covers hand-written providers and families alike and
//     does not depend on the variable being named `…Provider`. Each provider is
//     keyed by `<library uri>::<name>`, stable across the two analysis contexts
//     a cross-repo scan needs.
//
//  2. BODIES. A provider's build logic is whatever its initializer supplies: an
//     inline closure (scanned in place), a referenced top-level function, or a
//     `Notifier` class named by a `Foo.new` tear-off.
//
//  3. READS. A read is a `watch`/`read`/`listen`/`listenManual`/`refresh`/
//     `invalidate` invocation whose *receiver's static type* is riverpod's
//     `Ref` or `WidgetRef`. Testing the receiver's type rather than the token
//     `ref` is what makes a read through a stored `Ref` field visible. Reads are
//     collected over the call graph, not just the provider's own body: every
//     invocation resolving to a declaration inside the source roots is followed,
//     memoized per declaration and guarded against cycles. This reaches a read
//     hidden in a helper object, an extension method on `Ref`, or a private
//     notifier method. The analysis is a may-analysis: a run-time selection
//     between two providers contributes both.
//
//  4. TAINT CLOSURE. A provider is tainted if it reads a per-tab provider or any
//     other tainted provider. Every tainted provider that is not itself per-tab
//     is a violation.
//
// SIMCRUX TWIST — per-mode override lists. The per-tab override set differs
// between open-core and Pro modes. Open-core installs `simcruxTabOverrides`;
// the Pro overlay replaces the factory with `proTabOverrides` and re-homes the
// project-scoped providers as root per-project delegates in `proOverrides`. The
// override lists are therefore composed from bundle-helper calls
// (`...perProjectDashboardStateOverrides()`, `perProjectResultStoreOverride()`)
// and named `Override` consts, not only inline `x.overrideWith(…)` entries.
// [ScopeGraph.overrideTargets] follows those bundle helpers through the call
// graph so the effective symbol set resolves whichever shape the list uses,
// while deliberately NOT following a factory tear-off passed as a value
// argument (`overrideWithValue(proTabOverrides)`) — doing so would miscount the
// per-tab-only providers as root-overridden.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;

/// One provider-to-provider read edge, with the helper declarations the read
/// was found behind (empty when it is written in the provider's own body).
class ProviderRead {
  /// Creates a read edge to [target] reached through [via].
  ProviderRead(this.target, this.via);

  /// The provider key that was read.
  final String target;

  /// The helper declaration names the read was found behind.
  final List<String> via;
}

/// A registered provider: its symbol, the repo-relative path of the library
/// declaring it, and the declarations supplying its build logic.
class ProviderInfo {
  /// Creates a provider record.
  ProviderInfo(this.key, this.name, this.path);

  /// Registry key: `<library uri>::<name>`.
  final String key;

  /// The `xProvider` symbol.
  final String name;

  /// Repo-relative path of the declaring library.
  final String path;

  /// Declaration keys supplying this provider's build logic.
  final Set<String> bodies = <String>{};

  /// The provider's initializer expression, scanned for its own-body reads.
  Expression? initializer;
}

/// The resolved provider read-graph over a set of source roots.
class ScopeGraph {
  ScopeGraph._();

  /// Every registered provider, keyed by `<library uri>::<name>`.
  final Map<String, ProviderInfo> providers = <String, ProviderInfo>{};

  /// Libraries that failed to resolve (any provider they declare is invisible).
  final List<String> unresolved = <String>[];

  final Map<String, _Decl> _decls = <String, _Decl>{};
  final Map<String, ResolvedUnitResult> _units = <String, ResolvedUnitResult>{};
  final Map<String, Map<String, String>> _generated =
      <String, Map<String, String>>{};
  final Map<String, _Scan> _scans = <String, _Scan>{};
  Map<String, List<ProviderRead>>? _reads;

  /// Resolves every `.dart` file under [roots] and builds the read-graph.
  static Future<ScopeGraph> resolve(List<Directory> roots) async {
    final files = <String>[];
    for (final root in roots) {
      if (!root.existsSync()) continue;
      for (final e in root.listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) {
          files.add(p.normalize(e.absolute.path));
        }
      }
    }
    final graph = ScopeGraph._();
    if (files.isEmpty) return graph;
    final collection = AnalysisContextCollection(
      includedPaths: files,
      sdkPath: _dartSdkPath(),
    );
    for (final file in files) {
      final result = await collection
          .contextFor(file)
          .currentSession
          .getResolvedUnit(file);
      if (result is! ResolvedUnitResult) {
        graph.unresolved.add(p.relative(file));
        continue;
      }
      graph._units[p.normalize(result.path)] = result;
      result.unit.accept(_UnitVisitor(graph, result));
    }
    graph._linkGenerated();
    return graph;
  }

  /// The provider symbol for [key], for reporting.
  String nameOf(String key) =>
      providers[key]?.name ?? key.substring(key.indexOf('::') + 2);

  /// The registry key for a provider named [name], or null.
  String? keyOf(String name) {
    for (final e in providers.entries) {
      if (e.value.name == name) return e.key;
    }
    return null;
  }

  /// The helper chain recorded for the first hop of [reach], if the read was
  /// not written in that provider's own body.
  List<String> viaFor(List<String> reach) {
    if (reach.length < 2) return const <String>[];
    for (final r in reads()[reach[0]] ?? const <ProviderRead>[]) {
      if (r.target == reach[1]) return r.via;
    }
    return const <String>[];
  }

  /// Provider keys appearing as `x.overrideWith*(…)` targets in the library at
  /// [path], optionally restricted to the declaration (top-level variable or
  /// function) named [within].
  ///
  /// Bundle-helper invocations (`...someOverrides()`, `someOverride()`) and
  /// named `Override` const references inside the list are followed through the
  /// call graph so a list composed from helpers resolves to its leaf targets.
  /// A factory tear-off passed as a value argument to `overrideWithValue` is
  /// deliberately NOT followed.
  Set<String> overrideTargets(String path, String? within) {
    final unit = _units[p.normalize(File(path).absolute.path)];
    if (unit == null) return <String>{};
    final scopes = <AstNode>[];
    if (within == null) {
      scopes.add(unit.unit);
    } else {
      for (final d in unit.unit.declarations) {
        if (d is TopLevelVariableDeclaration &&
            d.variables.variables.any((v) => v.name.lexeme == within)) {
          scopes.add(d);
        } else if (d is FunctionDeclaration && d.name.lexeme == within) {
          scopes.add(d);
        }
      }
      if (scopes.isEmpty) scopes.add(unit.unit);
    }
    final out = <String>{};
    final seen = <String>{};
    final queue = <AstNode>[...scopes];
    while (queue.isNotEmpty) {
      final node = queue.removeLast();
      final collector = _OverrideCollector(this);
      node.accept(collector);
      out.addAll(collector.targets);
      for (final key in collector.calleeDecls) {
        if (!seen.add(key)) continue;
        final decl = _decls[key];
        if (decl != null) queue.add(decl.node);
      }
    }
    return out;
  }

  /// Every provider's read set, following the call graph out of its bodies.
  Map<String, List<ProviderRead>> reads() {
    final cached = _reads;
    if (cached != null) return cached;
    final out = <String, List<ProviderRead>>{};
    for (final info in providers.values) {
      final found = <String, List<String>>{};
      final own = _Scan();
      info.initializer?.accept(_ReadVisitor(this, own));
      for (final target in own.reads) {
        found.putIfAbsent(target, () => const <String>[]);
      }
      final seen = <String>{...info.bodies, ...own.callees};
      final queue = <_Frame>[
        for (final k in info.bodies) _Frame(k, const <String>[]),
        for (final k in own.callees)
          if (!info.bodies.contains(k))
            _Frame(k, <String>[_decls[k]?.name ?? k]),
      ];
      while (queue.isNotEmpty) {
        final frame = queue.removeLast();
        final scan = _scan(frame.decl);
        for (final target in scan.reads) {
          found.putIfAbsent(target, () => frame.via);
        }
        for (final callee in scan.callees) {
          if (!seen.add(callee)) continue;
          queue.add(
            _Frame(callee, <String>[
              ...frame.via,
              _decls[callee]?.name ?? callee,
            ]),
          );
        }
      }
      out[info.key] = <ProviderRead>[
        for (final e in found.entries) ProviderRead(e.key, e.value),
      ];
    }
    return _reads = out;
  }

  _Scan _scan(String declKey) {
    final cached = _scans[declKey];
    if (cached != null) return cached;
    final scan = _scans[declKey] = _Scan();
    _decls[declKey]?.node.accept(_ReadVisitor(this, scan));
    return scan;
  }

  void _linkGenerated() {
    for (final info in providers.values) {
      final library = info.key.substring(0, info.key.indexOf('::'));
      final decl = _generated[library]?[info.name];
      if (decl != null) info.bodies.add(decl);
    }
  }

  void _noteGenerated(String library, String provider, String declKey) {
    _generated.putIfAbsent(library, () => <String, String>{})[provider] =
        declKey;
  }
}

/// Fixed-point taint propagation. Returns, for every tainted provider, a
/// shortest reach path ending at the per-tab seed it depends on.
Map<String, List<String>> taintClosure(
  Map<String, List<ProviderRead>> reads,
  Set<String> perTab,
) {
  final reach = <String, List<String>>{};
  for (final entry in reads.entries) {
    for (final read in entry.value) {
      if (read.target == entry.key || !perTab.contains(read.target)) continue;
      reach[entry.key] = <String>[entry.key, read.target];
      break;
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final entry in reads.entries) {
      if (reach.containsKey(entry.key)) continue;
      for (final read in entry.value) {
        if (read.target == entry.key) continue;
        final downstream = reach[read.target];
        if (downstream == null) continue;
        reach[entry.key] = <String>[entry.key, ...downstream];
        changed = true;
        break;
      }
    }
  }
  return reach;
}

/// The Dart SDK the analyzer should resolve `dart:` libraries against. Under
/// `flutter test` the running executable is the Flutter tester, whose directory
/// is not an SDK, so the bundled `dart-sdk` is located explicitly.
String? _dartSdkPath() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final candidates = <String>[
    if (flutterRoot != null) p.join(flutterRoot, 'bin', 'cache', 'dart-sdk'),
    p.dirname(p.dirname(Platform.resolvedExecutable)),
  ];
  for (final candidate in candidates) {
    if (File(p.join(candidate, 'lib', 'core', 'core.dart')).existsSync()) {
      return candidate;
    }
  }
  return null;
}

class _Frame {
  _Frame(this.decl, this.via);
  final String decl;
  final List<String> via;
}

class _Decl {
  _Decl(this.name, this.node);
  final String name;
  final AstNode node;
}

class _Scan {
  final Set<String> reads = <String>{};
  final Set<String> callees = <String>{};
}

bool _isRiverpodLibrary(Uri? uri) =>
    uri != null && uri.toString().contains('riverpod');

/// True when [type] is, or inherits from, a type declared by riverpod.
bool _isProviderType(DartType? type) {
  if (type is! InterfaceType) return false;
  if (_isRiverpodLibrary(type.element.library.uri)) return true;
  for (final supertype in type.element.allSupertypes) {
    if (_isRiverpodLibrary(supertype.element.library.uri)) return true;
  }
  return false;
}

/// True when [type] is riverpod's `Override`.
bool _isOverrideTyped(DartType? type) {
  if (type is! InterfaceType) return false;
  return type.element.name == 'Override';
}

/// True when [type] is riverpod's `Ref` or `WidgetRef`, however it was reached.
bool _isRefType(DartType? type) {
  if (type is! InterfaceType) return false;
  bool isRef(InterfaceElement element) {
    final name = element.name;
    return _isRiverpodLibrary(element.library.uri) &&
        (name == 'Ref' || name == 'WidgetRef');
  }

  if (isRef(type.element)) return true;
  for (final supertype in type.element.allSupertypes) {
    if (isRef(supertype.element)) return true;
  }
  return false;
}

/// True when [element] is a `Ref` member invoked without an explicit receiver —
/// the shape a `Ref` extension method takes, where `watch(x)` is an implicit
/// `this.watch(x)`.
bool _isImplicitRefReceiver(Element? element) {
  final enclosing = element?.enclosingElement;
  if (enclosing is InterfaceElement) return _isRefType(enclosing.thisType);
  if (enclosing is ExtensionElement) return _isRefType(enclosing.extendedType);
  return false;
}

const Set<String> _refMethods = <String>{
  'watch',
  'read',
  'listen',
  'listenManual',
  'refresh',
  'invalidate',
};

/// The registry key for a provider element, or null if [element] is not a
/// top-level provider variable.
String? _providerKey(Element? element) {
  var target = element;
  if (target is GetterElement) target = target.variable;
  if (target is SetterElement) target = target.variable;
  if (target is! TopLevelVariableElement) return null;
  if (!_isProviderType(target.type)) return null;
  final name = target.name;
  if (name == null) return null;
  return '${target.library.uri}::$name';
}

/// A stable key for a scannable declaration: its source file and name offset.
String? _declKey(Element? element) {
  if (element == null) return null;
  final fragment = element.firstFragment;
  final source = fragment.libraryFragment?.source.fullName;
  final offset = fragment.nameOffset;
  if (source == null || offset == null) return null;
  return '$source@$offset';
}

/// Registers provider definitions and every scannable declaration in one unit.
class _UnitVisitor extends RecursiveAstVisitor<void> {
  _UnitVisitor(this.graph, this.result);

  final ScopeGraph graph;
  final ResolvedUnitResult result;

  void _record(Element? element, String name, AstNode node) {
    final key = _declKey(element);
    if (key == null) return;
    graph._decls.putIfAbsent(key, () => _Decl(name, node));
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      final element = variable.declaredFragment?.element;
      // Record the variable's initializer so a named `Override` const used as a
      // list entry can be scanned for its `overrideWith` binding.
      _record(element, element?.name ?? '<var>', variable);
      final key = _providerKey(element);
      if (key == null) continue;
      final info = graph.providers.putIfAbsent(
        key,
        () => ProviderInfo(
          key,
          element!.name!,
          p.relative(result.libraryElement.firstFragment.source.fullName),
        ),
      );
      final initializer = variable.initializer;
      if (initializer != null) {
        info.initializer = initializer;
        initializer.accept(_BodyReferenceVisitor(info));
      }
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final element = node.declaredFragment?.element;
    final name = element?.name ?? '<function>';
    _record(element, name, node);
    _noteIfGenerated(node.metadata, name, element);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final element = node.declaredFragment?.element;
    _record(element, element?.name ?? '<method>', node);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _record(node.declaredFragment?.element, '<constructor>', node);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final element = node.declaredFragment?.element;
    final name = element?.name ?? '<class>';
    _record(element, name, node);
    _noteIfGenerated(node.metadata, name, element);
    super.visitClassDeclaration(node);
  }

  /// A `@riverpod` function or class generates `<name>Provider` into the same
  /// library's `.g.dart` part; record the association so the generated variable
  /// picks up the annotated declaration as its body. SimCrux ships no codegen,
  /// but the link is harmless and keeps the scanner portable.
  void _noteIfGenerated(
    NodeList<Annotation> metadata,
    String name,
    Element? element,
  ) {
    final annotated = metadata.any((a) {
      final n = a.name.name;
      return n == 'riverpod' || n == 'Riverpod';
    });
    if (!annotated || name.isEmpty) return;
    final key = _declKey(element);
    if (key == null) return;
    graph._noteGenerated(
      result.libraryElement.uri.toString(),
      '${name[0].toLowerCase()}${name.substring(1)}Provider',
      key,
    );
  }
}

/// Attaches the declarations a provider's initializer names — `Foo.new` for a
/// notifier class, a bare identifier for a top-level build function — as that
/// provider's bodies.
class _BodyReferenceVisitor extends RecursiveAstVisitor<void> {
  _BodyReferenceVisitor(this.info);

  final ProviderInfo info;

  void _add(Element? element) {
    var target = element;
    if (target is ConstructorElement) target = target.enclosingElement;
    final key = _declKey(target);
    if (key != null) info.bodies.add(key);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (element is LocalFunctionElement ||
        element is TopLevelFunctionElement ||
        element is ConstructorElement) {
      _add(element);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    _add(node.constructorName.element);
    super.visitConstructorReference(node);
  }
}

/// Collects `ref.*` provider reads and outgoing call-graph edges from one
/// declaration.
class _ReadVisitor extends RecursiveAstVisitor<void> {
  _ReadVisitor(this.graph, this.scan);

  final ScopeGraph graph;
  final _Scan scan;

  void _addCallee(Element? element) {
    final key = _declKey(element);
    if (key != null && graph._decls.containsKey(key)) scan.callees.add(key);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final receiver = node.realTarget;
    final onRef = receiver != null
        ? _isRefType(receiver.staticType)
        : _isImplicitRefReceiver(node.methodName.element);
    if (_refMethods.contains(node.methodName.name) &&
        onRef &&
        node.argumentList.arguments.isNotEmpty) {
      node.argumentList.arguments.first.accept(
        _ProviderArgumentVisitor(graph, scan, <String>{}),
      );
    }
    _addCallee(node.methodName.element);
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _addCallee(node.propertyName.element);
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _addCallee(node.identifier.element);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _addCallee(node.constructorName.element);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _addCallee(node.element);
    super.visitFunctionExpressionInvocation(node);
  }
}

/// Resolves the provider(s) an argument expression denotes: a plain reference,
/// a family application, a conditional, or the result of a helper that returns
/// a provider.
class _ProviderArgumentVisitor extends RecursiveAstVisitor<void> {
  _ProviderArgumentVisitor(this.graph, this.scan, this.guard);

  final ScopeGraph graph;
  final _Scan scan;
  final Set<String> guard;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final key = _providerKey(node.element);
    if (key != null) scan.reads.add(key);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final key = _declKey(node.methodName.element);
    if (key != null && guard.add(key)) {
      graph._decls[key]?.node.accept(
        _ProviderArgumentVisitor(graph, scan, guard),
      );
    }
    super.visitMethodInvocation(node);
  }
}

/// Collects `x.overrideWith*(…)` targets from an override list, following
/// bundle-helper invocations and named `Override` const references through the
/// call graph while never descending into an override builder's own arguments.
class _OverrideCollector extends RecursiveAstVisitor<void> {
  _OverrideCollector(this.graph);

  final ScopeGraph graph;

  /// Provider keys overridden in this scope (directly or via bundle helpers).
  final Set<String> targets = <String>{};

  /// Declaration keys of bundle helpers / named consts to follow.
  final Set<String> calleeDecls = <String>{};

  static const _overrideMethods = <String>{
    'overrideWith',
    'overrideWithValue',
    'overrideWithBuild',
  };

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_overrideMethods.contains(node.methodName.name)) {
      final receiver = node.realTarget;
      if (receiver is Identifier) {
        final key = _providerKey(receiver.element);
        if (key != null) targets.add(key);
      }
      // Do not descend into the override builder argument: a factory tear-off
      // such as `overrideWithValue(proTabOverrides)` must not be followed, or a
      // per-tab-only bundle would be miscounted as root-overridden.
      return;
    }
    // A bundle-helper invocation like `perProjectResultStoreOverride()` or
    // `...perProjectDashboardStateOverrides()`. Follow the callee.
    final key = _declKey(node.methodName.element);
    if (key != null && graph._decls.containsKey(key)) calleeDecls.add(key);
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // A named `Override` const used as a list entry.
    var target = node.element;
    if (target is GetterElement) target = target.variable;
    if (target is TopLevelVariableElement && _isOverrideTyped(target.type)) {
      final key = _declKey(target);
      if (key != null && graph._decls.containsKey(key)) calleeDecls.add(key);
    }
    super.visitSimpleIdentifier(node);
  }
}
