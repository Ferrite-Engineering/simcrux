// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:collection';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';

/// One per-property status record, from `sby --live jsonl` or from a
/// `task_property_status` row of `status.sqlite`. The two sources carry the
/// same facts (VERIFICATION_GUIDE.md §26.4), so both become this.
@immutable
class SbyStatusRecord {
  /// Creates a record.
  const SbyStatusRecord({
    required this.task,
    required this.kind,
    required this.location,
    required this.name,
    required this.status,
    this.mode,
    this.engine,
    this.depth,
    this.trace,
    this.induction = false,
  });

  /// The `[tasks]` name (`task_name`), empty for a file with no tasks.
  final String task;

  /// `ASSERT`, `COVER`, or another kind a newer `sby` reports.
  final String kind;

  /// `<file>:<line>.<col>-<line>.<col>`, as `sby` spells it.
  final String location;

  /// The hierarchical property name (`<module>.<label>` under yosys-slang,
  /// mangled under the built-in frontend).
  final String name;

  /// `PASS`, `FAIL` or `UNKNOWN`, verbatim.
  final String status;

  /// The proof mode (`prove`, `bmc`, `cover`, `live`), when known.
  final String? mode;

  /// `engine_N` or `task_status`.
  final String? engine;

  /// The step the record is about, when `sby` has one.
  final int? depth;

  /// The trace the record names, verbatim (it may be the `.yw` witness).
  final String? trace;

  /// True when the record comes from the induction step: its trace is not a
  /// trace of the design and it is never a counterexample.
  final bool induction;

  /// The identity of the property within a run: task, kind and location.
  String get key => '$task\u0000$kind\u0000$location';

  /// Parses one `--live jsonl` object, or null when it is not a property
  /// record this reader understands.
  static SbyStatusRecord? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    // A job file with no `[tasks]` section: sby leaves `task_name` out of
    // the record altogether (measured on build 20261021).
    final task = decoded.containsKey('task_name') ? decoded['task_name'] : '';
    final kind = decoded['kind'];
    final location = decoded['location'];
    final status = decoded['status'];
    if (task is! String ||
        kind is! String ||
        location is! String ||
        status is! String) {
      return null;
    }
    final name = decoded['name'];
    final mode = decoded['mode'];
    final engine = decoded['engine'];
    final depth = decoded['depth'];
    final trace = decoded['trace'];
    final traceText = trace is String && trace.isNotEmpty ? trace : null;
    return SbyStatusRecord(
      task: task,
      kind: kind,
      location: location,
      name: name is String ? name : '',
      status: status,
      mode: mode is String ? mode : null,
      engine: engine is String ? engine : null,
      depth: depth is int ? depth : null,
      trace: traceText,
      induction: traceText != null && isInductionTrace(traceText),
    );
  }

  /// Whether [trace] names an induction-step file (`trace_induct.vcd`,
  /// `trace_induct.yw`, …).
  static bool isInductionTrace(String trace) {
    final slash = trace.replaceAll(r'\', '/').lastIndexOf('/');
    final base = slash < 0 ? trace : trace.substring(slash + 1);
    return base.startsWith('trace_induct');
  }
}

/// Everything the records said about one property, folded.
class SbyPropertyFold {
  /// Starts a fold from its first record.
  SbyPropertyFold(SbyStatusRecord first)
    : task = first.task,
      kind = first.kind,
      location = first.location,
      name = first.name;

  /// The `[tasks]` name.
  final String task;

  /// The property kind.
  final String kind;

  /// The location as `sby` spells it.
  final String location;

  /// The hierarchical name.
  String name;

  bool _pass = false;
  bool _baseFail = false;
  bool _inductionFail = false;
  int? _passStep;
  int? _failStep;
  String? _passTrace;
  String? _failTrace;
  String? _unrecognisedStatus;

  /// Folds one more record in.
  void add(SbyStatusRecord record) {
    if (name.isEmpty && record.name.isNotEmpty) name = record.name;
    switch (record.status.toUpperCase()) {
      case 'PASS':
        _pass = true;
        _passStep ??= record.depth;
        _passTrace = _preferVcd(_passTrace, record.trace);
      case 'FAIL':
        if (record.induction) {
          _inductionFail = true;
        } else {
          _baseFail = true;
          _failStep ??= record.depth;
          _failTrace = _preferVcd(_failTrace, record.trace);
        }
      case 'UNKNOWN':
        break;
      default:
        // A status token a newer `sby` invented. Kept, and read as
        // undecided: it is never a proof.
        _unrecognisedStatus ??= record.status;
    }
  }

  static String? _preferVcd(String? current, String? next) {
    if (next == null) return current;
    if (current == null) return next;
    if (current.toLowerCase().endsWith('.vcd')) return current;
    return next;
  }

