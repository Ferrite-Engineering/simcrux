// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:isolate';

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

/// Regex-based pass/fail classifier.
///
/// Honors [RegexPassFailConfig]. Each pattern is compiled fresh on
/// every `detect` call — the per-test cost is negligible compared to
/// running the simulator, and it lets the config be hot-reloaded
/// without flushing a cache.
///
/// Precedence is identical to [StringMatchDetector]: a fail match
/// always wins (so a test that prints "expected: foo" and then
/// "ERROR: …" is still classified as a failure). A required
/// `passPattern` that never matches downgrades to [TestStatus.fail].
/// When only `failPattern` is configured and never fires, the
/// detector returns [TestStatus.unknown] so the scheduler can fall
/// back to the exit-code default.
///
/// Pattern semantics:
/// - Multi-line: the patterns are applied to the joined `stdout +
///   "\n" + stderr` blob with `multiLine: true` so `^` and `$` match
///   line boundaries.
/// - Case-sensitive by default. Dart's `RegExp` has no PCRE-style inline
///   flag group: `(?i)error` throws `FormatException: Invalid group`. The
///   scoped modifier form `(?i:error)` compiles and matches case-
///   insensitively, as does a character class (`[Ee]rror`).
/// - The project loader compiles every pattern and rejects one that does
///   not compile, with its file and line. As defence in depth, an
///   uncompilable pattern that reaches the detector anyway returns
///   [TestStatus.unknown] rather than crashing the regression.
class RegexDetector implements PassFailDetector {
  /// Const constructor.
  const RegexDetector({this.maxScanChars = kDefaultMaxScanChars});

  /// Default ceiling on the number of characters the regex is run
  /// against. A user-authored pattern with catastrophic backtracking
  /// against a multi-GB log can hang the regression; bounding the scan
  /// to the **tail** of the captured log (where the terminal
  /// pass/fail signal — the `UVM_ERROR` summary, the `$finish` banner —
  /// almost always lives) caps the matcher's worst-case work and the
  /// ReDoS exposure surface. The upstream `BoundedLogCapture` already
  /// line-bounds the capture; this additionally byte-bounds a single
  /// pathological line.
  static const int kDefaultMaxScanChars = 1 << 20; // 1 MiB

  /// The maximum number of trailing characters of the combined log the
  /// detector runs the regex against.
  final int maxScanChars;

  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    if (config is! RegexPassFailConfig) return TestStatus.unknown;

    final blob = _boundedBlob(stdout, stderr);

    final failPattern = config.failPattern;
    if (failPattern != null && failPattern.isNotEmpty) {
      final regex = _tryCompile(failPattern);
      if (regex == null) return TestStatus.unknown;
      if (regex.hasMatch(blob)) return TestStatus.fail;
    }

    final passPattern = config.passPattern;
    if (passPattern != null && passPattern.isNotEmpty) {
      final regex = _tryCompile(passPattern);
      if (regex == null) return TestStatus.unknown;
      if (regex.hasMatch(blob)) return TestStatus.pass;
      // Required pass-pattern not present ⇒ failure.
      return TestStatus.fail;
    }

