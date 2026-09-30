// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

import '../../../support/answered_telemetry.dart';

/// `request_open_artifact` from VS Code's "Open in SimCrux Desktop": the
/// extension publishes the workspace's `simcrux.yaml` as a `source` artifact
/// and sends it. SimCrux must open it the way File → Open Project does, as a
/// config tab. It used to hand every `source` path to the external editor
/// launcher (by default `code --goto …`), so the YAML came back to VS Code as
/// text while the ack said it was honoured.
///
/// A project open is held to the floor — absolute, well-formed, the exact
/// string opened — and not to the directories the user has opened, so a
/// config SimCrux has never seen opens. A `source` artifact that is not a
/// project still goes to the editor, under the roots
/// (`kCxpOpenArtifactContainment` says why the two differ). The
/// `crux.design_id` fallback keeps the roots too; its tests are in
/// `inbound_request_handler_test.dart`.
///
/// Everything runs through the production handler, the production roots
/// (the recent-projects list) and the production project opener the handler
/// publishes. Most tests put a server in front of it that admits every path,
/// so a refusal is the handler's own; the last group goes through the
/// production wire screen.
void main() {
  late Directory opened;
  late Directory never;
  late Directory storeDir;
  late Directory workspaceDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    opened = Directory.systemTemp.createTempSync('simcrux_artifact_opened_');
    never = Directory.systemTemp.createTempSync('simcrux_artifact_never_');
    storeDir = Directory.systemTemp.createTempSync('simcrux_artifact_store_');
    workspaceDir = Directory.systemTemp.createTempSync('simcrux_artifact_ws_');
    // An honoured open nudges the window's attention; these binding-less
    // `dart:test` cases would throw on the platform channel.
    windowAttentionRequester = const NoopWindowAttentionRequester();
  });

  tearDown(() {
    windowAttentionRequester = const MethodChannelWindowAttentionRequester();
    <Directory>[opened, never, storeDir, workspaceDir].forEach(_deleteQuietly);
  });

  File file(Directory dir, String name, [String text = 'suites: []\n']) =>
      File(p.join(dir.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);

  Future<void> record(String designId, String path) =>
      CxpWorkspaceStore(workspaceDirectory: storeDir.path).upsertArtifact(
        designId: designId,
        kind: kCxpSourceArtifactKind,
        path: path,
        producer: 'vscode',
      );

  /// The app, with a config in [opened] among the recent projects (the
  /// roots), a connected client, and a stub editor launcher. With
  /// [productionWire] the server is the one `cxpServerFactoryProvider`
  /// builds; otherwise it admits every path, so the handler's own checks are
  /// what is tested.
  Future<_App> boot({bool productionWire = false}) async {
    if (productionWire) {
      // The production factory binds the configured port, so configure a
      // free one rather than collide with a running SimCrux.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simcrux.cxpServerPort': port,
      });
    }
    final launcher = _StubLauncher();
    final container = ProviderContainer(
      overrides: <Override>[
        ...answeredTelemetryOverrides(),
        if (!productionWire)
          cxpServerFactoryProvider.overrideWithValue(
            ({required selfIdentity, required port}) => SimCruxCxpServer(
              selfIdentity: selfIdentity,
              port: 0,
              containment: const _AdmitEveryPath(),
            ),
          ),
        editorLauncherProvider.overrideWithValue(launcher),
        // The production store, pointed at a temp directory and carrying
        // the production rule.
        cxpWorkspaceStoreProvider.overrideWith(
          (ref) => CxpWorkspaceStore(
            workspaceDirectory: storeDir.path,
            containment: ref.watch(cxpPathContainmentProvider),
          ),
        ),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => workspaceDir,
          ),
        ),
      ],
    );
    addTearDown(() async {
      await container.read(workspaceProvider.notifier).flushPendingSave();
      container.dispose();
    });
    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .addRecentProject(file(opened, 'simcrux.yaml').path);
    await container.read(workspaceProvider.future);
    final server = await container.read(cxpServerProvider.future);
    expect(server, isNotNull);
    // Anchor the handler, as the app does. It publishes the project opener.
    container.read(inboundRequestHandlerProvider);
    final client = LocalCxpClient(
      selfIdentity: const PeerIdentity(
        peerId: 'vscode-open-artifact-test',
        productName: 'vscode',
        productVersion: '0.0.0-test',
      ),
    );
    await client.connect(
      host: '127.0.0.1',
      port: server!.boundPort!,
      token: cxpProcessAuthToken,
    );
    addTearDown(client.dispose);
    return _App(container, client, launcher);
  }

  group('a SimCrux project', () {
    // The defect: this went to the editor launcher, and so back to VS Code as
    // text. MUTATION, each measured: sending every path to
    // `_openSourceInEditor` instead of `_openProjectForPeer` makes this red;
    // so does holding `_openProjectForPeer` to the roots.
    test('a simcrux.yaml never opened, sent as a hint, opens as a config tab, '
        'and no editor runs', () async {
      final config = file(never, 'simcrux.yaml');
      final app = await boot();
      expect(
        app.container.read(cxpPathContainmentProvider).allows(config.path),
        isFalse,
        reason: 'the premise: the roots would refuse this config',
      );
      final ack = await app.ask(hint: config.path);
      expect(ack.honored, isTrue, reason: ack.reason);
      expect(app.tabs(), <String>[config.path]);
      expect(app.launcher.calls, isEmpty);
    });

    // Inside the roots, an editor launch would be admitted, so only the
    // route decides. MUTATION: sending every path to `_openSourceInEditor`
    // makes this red.
    test('a simcrux.yaml inside the opened directories opens as a config '
        'tab, not in the editor', () async {
      final config = file(opened, 'regress.yml');
      final app = await boot();
      final ack = await app.ask(hint: config.path);
      expect(ack.honored, isTrue, reason: ack.reason);
      expect(app.tabs(), <String>[config.path]);
      expect(app.launcher.calls, isEmpty);
    });

    // The extension publishes the config before it sends, so this is the
    // path its hand-off normally takes. The store the app provides is rooted
    // and would drop the record. MUTATION: resolving through
    // `resolveSourceArtifactPath` (the rooted store) in
    // `_handleRequestOpenArtifact` makes this red.
    test('a recorded config never opened opens, though the rooted store '
        'drops the record', () async {
      final config = file(never, 'simcrux.yaml');
      await record('d-never', config.path);
      final app = await boot();
      expect(
        resolveSourceArtifactPath(app.ref, 'd-never'),
        isNull,
        reason: 'the premise: the rooted store drops this record',
      );
      final ack = await app.ask(designId: 'd-never');
      expect(ack.honored, isTrue, reason: ack.reason);
      expect(app.tabs(), <String>[config.path]);
    });

    // As File → Open Project does: the user asked for this project. And a
    // second hand-off focuses the tab rather than stacking another.
    test('the config joins the recent projects, and a second hand-off does '
        'not open a second tab', () async {
      final config = file(never, 'simcrux.yaml');
      final app = await boot();
      expect((await app.ask(hint: config.path)).honored, isTrue);
      expect((await app.ask(hint: config.path)).honored, isTrue);
      expect(app.tabs(), <String>[config.path]);
      expect(
        app.container.read(appSettingsProvider).value?.recentProjectPaths,
        contains(config.path),
      );
    });

    // A `<design>.crux-project` is swapped for its config before the open,
    // and the floor judges the swapped path; the opener is handed the config
    // and swaps nothing, so the string checked is the string opened.
    // MUTATION: handing the opener `path` rather than the swapped `config`
    // in `_openProjectForPeer` makes this red.
    test('a design manifest opens the config it names', () async {
      final config = file(never, 'simcrux.yaml');
      final manifest = file(
        never,
        'design.crux-project',
        'version: 1\nartifacts:\n  simulation: simcrux.yaml\n',
      );
      final app = await boot();
      final ack = await app.ask(hint: manifest.path);
      expect(ack.honored, isTrue, reason: ack.reason);
      // The manifest's directory comes back canonical (`/var` is
      // `/private/var` on macOS), so the two are compared resolved.
      expect(app.tabs(), hasLength(1));
      expect(
        File(app.tabs().single).resolveSymbolicLinksSync(),
        config.resolveSymbolicLinksSync(),
      );
    });

    // MUTATION: deleting the `isSimcruxConfigPath(config)` refusal in
    // `_openProjectForPeer` opens a tab on a file that is not a config, and
    // this goes red.
    test('a design manifest that names something other than a config is '
        'refused', () async {
      file(never, 'notes.txt');
      final manifest = file(
        never,
        'design.crux-project',
        'version: 1\nartifacts:\n  simulation: notes.txt\n',
      );
      final app = await boot();
      final ack = await app.ask(hint: manifest.path);
      expect(ack.honored, isFalse);
      expect(ack.reason, 'the design manifest does not name a SimCrux config');
      expect(app.tabs(), isEmpty);
    });

    // A tab for a missing config would hold nothing but an error. MUTATION:
    // deleting the `FileSystemEntity` check in `_openProjectForPeer` makes
    // this red.
    test('a hint naming no file here is declined, and no tab opens', () async {
      final app = await boot();
      final ack = await app.ask(hint: p.join(never.path, 'simcrux.yaml'));
      expect(ack.honored, isFalse);
      expect(ack.reason, 'the artifact is not a file here');
      expect(app.tabs(), isEmpty);
    });

    // The floor is what stands between a peer and a project open, so each of
    // its refusals is pinned by a case only it can refuse.
    group('the floor refuses', () {
      // Relative to where SimCrux runs, this names a real config, so nothing
      // after the floor would stop it. MUTATION: deleting the
      // `kCxpOpenArtifactContainment.refuse(path)` check in
      // `_handleRequestOpenArtifact` opens it, and this goes red.
      //
      // The file sits under the working directory (in its ignored
      // `.dart_tool`), not the system temp directory: on Windows the two can
      // be on different drives, and no relative path leads from one drive to
      // another.
      test('a relative path, even one naming a file from where SimCrux '
          'runs', () async {
        final here = Directory(
          p.join(Directory.current.path, '.dart_tool'),
        ).createTempSync('simcrux_relative_');
        addTearDown(() => _deleteQuietly(here));
        final relative = p.relative(file(here, 'relative.yaml').path);
        expect(p.isRelative(relative), isTrue);
        expect(
          FileSystemEntity.typeSync(relative),
          FileSystemEntityType.file,
          reason: 'the case must name a real file, or it proves nothing',
        );
        final app = await boot();
        final ack = await app.ask(hint: relative);
        expect(ack.honored, isFalse);
        expect(ack.reason, 'file_path must be an absolute path');
        expect(app.tabs(), isEmpty);
      });

      // A NUL ends the name where the operating system reads it, so what was
      // checked is not what would be opened.
      test('a path carrying a NUL', () async {
        final config = file(never, 'simcrux.yaml');
        final app = await boot();
        for (final hint in <String>[
          '${config.path} ',
          '${config.path} .txt',
          '${never.path} /simcrux.yaml',
        ]) {
          final ack = await app.ask(hint: hint);
          expect(ack.honored, isFalse, reason: 'hint ${hint.codeUnits}');
          expect(ack.reason, 'file_path contains a NUL character');
        }
        expect(app.tabs(), isEmpty);
      });

      // The string checked is the string opened. A trailing space is part of
      // a POSIX file name, so `padded.yaml ` is a real file here and a
      // different one from `padded.yaml`; a check that trimmed first would
      // pass the one name and open the other. The shared floor refuses a
      // padded path itself, in its own words, so SimCrux adds no clause of
      // its own. MUTATION: deleting the `kCxpOpenArtifactContainment.refuse`
      // check in `_handleRequestOpenArtifact` makes this red.
      test('a path padded with white space, though the padded name is a real '
          'file', () async {
        file(never, 'padded.yaml');
        final trailing = file(never, 'padded.yaml ').path;
        expect(
          FileSystemEntity.typeSync(trailing),
          FileSystemEntityType.file,
          reason: 'the case must name a real file, or it proves nothing',
        );
        final plain = p.join(never.path, 'padded.yaml');
        final app = await boot();
        for (final hint in <String>[trailing, ' $plain', '$plain\t']) {
          final ack = await app.ask(hint: hint);
          expect(ack.honored, isFalse, reason: 'hint ${hint.codeUnits}');
          expect(ack.reason, 'file_path begins or ends with white space');
        }

        // The same name arriving as a record rather than a hint. The store
        // reads records under the same floor, so it drops this one before
        // the handler sees a path, and with no hint there is nothing to open.
        await record('d-padded', trailing);
        final ack = await app.ask(designId: 'd-padded');
        expect(ack.honored, isFalse);
        expect(ack.reason, 'no source artifact recorded for design "d-padded"');
        expect(app.tabs(), isEmpty);
      });
    });
  });

  // An editor launch is a different risk from a parse, and keeps the roots
  // (`kCxpOpenArtifactContainment` says why).
  group('a source file that is not a project', () {
    test('inside the opened directories, opens in the editor', () async {
      final source = file(opened, 'rtl/top.sv', 'module top; endmodule\n');
      final app = await boot();
      final ack = await app.ask(hint: source.path);
      expect(ack.honored, isTrue, reason: ack.reason);
      expect(app.launcher.calls, <String>[source.path]);
      expect(app.tabs(), isEmpty);
    });

    // Where a project would open, a source file does not. MUTATION: dropping
    // the rooted check from `_openSourceInEditor` makes this red.
    test('never opened, is refused under the roots, and no editor runs, '
        'though a project there would open', () async {
      final source = file(never, 'rtl/top.sv', 'module top; endmodule\n');
      await record('d-source', source.path);
      final app = await boot();
      final ack = await app.ask(designId: 'd-source');
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('outside the directories'));
      expect(ack.reason, isNot(contains(source.path)));
      expect(app.launcher.calls, isEmpty);
    });
  });

  group('through the production wire screen', () {
    // `LocalCxpServer` screens the hint before the handler sees it, and a
    // rooted screen there strips the hint for a config never opened; no
    // record is written, so the hint is all the handler has. MUTATION:
    // handing `SimCruxCxpServer` `cxpPathContainmentProvider` in
    // `cxpServerFactoryProvider` makes this red.
    test('a simcrux.yaml never opened crosses the wire and opens as a config '
        'tab', () async {
      final config = file(never, 'simcrux.yaml');
      final app = await boot(productionWire: true);
      final ack = await app.ask(hint: config.path);
      expect(ack.honored, isTrue, reason: ack.reason);
      expect(app.tabs(), <String>[config.path]);
      expect(app.launcher.calls, isEmpty);
    });

    // The wire does not root an editor launch either; the handler does.
    test('a source file never opened crosses the wire and is refused by the '
        'handler', () async {
      final source = file(never, 'rtl/top.sv', 'module top; endmodule\n');
      final app = await boot(productionWire: true);
      final ack = await app.ask(hint: source.path);
      expect(ack.honored, isFalse);
      expect(ack.reason, contains('outside the directories'));
      expect(app.launcher.calls, isEmpty);
    });
  });
}

