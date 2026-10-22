// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/workspace/providers/recent_lists.dart';
import 'package:simcrux/services/remote/cxp/cxp_project_open_handle.dart';

import '../../../support/cxp_runtime_harness.dart';

/// CXP 1.3 section 9.11 and conformance item 22: the `reason` of a refusal
/// names the kind of refusal and nothing the sender supplied. Every refusal
/// path of [SimcruxCxpRequestHandler] is driven here with a request whose
/// path, design id, file name and kind name are unmistakable, and the
/// reason is searched for each of them.
///
/// MUTATION: interpolating `element.path`, a design id, an artifact kind or
/// a path into any reason in the handler turns the matching case red.
class _FailingLauncher implements EditorLauncher {
  @override
  String get template => 'stub';

  @override
  ({String executable, List<String> args})? composeCommand({
    required String filePath,
    int line = 1,
    int column = 1,
  }) => (executable: 'stub', args: const <String>[]);

  @override
  Future<bool> openSource({
    required String filePath,
    int line = 1,
    int column = 1,
  }) async => false;
}

const PeerIdentity _sender = PeerIdentity(
  peerId: 'reason-test-sender',
  productName: 'test',
  productVersion: '0.0.0',
);

final Provider<SimcruxCxpRequestHandler> _handlerProvider =
    Provider<SimcruxCxpRequestHandler>(SimcruxCxpRequestHandler.new);

/// The sentinel segments of [value] read as a path in either separator style:
/// the ones this test minted, which start with `zq` and cannot be a word a
/// reason uses for its own purposes.
Iterable<String> _segments(String value) =>
    value.split(RegExp(r'[/\\]')).where((s) => s.startsWith('zq'));

/// Fails when [result] is not a refusal or when its reason contains any of
/// [sent], whole or by path segment.
void _expectNothingEchoed(CruxCxpHandlerResult result, List<String> sent) {
  expect(result.honored, isFalse);
  final reason = result.reason;
  expect(reason, isNotNull);
  expect(reason, isNotEmpty);
  for (final value in sent) {
    expect(reason, isNot(contains(value)), reason: 'echoes "$value"');
    for (final segment in _segments(value)) {
      expect(reason, isNot(contains(segment)), reason: 'echoes "$segment"');
    }
  }
}