    return TestStatus.unknown;
  }

  /// Async counterpart to [detect] that runs each pattern match under a
  /// killable-isolate [deadline] via [guardedRegexHasMatch], so a
  /// user-authored pattern with catastrophic (exponential) backtracking
  /// cannot freeze the calling isolate — the production classification
  /// path (see `PassFailDetectorRegistry.classifyAsync`) routes through
  /// here.
  ///
  /// Semantics are identical to [detect]: fail-match wins, a required
  /// `passPattern` that does not (conclusively) match downgrades to
  /// [TestStatus.fail], an uncompilable pattern degrades to
  /// [TestStatus.unknown], and the scan is bounded to the trailing
  /// [maxScanChars]. On deadline expiry [guardedRegexHasMatch] reports
  /// "no conclusive match", so a hung `failPattern` is treated as
  /// not-failed (classification falls back to the exit-code default) and
  /// a hung required `passPattern` downgrades to fail — the same outcome
  /// [detect] would produce for a pattern that simply did not match.
  Future<TestStatus> detectAsync({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
    Duration deadline = const Duration(seconds: 1),
  }) async {
    if (config is! RegexPassFailConfig) return TestStatus.unknown;

    final blob = _boundedBlob(stdout, stderr);

    final failPattern = config.failPattern;
    if (failPattern != null && failPattern.isNotEmpty) {
      // Compile on the calling isolate purely to distinguish an invalid
      // pattern (⇒ unknown) from a valid pattern that does not match; the
      // potentially-catastrophic *match* runs in the guarded isolate.
      if (_tryCompile(failPattern) == null) return TestStatus.unknown;
      if (await guardedRegexHasMatch(failPattern, blob, deadline: deadline)) {
        return TestStatus.fail;
      }
    }

    final passPattern = config.passPattern;
    if (passPattern != null && passPattern.isNotEmpty) {
      if (_tryCompile(passPattern) == null) return TestStatus.unknown;
      if (await guardedRegexHasMatch(passPattern, blob, deadline: deadline)) {
        return TestStatus.pass;
      }
      // Required pass-pattern not (conclusively) present ⇒ failure.
      return TestStatus.fail;
    }

    return TestStatus.unknown;
  }

  /// Combines [stdout]/[stderr] and bounds the matcher's input to the
  /// trailing [maxScanChars], so a catastrophic pattern cannot backtrack
  /// across an unbounded log. Shared by [detect] and [detectAsync].
  String _boundedBlob(String stdout, String stderr) {
    final full = '$stdout\n$stderr';
    return full.length > maxScanChars
        ? full.substring(full.length - maxScanChars)
        : full;
  }

  RegExp? _tryCompile(String pattern) {
    try {
      return RegExp(pattern, multiLine: true);
    } on FormatException {
      return null;
    }
  }
}

/// Runs `RegExp(pattern, multiLine: true).hasMatch(input)` in a worker
/// isolate under a hard wall-clock [deadline], killing the isolate if it
/// exceeds it.
///
/// `RegExp.hasMatch` is synchronous and cannot be interrupted in-isolate,
/// so a user-authored pattern with catastrophic (exponential)
/// backtracking would otherwise hang the whole regression. Off-loading
/// the match to a killable isolate is the only robust guard: on timeout
/// (or any error) this returns [onTimeout] (default `false` — "this
/// pattern did not conclusively match", so classification falls back to
/// the exit-code default) instead of blocking forever.
///
/// [RegexDetector] additionally bounds the *input* it scans
/// ([RegexDetector.maxScanChars]) on both its sync and async paths; this
/// guarded entry point is what [RegexDetector.detectAsync] — and thus the
/// scheduler's production classify path — runs the match through.
///
/// **Workers are pooled, not spawned per call.** Each classification
/// evaluates up to two patterns, so spawning per call would cost a 10k
/// -test regression ~20k isolates — each a fresh VM heap and event
/// loop, purely to run a match that virtually always completes in
/// microseconds. Matches lease an idle worker from [_regexPool] and
/// return it afterwards.
/// The killable-deadline guarantee is unchanged: a worker serves one
/// match at a time, so a worker killed for blowing its deadline takes
/// only its own pathological match down with it and is simply never
/// returned to the pool.
Future<bool> guardedRegexHasMatch(
  String pattern,
  String input, {
  Duration deadline = const Duration(seconds: 1),
  bool onTimeout = false,
}) => _regexPool.run(pattern, input, deadline: deadline, onTimeout: onTimeout);

/// Releases every idle pooled worker. Test hook: call it between test cases
/// so no isolate outlives the case that needed it. The app does not call it;
/// idle workers end with the process.
Future<void> shutdownRegexIsolatePool() => _regexPool.shutdown();

/// Number of idle workers currently parked in the pool. Test hatch for
/// the guard that asserts reuse actually happens.
int get debugRegexPoolIdleCount => _regexPool.idleCount;

final _RegexIsolatePool _regexPool = _RegexIsolatePool();

/// A small pool of long-lived matcher isolates.
class _RegexIsolatePool {
  /// Idle workers parked for reuse. Bounded so a burst of concurrent
  /// classifications does not leave dozens of isolates resident for the
  /// rest of the session.
  static const int _maxIdle = 4;

  final List<_RegexWorker> _idle = <_RegexWorker>[];