/// The app under test, and what a test asks of it.
class _App {
  _App(this.container, this.client, this.launcher);

  final ProviderContainer container;
  final LocalCxpClient client;
  final _StubLauncher launcher;

  /// The root [Ref], for the workspace-link functions production calls.
  Ref get ref => container.read(_refProvider);

  /// Sends `request_open_artifact` for [designId] with [hint], and returns
  /// the ack.
  Future<RequestOpenArtifactAck> ask({
    String designId = 'unrecorded',
    String? hint,
  }) async {
    final reply = client.inbound.firstWhere(
      (m) => m.message is RequestOpenArtifactAck,
    );
    client.send(
      RequestOpenArtifact(
        designId: designId,
        artifactKind: kCxpSourceArtifactKind,
        path: hint,
      ),
    );
    return (await reply.timeout(const Duration(seconds: 5))).message
        as RequestOpenArtifactAck;
  }

  /// The config every workspace tab holds, in tab order.
  List<String> tabs() => <String>[
    for (final tab
        in container.read(workspaceProvider).value?.tabs ??
            const <crux.WorkspaceTab<SimcruxTabPayload>>[])
      tab.payload.configPath,
  ];
}

/// Provider exposing the container's [Ref].
final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

/// A wire screen that admits every path, so a refusal can only be the
/// handler's own.
class _AdmitEveryPath extends CxpPathContainment {
  const _AdmitEveryPath();

  @override
  String? refuse(String path) => null;
}

/// Records the files it is asked to open; never spawns anything.
class _StubLauncher implements EditorLauncher {
  final List<String> calls = <String>[];

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
  }) async {
    calls.add(filePath);
    return true;
  }
}

/// Deletes [dir], tolerating a writer that is still finishing in it.
void _deleteQuietly(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Best effort.
  }
}