  /// Whether this is a cover statement.
  bool get isCover => kind.toUpperCase() == 'COVER';

  /// The status these records support on their own.
  ///
  /// A base-case FAIL wins over a PASS (the more conservative fact). An
  /// induction FAIL alone is undecided, never a counterexample.
  FormalPropertyStatus get status {
    if (_baseFail) {
      return isCover
          ? FormalPropertyStatus.notReached
          : FormalPropertyStatus.counterexample;
    }
    if (_pass && _unrecognisedStatus == null) {
      return isCover
          ? FormalPropertyStatus.reached
          : FormalPropertyStatus.proved;
    }
    return FormalPropertyStatus.inconclusive;
  }

  /// The step of the counterexample or the cover witness, when known.
  int? get step => _baseFail ? _failStep : (isCover ? _passStep : null);

  /// The trace of the counterexample or the cover witness, verbatim.
  String? get trace => _baseFail ? _failTrace : (isCover ? _passTrace : null);

  /// True when an induction step failed for this property.
  bool get inductionFailed => _inductionFail;
}

/// Incremental reader for `sby --live jsonl`, fed the run log line by line.
///
/// `sby` prints each status change as `SBY <time> [<job>] jsonl: {…}`. Lines
/// that are not status records pass through untouched, so the same `onLine`
/// hook feeds this reader and the log reader. Bounded: a line longer than
/// [kMaxLineLength] is not decoded, and at most [kMaxProperties] distinct
/// properties are tracked.
class SbyStatusReader {
  /// Creates a reader. With [task], records of other tasks are ignored (a
  /// log captured from a multi-task invocation interleaves them).
  SbyStatusReader({this.task});

  /// Only records of this task are folded, when set.
  final String? task;

  /// The longest line decoded as JSON.
  static const int kMaxLineLength = 64 * 1024;

  /// The most distinct properties tracked.
  static const int kMaxProperties = 20000;

  static final RegExp _prefix = RegExp(r'^SBY\s+(?:\S+\s+)?\[[^\]]*\]\s*');
  static const String _marker = 'jsonl:';

  final LinkedHashMap<String, SbyPropertyFold> _folds =
      LinkedHashMap<String, SbyPropertyFold>();
  int _records = 0;
  int _malformed = 0;
  bool _truncated = false;
  String? _mode;

  /// The proof mode the first record named, or null.
  String? get mode => _mode;

  /// Feeds one log line.
  void addLine(String raw) {
    if (raw.length > kMaxLineLength) {
      if (raw.contains(_marker)) _malformed++;
      return;
    }
    final line = raw.replaceFirst(_prefix, '').trimLeft();
    if (!line.startsWith(_marker)) return;
    final body = line.substring(_marker.length).trim();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      _malformed++;
      return;
    }
    final record = SbyStatusRecord.fromJson(decoded);
    if (record == null) {
      _malformed++;
      return;
    }
    add(record);
  }

  /// Folds one record (also used for `status.sqlite` rows).
  void add(SbyStatusRecord record) {
    final only = task;
    if (only != null && record.task != only) return;
    _records++;
    _mode ??= record.mode;
    final existing = _folds[record.key];
    if (existing != null) {
      existing.add(record);
      return;
    }
    if (_folds.length >= kMaxProperties) {
      _truncated = true;
      return;
    }
    _folds[record.key] = SbyPropertyFold(record)..add(record);
  }

  /// Property folds in first-seen order.
  List<SbyPropertyFold> get properties =>
      List<SbyPropertyFold>.unmodifiable(_folds.values);

  /// The fold for [key] ([SbyStatusRecord.key]), or null.
  SbyPropertyFold? operator [](String key) => _folds[key];

  /// How many records were folded.
  int get recordCount => _records;

  /// Lines that said `jsonl:` but could not be read as a record.
  int get malformedCount => _malformed;

  /// True when properties beyond [kMaxProperties] were dropped.
  bool get truncated => _truncated;

  /// Convenience for tests and replay: reads a whole captured log.
  static SbyStatusReader parse(String log, {String? task}) {
    final reader = SbyStatusReader(task: task);
    const LineSplitter().convert(log).forEach(reader.addLine);
    return reader;
  }
}

/// The verdict token a set of property statuses supports on its own, for
/// the agreement rule: the most conservative status wins.
FormalVerdict verdictFromProperties(Iterable<FormalPropertyStatus> statuses) {
  var worst = FormalPropertyStatus.proved;
  for (final status in statuses) {
    if (status.conservativeRank > worst.conservativeRank) worst = status;
  }
  return worst.verdict;
}