  /// Workers currently out on a lease (mid-[run]). Tracked so [shutdown]
  /// can reap the isolate serving an in-flight match, not just the parked
  /// idle ones — otherwise a leased worker outlives shutdown and, on
  /// completion, re-parks itself into a pool the shutdown believed empty.
  final Set<_RegexWorker> _leased = <_RegexWorker>{};

  /// Bumped by every [shutdown]. A lease captures it before spawning; if
  /// it changed by the time the match returns, a shutdown happened during
  /// the lease and the worker is never re-parked. Self-resetting, so the
  /// pool is fully reusable after a shutdown (shutdown is called between
  /// test cases, not only at app exit).
  int _generation = 0;

  int get idleCount => _idle.length;

  Future<bool> run(
    String pattern,
    String input, {
    required Duration deadline,
    required bool onTimeout,
  }) async {
    final gen = _generation;
    _RegexWorker worker;
    try {
      worker = _idle.isNotEmpty
          ? _idle.removeLast()
          : await _RegexWorker.spawn();
    } on Object {
      // Isolate spawn failed (resource exhaustion) — degrade to "no
      // conclusive match" exactly as a deadline expiry would.
      return onTimeout;
    }
    _leased.add(worker);
    final bool result;
    try {
      result = await worker.match(
        pattern,
        input,
        deadline: deadline,
        onTimeout: onTimeout,
      );
    } finally {
      _leased.remove(worker);
    }
    // Re-park only when no shutdown intervened (generation unchanged) and
    // the worker is still alive. A shutdown that raced this lease — even
    // one landing while spawn() was in flight, before _leased.add — bumped
    // the generation, so the worker is killed here instead of resurrecting
    // an isolate the shutdown believed it had reaped.
    if (gen == _generation && worker.isAlive) {
      if (_idle.length < _maxIdle) {
        _idle.add(worker);
      } else {
        worker.kill();
      }
    } else if (worker.isAlive) {
      worker.kill();
    }
    return result;
  }

  Future<void> shutdown() async {
    _generation++;
    for (final worker in _idle) {
      worker.kill();
    }
    _idle.clear();
    // Reap workers currently serving a match. Killing the isolate does not
    // hang the awaiting run(): its deadline timer still fires and resolves
    // the match. toList() guards against a concurrent lease return mutating
    // _leased during the walk.
    for (final worker in _leased.toList()) {
      worker.kill();
    }
    _leased.clear();
  }
}

/// One matcher isolate. Serves a single [match] at a time.
class _RegexWorker {
  _RegexWorker._(this._isolate, this._requests, this._responses);

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _responses;

  Completer<bool>? _pending;
  bool _alive = true;

  bool get isAlive => _alive;

  static Future<_RegexWorker> spawn() async {
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(_regexWorkerEntry, handshake.sendPort);
    final responses = ReceivePort();
    final requests = await handshake.first as SendPort;
    handshake.close();
    final worker = _RegexWorker._(isolate, requests, responses);
    responses.listen(worker._onResponse);
    return worker;
  }

  void _onResponse(Object? message) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _pending = null;
    pending.complete(message == true);
  }

  Future<bool> match(
    String pattern,
    String input, {
    required Duration deadline,
    required bool onTimeout,
  }) {
    final completer = Completer<bool>();
    _pending = completer;
    final timer = Timer(deadline, () {
      if (completer.isCompleted) return;
      _pending = null;
      // The match is wedged in an uninterruptible `hasMatch`; the only
      // way out is to destroy the isolate running it.
      kill();
      completer.complete(onTimeout);
    });
    try {
      _requests.send(<Object?>[_responses.sendPort, pattern, input]);
    } on Object {
      timer.cancel();
      _pending = null;
      kill();
      return Future<bool>.value(onTimeout);
    }
    return completer.future.whenComplete(timer.cancel);
  }

  void kill() {
    if (!_alive) return;
    _alive = false;
    _responses.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _regexWorkerEntry(SendPort handshake) {
  final requests = ReceivePort();
  handshake.send(requests.sendPort);
  requests.listen((message) {
    final args = message as List<Object?>;
    final replyTo = args[0]! as SendPort;
    final pattern = args[1]! as String;
    final input = args[2]! as String;
    bool result;
    try {
      result = RegExp(pattern, multiLine: true).hasMatch(input);
    } on Object {
      result = false;
    }
    replyTo.send(result);
  });
}
