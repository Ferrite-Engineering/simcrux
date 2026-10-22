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
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/services/remote/cxp/cxp_project_open_handle.dart';

import '../../../support/cxp_runtime_harness.dart';

// The `project` artifact kind (CXP 9.10.2): a SimCrux project is published
// and asked for as `project`, never `source`, which names one HDL file. For
// one release a project another product still records as `source` is read
// too, and a project in a format SimCrux does not read is refused.
//
// MUTATION: resolve `project` from `source` records only and the first case
// fails; drop the format check and the `.lintcrux` case opens a tab.

const PeerIdentity _peer = PeerIdentity(
  peerId: 'vscode-1-1',
  productName: 'vscode',
  productVersion: '1.2.0',
);

final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

void main() {
  late Directory manifests;
  late Directory records;
  late Directory design;
  late ProviderContainer container;
  late List<String> opened;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    manifests = cxpTestManifestDirectory();
    records = await Directory.systemTemp.createTemp('simcrux_project_ws_');
    design = await Directory.systemTemp.createTemp('simcrux_project_design_');
    container = simcruxCxpRuntimeContainer(
      manifestDirectory: manifests,
      extra: <Override>[
        cxpWorkspaceStoreProvider.overrideWithValue(
          CxpWorkspaceStore(workspaceDirectory: records.path),
        ),
      ],
    );
    addTearDown(container.dispose);
    opened = <String>[];
    container.read(cxpProjectOpenHandleProvider).opener = (path) async {
      opened.add(path);
      return true;
    };
  });

  tearDown(() async {
    for (final dir in <Directory>[records, design]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  File write(String name, String text) =>
      File(p.join(design.path, name))..writeAsStringSync(text);

  Future<void> record(
    String kind,
    String path, {
    String designId = 'd-project',
  }) => CxpWorkspaceStore(workspaceDirectory: records.path).upsertArtifact(
    designId: designId,
    kind: kind,
    path: path,
    producer: 'vscode',
  );

  Future<CruxCxpHandlerResult> ask(
    String kind, {
    String? hint,
    String designId = 'd-project',
  }) => SimcruxCxpRequestHandler(container.read(_refProvider)).openArtifact(
    RequestOpenArtifact(designId: designId, artifactKind: kind, path: hint),
    _peer,
  );

  test('a project recorded as project opens as a config tab', () async {
    final config = write('simcrux.yaml', 'suites: []\n');
    await record(kCxpProjectArtifactKind, config.path);
    final result = await ask(kCxpProjectArtifactKind);
    expect(result.honored, isTrue, reason: result.reason);
    expect(opened, <String>[config.path]);
  });

  test('a project another product still records as source is read for '
      'project, and project records answer a source request', () async {
    final config = write('simcrux.yaml', 'suites: []\n');
    await record(kCxpSourceArtifactKind, config.path);
    expect((await ask(kCxpProjectArtifactKind)).honored, isTrue);
    expect(opened, <String>[config.path]);

    await record(kCxpProjectArtifactKind, config.path, designId: 'd-new');
    expect(
      (await ask(kCxpSourceArtifactKind, designId: 'd-new')).honored,
      isTrue,
    );
    expect(opened, <String>[config.path, config.path]);
  });

  test('a project in a format SimCrux does not read is refused, and nothing '
      'opens', () async {
    final lint = write('design.lintcrux', '{}\n');
    final result = await ask(kCxpProjectArtifactKind, hint: lint.path);
    expect(result.honored, isFalse);
    expect(result.reason, isNot(contains(lint.path)));
    expect(result.reason, isNot(contains('d-project')));
    expect(opened, isEmpty);
  });

  test('nothing recorded and no hint: refused without the design', () async {
    final result = await ask(kCxpProjectArtifactKind);
    expect(result.honored, isFalse);
    expect(result.reason, isNot(contains('d-project')));
  });

  test('SimCrux publishes an open project as project, only while the '
      'server runs', () async {
    final config = write('simcrux.yaml', 'suites: []\n');
    final ref = container.read(_refProvider);
    await publishProjectWorkspaceArtifact(ref, config.path);
    final store = CxpWorkspaceStore(workspaceDirectory: records.path);
    final designId = cxpDesignIdForPath(config.path);
    expect(
      await store.resolveArtifactAsync(designId, kCxpProjectArtifactKind),
      isNull,
      reason: 'the harness server is not running',
    );
    final running = ProviderContainer(
      parent: container,
      overrides: [
        _refProvider.overrideWith((ref) => ref),
        cruxCxpServerStatusProvider.overrideWithValue((
          running: true,
          port: 54325,
          problem: null,
        )),
      ],
    );
    addTearDown(running.dispose);
    await publishProjectWorkspaceArtifact(
      running.read(_refProvider),
      config.path,
    );
    final artifact = await store.resolveArtifactAsync(
      designId,
      kCxpProjectArtifactKind,
    );
    expect(artifact?.path, config.path);
    expect(
      await store.resolveArtifactAsync(designId, kCxpSourceArtifactKind),
      isNull,
      reason: 'never as source',
    );
  });
}
