// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: every Dart file under `lib/` is reachable from an entry point
// of this package, or is listed below with the reason it is not.
//
// ## The defect class this closes
//
// A file nothing imports still compiles, still analyzes clean, and keeps its
// own unit tests green: the tests import it directly, so they cannot notice
// that the application does not. `action_reachability_guard_test.dart` checks
// that an action DECLARES a surface; nothing checked that the code behind a
// feature is MOUNTED. A text tripwire (`expect(source, contains('Foo('))`)
// stays green after the file holding `Foo(` loses its last importer, and a doc
// comment asserting "the open-core build renders this" survives the same
// loss. This guard reads the import graph instead.
//
// ## What counts as reached
//
// The walk starts at every `lib/main*.dart` (the desktop app and the web
// dashboard viewer) and every `bin/*.dart` (the headless `simcrux` binary),
// and follows `import`, `export` and `part` directives through this package —
// every branch of a conditional import (`if (dart.library.io) …`), because
// each branch is compiled on some platform. Directives are read from a parsed
// syntax tree, so an import inside a comment or a string does not count. The
// `--ci` path needs no entry of its own: it is `lib/main.dart` with different
// arguments. Generated localizations (`lib/l10n/generated/`) are not
// candidates: they are reached through the sources that use them and do not
// exist until `flutter gen-l10n` has run.
//
// ## Why a file may be unreached, and how an exemption stays honest
//
// Exactly two consumers outside this package's entry points are legitimate,
// and every exemption names one. The guard checks the consumer is real, so an
// exemption cannot outlive its reason:
//
//  * `_Consumer.proOverlay` — an open-core file only the Pro overlay imports:
//    an extension-point interface, its value types, its no-op default, or a
//    seam provider whose producer and readers are both overlay code. Verified
//    whenever this repository is checked out as the overlay's submodule
//    (`../lib/overrides.dart` exists): the walk is repeated from the overlay's
//    own entry points, and each such file must be reached from there. A
//    standalone clone cannot see the overlay, so there the check is only that
//    the file exists and is still unreached from here; the overlay's own
//    import guard re-checks this list against its entry points in its CI.
//  * `_Consumer.testsAndTools` — support code shared by tests or a fixture
//    regenerator that must import it through `package:` (the overlay's tests
//    among them). Verified by walking `test/`, `integration_test/` and
//    `tool/`.
//
// An exemption whose file is now reached from an entry point, whose file is
// gone, or whose consumer no longer imports it fails the guard: delete it.

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Which consumer, other than this package's entry points, uses a file.
enum _Consumer {
  /// Imported by the Pro overlay's `lib/`.
  proOverlay,

  /// Imported only by tests, integration tests or tools.
  testsAndTools,
}

/// A `lib/` file no entry point of this package reaches, and why that is
/// correct.
class _Exemption {
  const _Exemption(this.file, this.consumer, this.reason);

  /// Package-relative path, forward slashes.
  final String file;

  /// Who imports it instead; the guard verifies this.
  final _Consumer consumer;

  /// Why the open-core entry points do not reach it.
  final String reason;
}

const _crossProjectSearch =
    'Part of the cross-project search seam. The open core declares the '
    'service interface, its value types and the no-op default; the search '
    'dialog, the service that walks every open project and the only readers '
    'of this seam are Pro overlay code. The open-core Search Across Projects '
    'action dispatches through a separate opener seam and never reaches it.';

const _flakyDetection =
    'Part of the flaky-test detection seam. The open core declares the '
    'service interface, the score and config models and the no-op default; '
    'the scoring engine and every surface that reads a score (the Flaky '
    'Tests panel, the dashboard row annotation, auto-retry) are Pro overlay '
    'code.';

const _prAnnotation =
    'Part of the PR-annotation seam. The open core declares the dispatcher '
    'interface, the annotation and target models, the run-to-annotation '
    'builder and the no-op defaults; the per-platform dispatchers, the '
    'target settings and the run-completion hook that read them are Pro '
    'overlay code.';

