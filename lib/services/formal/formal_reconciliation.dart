// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/services/formal/formal_containment.dart';
import 'package:simcrux/services/formal/sby_status_database.dart';
import 'package:simcrux/services/formal/sby_status_reader.dart';

/// One property of one task, after reconciliation.
@immutable
class FormalPropertyResult {
  /// Creates a result.
  const FormalPropertyResult({
    required this.task,
    required this.kind,
    required this.location,
    required this.rawLocation,
    required this.name,
    required this.status,
    this.label,
    this.file,
    this.line,
    this.step,
    this.trace,
  });

  /// The `[tasks]` name.
  final String task;

  /// `ASSERT`, `COVER`, ….
  final String kind;

  /// The location, project-root-relative when it resolves inside the
  /// project, else as `sby` spelled it.
  final String location;

  /// The location exactly as `sby` spelled it.
  final String rawLocation;

  /// The hierarchical name `sby` reported.
  final String name;

  /// What the reconciled records support.
  final FormalPropertyStatus status;

  /// The user's label, when the frontend kept one (yosys-slang does; the
  /// built-in frontend mangles names into `_witness_.check_…`).
  final String? label;

  /// The source file part of [location].
  final String? file;

  /// The source line.
  final int? line;

  /// The counterexample's or the cover witness's step.
  final int? step;

  /// The trace the records named, verbatim.
  final String? trace;

  /// The identity within a run: task, kind and location.
  String get key => '$task\u0000$kind\u0000$location';

  /// The name to show: the label, else `kind @ file:line`.
  String get displayName {
    final own = label;
    if (own != null) return own;
    final where = file == null ? location : '$file:${line ?? '?'}';
    return '${kind.toLowerCase()} @ $where';
  }

  /// The identity across runs. The label when there is one; for an
  /// unlabelled property, null until the shared `crux-fnv1a64/1` signature
  /// over task, kind, file and normalised property text is available.
  String? get crossRunIdentity => label;
}

/// The outcome of reconciling a task's `DONE (…)` verdict with its
/// per-property statuses.
@immutable
class FormalReconciliation {
  /// Creates a reconciliation.
  const FormalReconciliation({
    required this.properties,
    required this.verdict,
    required this.taskVerdict,
    required this.disagreement,
    required this.truncated,
  });

  /// Applies the agreement rule (VERIFICATION_GUIDE.md §26.8).
  ///
  /// - The log's `DONE (…)` verdict is the task verdict.
  /// - The status stream ([live]) is the primary per-property source;
  ///   `status.sqlite` ([database]) supplies properties the stream never
  ///   mentioned and is compared with it. Where the two give different
  ///   statuses for one property, the more conservative one is kept and the
  ///   disagreement recorded.
  /// - A checked property with no record at all is Did not run under a task
  ///   that said `PASS`, and undecided otherwise.
  /// - When the task said `PASS` and any property did not end proved or
  ///   reached, the row verdict becomes the properties' most conservative
  ///   fact. When the task said anything else, its verdict stands. In both
  ///   cases a difference of bucket is recorded as a disagreement.
  ///
  /// Only the kinds the proof mode checks count: covers in `cover` mode,
  /// everything else otherwise (`status.sqlite` declares a design's cover
  /// statements in a `prove` task too, and they are never checked there).
  factory FormalReconciliation.reconcile({
    required FormalVerdict taskVerdict,
    required String? proofMode,
    required SbyStatusReader live,
    SbyStatusSnapshot? database,
    Map<String, String> files = const <String, String>{},
    String? sbyDirectory,
    String? projectRoot,
  }) {
    // What the records say first: `sby` writes the task's own mode on every
    // one, while [proofMode] is read from the `.sby` file without regard to
    // task scoping.
    final mode = live.mode ?? _modeOf(database) ?? proofMode;
    // Assumptions and fairness constraints are inputs to a proof, never
    // results of one.
    bool checked(String kind) {
      final upper = kind.toUpperCase();
      if (upper == 'ASSUME' || upper == 'FAIR') return false;
      return mode?.toLowerCase() == 'cover'
          ? upper == 'COVER'
          : upper != 'COVER';
    }

    final dbFolds = SbyStatusReader(task: live.task);
    (database?.records ?? const <SbyStatusRecord>[]).forEach(dbFolds.add);

    final order = <String>[];
    final names = <String, String>{};
    final tasks = <String, String>{};
    final kinds = <String, String>{};
    final locations = <String, String>{};
    void note(String key, String task, String kind, String loc, String name) {
      if (!checked(kind)) return;
      if (!names.containsKey(key)) {
        order.add(key);
        tasks[key] = task;
        kinds[key] = kind;
        locations[key] = loc;
        names[key] = name;
      } else if (names[key]!.isEmpty && name.isNotEmpty) {
        names[key] = name;
      }
    }

    for (final fold in live.properties) {
      note(
        '${fold.task}\u0000${fold.kind}\u0000${fold.location}',
        fold.task,
        fold.kind,
        fold.location,
        fold.name,
      );
    }
    for (final declared
        in database?.properties ?? const <SbyDeclaredProperty>[]) {
      if (live.task != null && declared.task != live.task) continue;
      note(
        declared.key,
        declared.task,
        declared.kind,
        declared.location,
        declared.name,
      );
    }
    for (final fold in dbFolds.properties) {
      note(
        '${fold.task}\u0000${fold.kind}\u0000${fold.location}',
        fold.task,
        fold.kind,
        fold.location,
        fold.name,
      );
    }

    var disagreement = false;
    final results = <FormalPropertyResult>[];
    for (final key in order) {
      final fromLive = live[key];
      final fromDb = dbFolds[key];
      FormalPropertyStatus status;
      SbyPropertyFold? source;
      if (fromLive != null && fromDb != null) {
        final a = fromLive.status;
        final b = fromDb.status;
        if (a != b) disagreement = true;
        if (b.conservativeRank > a.conservativeRank) {
          status = b;
          source = fromDb;
        } else {
          status = a;
          source = fromLive;
        }
      } else if (fromLive != null || fromDb != null) {
        source = fromLive ?? fromDb;
        status = source!.status;
      } else {
        status = taskVerdict == FormalVerdict.pass
            ? FormalPropertyStatus.didNotRun
            : FormalPropertyStatus.inconclusive;
      }
      final raw = locations[key]!;
      final where = normaliseLocation(
        raw,
        files: files,
        sbyDirectory: sbyDirectory,
        projectRoot: projectRoot,
      );
      results.add(
        FormalPropertyResult(
          task: tasks[key]!,
          kind: kinds[key]!,
          location: where.location,
          rawLocation: raw,
          name: names[key]!,
          status: status,
          label: labelOf(names[key]!),
          file: where.file,
          line: where.line,
          step: source?.step,
          trace: source?.trace,
        ),
      );
    }

    if (results.isEmpty) {
      return FormalReconciliation(
        properties: const <FormalPropertyResult>[],
        verdict: taskVerdict,
        taskVerdict: taskVerdict,
        disagreement: null,
        truncated: live.truncated || (database?.truncated ?? false),
      );
    }
    final derived = verdictFromProperties(results.map((r) => r.status));
    if (FormalBucket.of(derived) != FormalBucket.of(taskVerdict)) {
      disagreement = true;
    }
    final verdict = taskVerdict == FormalVerdict.pass ? derived : taskVerdict;
    return FormalReconciliation(
      properties: List<FormalPropertyResult>.unmodifiable(results),
      verdict: verdict,
      taskVerdict: taskVerdict,
      disagreement: disagreement,
      truncated: live.truncated || (database?.truncated ?? false),
    );
  }