void main() {
  late Directory manifests;
  late Directory inside;
  late Directory records;
  late ProviderContainer container;
  late SimcruxCxpRequestHandler handler;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    manifests = cxpTestManifestDirectory();
    inside = await Directory.systemTemp.createTemp('zqsimcrux_reason_in_');
    records = await Directory.systemTemp.createTemp('zqsimcrux_reason_ws_');
    container = simcruxCxpRuntimeContainer(
      manifestDirectory: manifests,
      extra: <Override>[
        editorLauncherProvider.overrideWithValue(_FailingLauncher()),
        cxpWorkspaceStoreProvider.overrideWithValue(
          CxpWorkspaceStore(workspaceDirectory: records.path),
        ),
      ],
    );
    addTearDown(container.dispose);
    final recents = container.read(recentProjects.provider.notifier);
    await recents.restored;
    recents.markOpened(p.join(inside.path, 'simcrux.yaml'));
    handler = container.read(_handlerProvider);
  });

  tearDown(() async {
    for (final dir in <Directory>[inside, records]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  group('request_highlight refusals', () {
    Future<CruxCxpHandlerResult> highlight(
      ElementId element, {
      Map<String, Object?> metadata = const <String, Object?>{},
    }) => handler.highlight(
      RequestHighlight(element: element, metadata: metadata),
      _sender,
    );

    test('a test that is not in the active project', () async {
      const path = 'zqsuite/zqtest_missing';
      final result = await highlight(
        const ElementId(kind: ElementKind.test, path: path),
      );
      _expectNothingEchoed(result, <String>[path]);
    });

    test('an element kind this build does not model', () async {
      const path = 'zqtop.zqdut.zqthing';
      final result = await highlight(
        ElementId(kind: ElementKind('zqkind_unheard'), path: path),
      );
      _expectNothingEchoed(result, <String>[path, 'zqkind_unheard']);
    });

    test('a breakpoint', () async {
      const path = '/zqabs/zqtb_x.v:42';
      final result = await highlight(
        const ElementId(kind: ElementKind.breakpoint, path: path),
      );
      _expectNothingEchoed(result, <String>[path]);
    });

    test('a marker and a rule', () async {
      const path = 'zqmarker/zqrule_a';
      for (final kind in <ElementKind>[
        ElementKind.marker,
        ElementKind.rule,
      ]) {
        final result = await highlight(ElementId(kind: kind, path: path));
        _expectNothingEchoed(result, <String>[path]);
      }
    });

    test('a test whose design id names no recorded source', () async {
      const path = 'zqsuite/zqtest_missing';
      const designId = 'zqdesign-id-0123456789abcdef';
      final result = await highlight(
        const ElementId(kind: ElementKind.test, path: path),
        metadata: <String, Object?>{cxpDesignIdMetadataKey: designId},
      );
      _expectNothingEchoed(result, <String>[path, designId]);
    });
  });

  group('request_open_artifact refusals', () {
    Future<CruxCxpHandlerResult> open({
      required String designId,
      String artifactKind = kCxpSourceArtifactKind,
      String? path,
    }) => handler.openArtifact(
      RequestOpenArtifact(
        designId: designId,
        artifactKind: artifactKind,
        path: path,
      ),
      _sender,
    );

    String under(String relative) => p.join(inside.path, relative);

    test('a kind SimCrux does not open', () async {
      const designId = 'zqdesign-kind-0123456789abcdef';
      final result = await open(
        designId: designId,
        artifactKind: 'zqkind_artifact',
        path: under('zqdir/zqwave.vcd'),
      );
      _expectNothingEchoed(result, <String>[
        designId,
        'zqkind_artifact',
        under('zqdir/zqwave.vcd'),
      ]);
    });

    test('a design with no recorded artifact and no hint', () async {
      const designId = 'zqdesign-unrecorded-0123456789';
      final result = await open(designId: designId);
      _expectNothingEchoed(result, <String>[designId]);
    });

    test('a hint outside the directories the user has opened', () async {
      const designId = 'zqdesign-outside-0123456789ab';
      final outside = p.normalize(p.absolute('/zqoutside/zqevil.sv'));
      final result = await open(designId: designId, path: outside);
      _expectNothingEchoed(result, <String>[designId, outside]);
    });

    test('a hint that is not an absolute path', () async {
      const designId = 'zqdesign-relative-0123456789a';
      const hint = 'zqrelative/zqfile.sv';
      final result = await open(designId: designId, path: hint);
      _expectNothingEchoed(result, <String>[designId, hint]);
    });

    test('a source file the editor fails to open', () async {
      const designId = 'zqdesign-editor-0123456789abc';
      final hint = under('zqrtl/zqtop.sv');
      final result = await open(designId: designId, path: hint);
      _expectNothingEchoed(result, <String>[designId, hint]);
    });

    test('a project file that is not here', () async {
      const designId = 'zqdesign-project-0123456789ab';
      final hint = under('zqmissing/zqconfig.yaml');
      final result = await open(designId: designId, path: hint);
      _expectNothingEchoed(result, <String>[designId, hint]);
    });

    test('a project file the opener declines', () async {
      const designId = 'zqdesign-declined-0123456789a';
      final config = File(under('zqproject/zqconfig.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('version: "1"\n');
      container.read(cxpProjectOpenHandleProvider).opener = (_) async => false;
      final result = await open(designId: designId, path: config.path);
      _expectNothingEchoed(result, <String>[designId, config.path]);
    });

    test('a design manifest SimCrux cannot use', () async {
      const designId = 'zqdesign-manifest-0123456789a';
      final manifest = File(under('zqmanifest/zqdesign.crux-project'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}\n');
      final result = await open(designId: designId, path: manifest.path);
      _expectNothingEchoed(result, <String>[designId, manifest.path]);
    });
  });

  group('request_open_source refusals', () {
    test('a file outside the directories the user has opened', () async {
      final outside = p.normalize(p.absolute('/zqoutside/zqpasswd.sv'));
      final result = await handler.openSource(
        RequestOpenSource(filePath: outside, line: 1),
        _sender,
      );
      _expectNothingEchoed(result, <String>[outside]);
    });

    test('a file the editor fails to open', () async {
      final file = p.join(inside.path, 'zqrtl', 'zqalu.sv');
      final result = await handler.openSource(
        RequestOpenSource(filePath: file, line: 1),
        _sender,
      );
      _expectNothingEchoed(result, <String>[file]);
    });
  });
}
