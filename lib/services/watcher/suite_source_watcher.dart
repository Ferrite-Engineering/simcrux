// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_file_watcher/crux_file_watcher.dart';
import 'package:simcrux/domain/models/regression_config.dart';

/// Aggregator that watches every source file declared by every test
/// in a [RegressionConfig] and emits a single debounced event when
/// any of them changes.
///
/// crux_file_watcher exposes a one-file-per-instance API; the suite
/// watcher fans that out to N [FileWatcherService] instances (one
/// per distinct source path) and unifies their streams behind one
/// public stream so the auto-rerun consumer only needs a single
/// subscription. Each underlying watcher already debounces at
/// 500 ms; the suite watcher doesn't add a second debounce window
/// — coalescing many concurrent change events into one rerun is the
/// AutoReloadMode notifier's job (it ignores subsequent ticks while
/// the dialog/snackbar prompt is open).
class SuiteSourceWatcher {
  /// Creates a [SuiteSourceWatcher].
  ///
  /// [serviceFactory] is injectable for tests so the watcher can be
  /// driven against scripted `FileWatcherService` fakes without
  /// touching the real file system.
  SuiteSourceWatcher({
    FileWatcherService Function()? serviceFactory,
  }) : _serviceFactory = serviceFactory ?? FileWatcherService.new;

  final FileWatcherService Function() _serviceFactory;
  final List<FileWatcherService> _services = <FileWatcherService>[];
  final List<StreamSubscription<FileWatchEvent>> _subscriptions =
      <StreamSubscription<FileWatchEvent>>[];
  final StreamController<SuiteSourceChange> _controller =
      StreamController<SuiteSourceChange>.broadcast();

  /// True once [dispose] has run.
  bool _disposed = false;

  /// Stream of file-change events across every watched source path.
  Stream<SuiteSourceChange> get events => _controller.stream;

  /// Number of files currently being watched.
  int get watchedPathCount => _services.length;

  /// Begins watching every distinct source path declared in [config].
  /// Stops any previously-watched files first.
  void watch(RegressionConfig config) {
    stop();
    if (_disposed) {
      throw StateError('SuiteSourceWatcher already disposed');
    }
    final paths = <String>{};
    for (final suite in config.suites) {
      for (final spec in suite.tests) {
        paths.addAll(spec.sources);
      }
    }
    for (final path in paths) {
      final service = _serviceFactory();
      _services.add(service);
      _subscriptions.add(
        service.events.listen(
          (event) => _onEvent(path, event),
        ),
      );
      service.startWatching(path);
    }
  }

  /// Stops every active watcher. Idempotent — safe to call from
  /// `ref.onDispose`.
  void stop() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    for (final svc in _services) {
      svc
        ..stopWatching()
        ..dispose();
    }
    _services.clear();
  }

  /// Stops everything and closes the broadcast stream.
  void dispose() {
    stop();
    _disposed = true;
    unawaited(_controller.close());
  }

  void _onEvent(String path, FileWatchEvent event) {
    if (_controller.isClosed) return;
    _controller.add(SuiteSourceChange(path: path, event: event));
  }
}

/// A single file change emitted by [SuiteSourceWatcher].
class SuiteSourceChange {
  /// Creates a [SuiteSourceChange].
  const SuiteSourceChange({required this.path, required this.event});

  /// The source file that changed.
  final String path;

  /// Underlying crux_file_watcher event.
  final FileWatchEvent event;
}