  /// Every checked property, in first-seen order.
  final List<FormalPropertyResult> properties;

  /// The verdict to show and record: [taskVerdict], unless the task said
  /// `PASS` and a property says otherwise, in which case the property's
  /// (more conservative) fact. Never moved toward `PASS`.
  final FormalVerdict verdict;

  /// What the log's `DONE (…)` line said.
  final FormalVerdict taskVerdict;

  /// True when the sources disagreed (the task verdict against the
  /// properties, or the status stream against `status.sqlite`); false when
  /// they were compared and agreed; null when there was no per-property
  /// data to compare.
  final bool? disagreement;

  /// True when a bound cut the per-property data short.
  final bool truncated;

  /// Properties that ended as a counterexample or an unreached cover.
  int get failedCount => properties
      .where((r) => r.status.bucket == FormalBucket.counterexample)
      .length;

  /// Properties that ended undecided or did not run.
  int get undecidedCount => properties
      .where(
        (r) =>
            r.status == FormalPropertyStatus.inconclusive ||
            r.status == FormalPropertyStatus.didNotRun,
      )
      .length;

  static String? _modeOf(SbyStatusSnapshot? database) {
    for (final record in database?.records ?? const <SbyStatusRecord>[]) {
      if (record.mode != null) return record.mode;
    }
    return null;
  }

  static final RegExp _location = RegExp(r'^(.*?):(\d+)((?:[.:-].*)?)$');

  /// Maps `sby`'s spelling of a location (the copy in the task's `src/`)
  /// back to the user's file, relative to [projectRoot].
  ///
  /// [files] is the `.sby` file's `[files]` map (copy name to source path,
  /// relative to [sbyDirectory]). The result is project-root-relative only
  /// when the source lies inside [projectRoot] (`crux_io` path identity);
  /// otherwise the location is kept as `sby` spelled it.
  static ({String location, String? file, int? line}) normaliseLocation(
    String raw, {
    Map<String, String> files = const <String, String>{},
    String? sbyDirectory,
    String? projectRoot,
  }) {
    final match = _location.firstMatch(raw);
    if (match == null) return (location: raw, file: null, line: null);
    final copy = match.group(1)!;
    final line = int.tryParse(match.group(2)!);
    final rest = match.group(3) ?? '';
    final source = files[copy] ?? copy;
    if (sbyDirectory == null || projectRoot == null) {
      return (location: raw, file: copy, line: line);
    }
    final absolute = p.isAbsolute(source)
        ? source
        : p.join(sbyDirectory, source);
    final contained = FormalContainment.containedPath(projectRoot, absolute);
    if (contained == null) return (location: raw, file: copy, line: line);
    final relative = p
        .relative(contained, from: p.normalize(p.absolute(projectRoot)))
        .replaceAll(r'\', '/');
    return (
      location: '$relative:${match.group(2)}$rest',
      file: relative,
      line: line,
    );
  }

  /// The user's label from a hierarchical property name, or null when the
  /// frontend mangled it.
  static String? labelOf(String name) {
    if (name.isEmpty) return null;
    final segments = name.split('.');
    if (segments.length < 2) return null;
    for (final segment in segments) {
      if (segment.startsWith('_witness_') ||
          segment.startsWith(r'$') ||
          segment.startsWith(r'\')) {
        return null;
      }
    }
    final last = segments.last;
    return last.isEmpty ? null : last;
  }
}
