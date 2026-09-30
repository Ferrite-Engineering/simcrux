// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/cli_args_provider.dart';
import 'package:simcrux/core/platform/incoming_file_service.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/widgets/open_config_tab.dart';

/// Sits near the app root and opens any `simcrux.yaml` files passed
/// on the command line as workspace tabs on first frame, then every file
/// macOS opens on the app's behalf (a Finder double-click, `open -a`, a
/// drop on the Dock icon) by the same route, for as long as it is mounted.
///
/// A file from Finder has no flag to say what it is, so it is routed by
/// extension to the argument that would have opened it: a
/// `.simcrux-workspace` as `--workspace`, anything else as a positional
/// path. Both reach the same code the command line does, so a
/// double-clicked project loads through the same config loader and
/// project-tooling gate, and arms its tab without running it unless the
/// user turned on running on open. See [IncomingFileService].
///
/// A positional `<design>.crux-project` manifest, or a design directory
/// holding one, opens the `simulation` config the manifest names, with the
/// same feedback the Open dialogs give (see [openConfigAsTab]).
///
/// The workspace owns the dashboard; each positional CLI argument
/// becomes a tab, and the per-tab `RegressionTabContent` arms the
/// regression runner inside the tab's per-tab `ProviderContainer` when
/// the tab first becomes visible.
///
/// One-shot: the `_started` guard means this widget only opens tabs
/// once per app lifetime. The trigger fires inside a post-frame
/// callback so the [ProviderScope] is fully available by the time the
/// workspace notifier mutates.
class CliRegressionBootstrapper extends ConsumerStatefulWidget {
  /// Creates a [CliRegressionBootstrapper].
  const CliRegressionBootstrapper({required this.child, super.key});

  /// The widget rendered after the bootstrap kick-off — typically the
  /// app's [MaterialApp.router].
  final Widget child;

  @override
  ConsumerState<CliRegressionBootstrapper> createState() =>
      _CliRegressionBootstrapperState();
}

class _CliRegressionBootstrapperState
    extends ConsumerState<CliRegressionBootstrapper> {
  bool _started = false;

  /// Files macOS opens on the app's behalf, subscribed once the command
  /// line has been handled. Cancelled with this state, so a remount (see
  /// [_maybeStart]) hands the stream to the state that replaces it.
  StreamSubscription<void>? _openedFiles;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  Future<void> _maybeStart() async {
    // **This can fire against a disposed state, and on a first run it always
    // does.** The EULA gate above this widget renders its child unchanged
    // until its acceptance store resolves, then returns a `Stack` with the
    // child inside it. That reparents this subtree, so the element holding
    // this state is destroyed and a fresh one built — while the callback
    // `initState` armed is still queued. `ConsumerState.ref` dereferences
    // `State.context`, which is null once disposed, so it threw
    // `Null check operator used on a null value` before reading a single
    // argument.
    //
    // It is deterministic rather than racy because the callback is armed
    // during Flutter's WARM-UP frame and delivered by a timer afterwards, by
    // which point the store has resolved and the gate has already swapped.
    // A second launch never reproduced it: with the EULA accepted the gate
    // returns the child unchanged, nothing reparents, and this state survives
    // its own callback. That is why it reached the day of the public flip —
    // and it is the exact flow the READMEs teach, since "Try it" tells a new
    // reader to pass a file and a new reader has not accepted the EULA yet.
    //
    // Returning early is the whole fix: the remount re-arms `initState`, and
    // that second state does the work. Measured, not assumed — on the
    // crashing build the named project opened anyway, so the recovery path
    // was already live and only the noise was missing a guard. `_started` is
    // deliberately left unset here, because setting it before returning would
    // be the version of this that really does swallow the project.
    if (!mounted) return;
    if (_started) return;
    _started = true;
    final args = ref.read(cliArgsProvider);
    final notifier = ref.read(workspaceProvider.notifier);

    // --workspace runs first so positional configs append to the
    // already-loaded workspace shape.
    final wsPath = args.workspacePath;
    if (wsPath != null && wsPath.isNotEmpty) {
      try {
        await notifier.loadFrom(wsPath);
      } on Object {
        // Best-effort; the service returns Workspace.empty on
        // malformed files and the empty-canvas state surfaces.
      }
    }

    // Positional configs become one tab apiece.
    for (final path in args.projectPaths) {
      // Re-checked each iteration, not once above the loop: `ref` is a getter
      // that revalidates the element on every call, and the awaits in this
      // method are all points at which the gate can swap underneath us.
      if (!mounted) return;
      // One `project.opened` event per path, not one per launch: two configs
      // on the command line is two projects opened, and coalescing folds
      // them into a single row with `count: 2` anyway. The command line does
      // not touch the recents list.
      await openConfigAsTab(
        ref: ref,
        context: mounted ? context : null,
        rawPath: path,
        source: 'cli',
        addToRecents: false,
      );
    }

    // --session opens one additional tab whose config path is the given
    // path itself. The session document is not parsed — nothing reads the
    // config path it carries, and selection and filter chips are not
    // restored — which is what `--session`'s help says.
    final sessionPath = args.sessionPath;
    if (sessionPath != null && sessionPath.isNotEmpty) {
      // `notifier` was captured while mounted, so this call is safe without a
      // further `ref` read — but bail anyway rather than mutate a workspace
      // whose owning tree is gone.
      if (!mounted) return;
      await notifier.openTab(
        displayName: p.basename(sessionPath),
        payload: SimcruxTabPayload(configPath: sessionPath),
      );
    }

    // After the command line, so a launch that has both opens the argv tabs
    // first, as a second positional path would. Subscribed here, in the
    // state that got past the `mounted` check, and not in `initState`: the
    // native side hands the launch file out once, and a state the EULA gate
    // is about to discard would take it with it.
    //
    // One at a time, as the command line's loop does: two files from one
    // Finder selection arrive back to back, and two concurrent tab opens
    // each start from the same workspace, so the second would overwrite the
    // first. `asyncMap` holds the next path until the previous open is done.
    if (!mounted) return;
    _openedFiles = ref
        .read(incomingFileServiceProvider)
        .openedFiles()
        .asyncMap(_openIncoming)
        .listen(
          null,
          onError: (Object error, StackTrace stack) =>
              _log.warning('Could not open a file macOS sent', error, stack),
        );
  }

  /// Opens a file macOS delivered, by the route its command-line spelling
  /// takes.
  Future<void> _openIncoming(String path) async {
    if (!mounted) return;
    if (p.extension(path).toLowerCase() == kSimcruxWorkspaceExtension) {
      // `--workspace <path>`.
      try {
        await ref.read(workspaceProvider.notifier).loadFrom(path);
      } on Object catch (error) {
        // As for `--workspace`: the workspace keeps what it had. Logged
        // rather than dropped, so an issue report says why nothing opened.
        _log.warning('Could not open the workspace $path: $error');
      }
      return;
    }
    // A positional path: a `simcrux.yaml`, a `.crux-project` manifest or a
    // `.simcrux-session`, told apart by `openConfigAsTab` itself.
    await openConfigAsTab(
      ref: ref,
      context: mounted ? context : null,
      rawPath: path,
      source: 'cli',
      addToRecents: false,
    );
  }

  @override
  void dispose() {
    unawaited(_openedFiles?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The extension of a named workspace document, as `--workspace` takes it.
const String kSimcruxWorkspaceExtension = '.simcrux-workspace';

final _log = Logger('simcrux.platform');