const _overlayOpener =
    'A navigation opener seam whose producer and callers are both Pro '
    'overlay code: the overlay registers the screen it mounts and its own '
    'toolbar button and chip read the provider. No open-core surface reads '
    'it; the open-core default is null.';

const _driverPluginSdk =
    'Part of the driver-plugin SDK contract. The open core owns the wire '
    'format so the plugin ABI is published with the code; the only host that '
    'speaks it is the Pro overlay subprocess loader, because spawning plugin '
    'executables is a Pro-tier capability.';

const _exemptions = <_Exemption>[
  // The cross-project search seam.
  _Exemption(
    'lib/domain/enums/cross_project_search_scope.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),
  _Exemption(
    'lib/domain/interfaces/cross_project_search_service.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),
  _Exemption(
    'lib/domain/models/cross_project_search_match.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),
  _Exemption(
    'lib/domain/models/cross_project_search_progress.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),
  _Exemption(
    'lib/domain/models/cross_project_search_query.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),
  _Exemption(
    'lib/domain/models/cross_project_search_target.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),
  _Exemption(
    'lib/services/projects/cross_project_search_provider.dart',
    _Consumer.proOverlay,
    _crossProjectSearch,
  ),

  // The flaky-test detection seam.
  _Exemption(
    'lib/domain/interfaces/flaky_detection_service.dart',
    _Consumer.proOverlay,
    _flakyDetection,
  ),
  _Exemption(
    'lib/domain/models/flakiness_config.dart',
    _Consumer.proOverlay,
    _flakyDetection,
  ),
  _Exemption(
    'lib/domain/models/flakiness_score.dart',
    _Consumer.proOverlay,
    _flakyDetection,
  ),
  _Exemption(
    'lib/services/flaky_detection/flaky_detection_service_provider.dart',
    _Consumer.proOverlay,
    _flakyDetection,
  ),
  _Exemption(
    'lib/services/flaky_detection/noop_flaky_detection_service.dart',
    _Consumer.proOverlay,
    _flakyDetection,
  ),

  // The PR-annotation seam.
  _Exemption(
    'lib/domain/interfaces/pr_annotation_dispatcher.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),
  _Exemption(
    'lib/domain/models/pr_annotation.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),
  _Exemption(
    'lib/domain/models/pr_annotation_dispatch_result.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),
  _Exemption(
    'lib/domain/models/pr_annotation_target.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),
  _Exemption(
    'lib/services/pr_annotation/pr_annotation_dispatcher_provider.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),
  _Exemption(
    'lib/services/pr_annotation/pr_annotation_target_store.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),
  _Exemption(
    'lib/services/pr_annotation/run_annotation_builder.dart',
    _Consumer.proOverlay,
    _prAnnotation,
  ),

  // Opener seams whose callers are all overlay widgets.
  _Exemption(
    'lib/features/dashboard/providers/regression_comparison_opener.dart',
    _Consumer.proOverlay,
    _overlayOpener,
  ),
  _Exemption(
    'lib/features/dashboard/providers/riscv_compatibility_opener.dart',
    _Consumer.proOverlay,
    _overlayOpener,
  ),
  _Exemption(
    'lib/features/dashboard/providers/riscv_formal_opener.dart',
    _Consumer.proOverlay,
    _overlayOpener,
  ),

  // The driver-plugin SDK.
  _Exemption(
    'lib/services/driver_plugin/driver_wire_protocol.dart',
    _Consumer.proOverlay,
    _driverPluginSdk,
  ),
  _Exemption(
    'lib/services/driver_plugin/plugin_test_spec_codec.dart',
    _Consumer.proOverlay,
    _driverPluginSdk,
  ),

  // Other open-core API only the Pro overlay uses.
  _Exemption(
    'lib/domain/models/trend_alert.dart',
    _Consumer.proOverlay,
    'The trend-regression alert model. The detector that produces alerts, '
        'the acknowledged-alerts store and the banner that renders them are '
        'all Pro overlay code; nothing in the open core reads it. Moving the '
        'model into the overlay would retire this entry.',
  ),
  _Exemption(
    'lib/services/telemetry/gated_feature.dart',
    _Consumer.proOverlay,
    'The closed vocabulary of `tier.gate_hit`. Every gate site that can '
        'raise the upgrade dialog is an overlay opener; the vocabulary is '
        'declared here so the event catalog and its conformance test, which '
        'cannot see the overlay, own the one declaration both sides use.',
  ),
  _Exemption(
    'lib/shared/widgets/simcrux_edition_badge.dart',
    _Consumer.proOverlay,
    'States the edition in force and renders nothing at open core, so the '
        'open core does not mount it; the Pro overlay mounts it in the status '
        'bar trailing slot.',
  ),

  // Support code for tests and tools.
  _Exemption(
    'lib/services/job_scheduler/fake_process_runner.dart',
    _Consumer.testsAndTools,
    'The in-process simulator stand-in the scheduler tests, the orchestration '
        'fixture regenerator and the soak harness drive. It lives under lib/ '
        'because tool/ scripts and the Pro overlay tests import it through '
        '`package:`, which cannot reach test/.',
  ),
  _Exemption(
    'lib/services/job_scheduler/orchestration_fixture.dart',
    _Consumer.testsAndTools,
    'The orchestration scenarios shared by '
        'tool/generate_orchestration_fixtures.dart, which writes the golden '
        'corpus, and the golden test that replays it, so the input and the '
        'golden cannot drift.',
  ),
];

void main() {
  final self = _packageName('.');
  final entries = _entryPoints('.');
  final reached = _relativeTo(
    '.',
    _reachable(entries, <String, String>{self: 'lib'}),
  );
  final candidates = _libFiles('.');
  final exempt = <String, _Exemption>{for (final e in _exemptions) e.file: e};

  test('the walk is not vacuous', () {
    expect(
      _relativeTo('.', entries),
      containsAll(<String>[
        'lib/main.dart',
        'lib/main_web.dart',
        'bin/simcrux.dart',
      ]),
      reason: 'the desktop, web and headless entry points were not found',
    );
    expect(
      candidates.where(reached.contains).length,
      greaterThan(300),
      reason: 'the walk reached almost nothing — directive parsing broke',
    );
    expect(reached, contains('lib/app.dart'));
    // The headless binary is an entry point of its own.
    expect(reached, contains('lib/core/cli/simcrux_cli.dart'));
    // A conditional-import branch is compiled on some platform, so it counts.
    expect(
      reached,
      contains('lib/services/trend_store/sql_trend_store_io.dart'),
    );
    expect(
      reached,
      contains('lib/services/trend_store/sql_trend_store_web.dart'),
    );
    // A `part` file is reached through its library.
    expect(reached, contains('lib/services/config/config_loader_riscv.dart'));
  });

  test('every lib file is reachable from an entry point, or says why not', () {
    final offenders = <String>[
      for (final file in candidates)
        if (!reached.contains(file) && !exempt.containsKey(file))
          '$file (${_lineCount(file)} lines)',
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'No entry point of this package imports these files, directly or '
          'transitively:\n  ${offenders.join('\n  ')}\n\n'
          'A file nothing imports is built, tested and shipped by nobody — '
          'its tests import it directly, so they stay green. Delete it, '
          'wire it, or, when another consumer genuinely owns it, add an '
          '_Exemption naming that consumer and the reason.',
    );
  });

  test('every exemption is still needed, and its consumer still uses it', () {
    final stale = <String>[];
    final seen = <String>{};
    for (final e in _exemptions) {
      if (!seen.add(e.file)) stale.add('${e.file}: listed twice');
      if (!File(e.file).existsSync()) {
        stale.add('${e.file}: no longer exists');
      } else if (reached.contains(e.file)) {
        stale.add('${e.file}: now reached from an entry point');
      }
    }

    // Tests, integration tests and tools, as one more set of entry points.
    final supportRoots = <String>[
      for (final dir in const <String>['test', 'integration_test', 'tool'])
        ..._dartFilesUnder(dir),
    ];
    final supportReached = _relativeTo(
      '.',
      _reachable(supportRoots, <String, String>{self: 'lib'}),
    );
    for (final e in _exemptions) {
      if (e.consumer == _Consumer.testsAndTools &&
          !supportReached.contains(e.file)) {
        stale.add('${e.file}: no test, integration test or tool imports it');
      }
    }

    // Checked out as the Pro overlay's submodule, the overlay-owned
    // exemptions are verified against the overlay's own entry points. A
    // standalone checkout cannot see the overlay; see the file comment.
    final overlay = _overlayCheckout();
    if (overlay != null) {
      final overlayReached = _relativeTo(
        '.',
        _reachable(_entryPoints(overlay.root), <String, String>{
          self: 'lib',
          overlay.package: p.join(overlay.root, 'lib'),
        }),
      );
      for (final e in _exemptions) {
        if (e.consumer == _Consumer.proOverlay &&
            !overlayReached.contains(e.file)) {
          stale.add('${e.file}: the Pro overlay no longer reaches it');
        }
      }
    }

    expect(
      stale,
      isEmpty,
      reason:
          'An exemption has outlived its reason; delete it (and the file, '
          'when nothing uses it any more):\n  ${stale.join('\n  ')}',
    );
  });

  group('the walk resolves the shapes it must', () {
    late Directory root;
    late Set<String> fixtureReached;

    setUpAll(() {
      root = Directory.systemTemp.createTempSync('import_walk_shapes_');
      void write(String path, String body) {
        File(p.join(root.path, 'lib', path))
          ..createSync(recursive: true)
          ..writeAsStringSync(body);
      }

      write('main.dart', '''
import 'package:demo/a.dart';
import 'package:other/unrelated.dart';
import 'dart:io';
// import 'package:demo/commented_out.dart';
/* import 'package:demo/block_commented.dart'; */
const text = "import 'package:demo/in_a_string.dart';";
void main() {}
''');
      write('a.dart', '''
export 'b.dart' show B;
import 'c_stub.dart'
    if (dart.library.io) 'c_io.dart'
    if (dart.library.js_interop) 'c_web.dart';
part 'a_part.dart';
''');
      write('a_part.dart', "part of 'a.dart';\n");
      write('b.dart', "import 'sub/d.dart';\nclass B {}\n");
      write('sub/d.dart', "import '../e.dart';\n");
      for (final leaf in const <String>[
        'c_stub.dart',
        'c_io.dart',
        'c_web.dart',
        'e.dart',
        'orphan.dart',
        'commented_out.dart',
        'block_commented.dart',
        'in_a_string.dart',
      ]) {
        write(leaf, '');
      }
      fixtureReached = _relativeTo(
        root.path,
        _reachable(
          <String>[p.join(root.path, 'lib', 'main.dart')],
          <String, String>{'demo': p.join(root.path, 'lib')},
        ),
      );
    });

    tearDownAll(() => root.deleteSync(recursive: true));

    test('imports, exports, parts and every conditional branch', () {
      expect(
        fixtureReached,
        unorderedEquals(<String>[
          'lib/main.dart',
          'lib/a.dart',
          'lib/a_part.dart',
          'lib/b.dart',
          'lib/c_stub.dart',
          'lib/c_io.dart',
          'lib/c_web.dart',
          'lib/sub/d.dart',
          'lib/e.dart',
        ]),
      );
    });

    test('commented-out, quoted and unimported files stay unreached', () {
      for (final unreached in const <String>[
        'lib/orphan.dart',
        'lib/commented_out.dart',
        'lib/block_commented.dart',
        'lib/in_a_string.dart',
      ]) {
        expect(fixtureReached, isNot(contains(unreached)));
      }
    });
  });
}

/// Every file reachable from [entries] through `import`, `export` and `part`,
/// following every branch of a conditional directive.
///
/// [packageRoots] maps a package name to its `lib/` directory; a `package:`
/// URI naming any other package is external and not followed. Returns
/// absolute, normalized paths. A target that does not exist (generated output
/// before codegen) is recorded but not read.
Set<String> _reachable(
  Iterable<String> entries,
  Map<String, String> packageRoots,
) {
  final roots = <String, String>{
    for (final e in packageRoots.entries)
      e.key: p.normalize(p.absolute(e.value)),
  };
  final reached = <String>{};
  final pending = <String>[
    for (final e in entries) p.normalize(p.absolute(e)),
  ];
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    if (!reached.add(file)) continue;
    final source = File(file);
    if (!source.existsSync()) continue;
    final unit = parseString(
      content: source.readAsStringSync(),
      path: file,
      throwIfDiagnostics: false,
    ).unit;
    for (final directive in unit.directives) {
      final uris = <String?>[
        if (directive is NamespaceDirective) ...<String?>[
          directive.uri.stringValue,
          for (final c in directive.configurations) c.uri.stringValue,
        ],
        if (directive is PartDirective) directive.uri.stringValue,
      ];
      for (final uri in uris.nonNulls) {
        final target = _resolve(uri, file, roots);
        if (target != null) pending.add(target);
      }
    }
  }
  return reached;
}

/// The file [uri] names when written in [from], or null when it lies outside
/// every package in [roots].
String? _resolve(String uri, String from, Map<String, String> roots) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null;
    final root = roots[rest.substring(0, slash)];
    if (root == null) return null;
    return p.normalize(p.join(root, rest.substring(slash + 1)));
  }
  return p.normalize(p.join(p.dirname(from), uri));
}

/// Every `lib/main*.dart` and `bin/*.dart` under [packageRoot].
List<String> _entryPoints(String packageRoot) => <String>[
  for (final f in _dartFilesUnder(p.join(packageRoot, 'lib'), recursive: false))
    if (p.basename(f).startsWith('main')) f,
  ..._dartFilesUnder(p.join(packageRoot, 'bin'), recursive: false),
];

/// Every hand-written `lib/**.dart` file, package-relative.
List<String> _libFiles(String packageRoot) => <String>[
  for (final f in _relativeTo(
    packageRoot,
    _dartFilesUnder(p.join(packageRoot, 'lib')),
  ))
    if (!_isGenerated(f)) f,
]..sort();

bool _isGenerated(String relative) =>
    relative.endsWith('.g.dart') ||
    relative.endsWith('.freezed.dart') ||
    relative.startsWith('lib/l10n/generated/');

List<String> _dartFilesUnder(String dir, {bool recursive = true}) {
  final d = Directory(dir);
  if (!d.existsSync()) return const <String>[];
  return <String>[
    for (final e in d.listSync(recursive: recursive))
      if (e is File && e.path.endsWith('.dart')) e.path,
  ];
}

/// [paths] relative to [root], with forward slashes, for paths inside it.
Set<String> _relativeTo(String root, Iterable<String> paths) {
  final base = p.normalize(p.absolute(root));
  return <String>{
    for (final path in paths)
      if (p.isWithin(base, p.normalize(p.absolute(path))))
        p.posix.joinAll(p.split(p.relative(p.absolute(path), from: base))),
  };
}

String _packageName(String packageRoot) {
  final match = RegExp(
    r'^name:\s*(\S+)',
    multiLine: true,
  ).firstMatch(File(p.join(packageRoot, 'pubspec.yaml')).readAsStringSync());
  if (match == null) fail('$packageRoot/pubspec.yaml declares no name');
  return match.group(1)!;
}

/// The Pro overlay this repository is checked out inside, if any. Its
/// package name is read from its pubspec rather than written here.
({String root, String package})? _overlayCheckout() {
  const root = '..';
  if (!File(p.join(root, 'lib', 'overrides.dart')).existsSync() ||
      !File(p.join(root, 'pubspec.yaml')).existsSync()) {
    return null;
  }
  return (root: root, package: _packageName(root));
}

int _lineCount(String file) => File(file).readAsLinesSync().length;
