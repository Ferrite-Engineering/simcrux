// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/formal_diagnostic.dart';

/// Reads the source text of the statement at `file:line` (the line and its
/// continuation up to the first `;`), or null when it cannot be read.
typedef SvaSourceReader = String? Function(String file, int line);

/// Turns a frontend's refusal of an SVA construct into a closed
/// [SvaConstructClass], so a row that did not run can say **what** was
/// refused and **where** before it says why.
///
/// Pure: the driver feeds it the task's log lines (the `sby` log and the
/// task's `model/design.log`, which is the only place older `sby` builds
/// keep the frontend's error) and a reader for the source copy
/// the frontend read.
///
/// ## What a refusal looks like (measured on three OSS CAD Suite builds)
///
/// | Build | Frontend | Line |
/// |---|---|---|
/// | 20261021 | both | `handshake.sv:42: ERROR: syntax error, unexpected '@'` |
/// | 20261021 | slang | `x.sv:2: ERROR: encountered unsupported SVA feature` |
/// | 20260921, 20260821 | slang | `x.sv:2:34: error: unsupported system task '$rose'` |
/// | all | slang | `Source line x.sv:2:11: …` then `ERROR: Feature unimplemented …` |
///
/// The frontends name a line, never a construct: the built-in parser stops
/// at the first token it cannot read (`unexpected '@'`), and yosys-slang
/// says only "unsupported SVA feature". So the class comes from the
/// statement at that line, in a fixed priority (the most specific
/// construct first): a `default clocking` block, a named `sequence` or
/// `property`, a liveness operator, a sequence operator, a repetition, a
/// delay, an implication. A message that names the construct itself
/// (`unknown system name '$initstate'`) wins over the statement.
///
/// ## What it never does
///
/// It never classifies a Verific run (the diagnostic is for the open
/// frontends), never claims a refusal it cannot place in an assertion
/// (a plain syntax error in RTL stays an ordinary error), and never
/// changes a verdict: the row is already Did not run because the engine
/// said `ERROR`.
class SvaRefusalClassifier {
  /// Creates a classifier.
  const SvaRefusalClassifier();

  /// `SBY 12:34:56 [task] ` and the `base: ` step prefix.
  static final RegExp _sbyPrefix = RegExp(
    r'^(?:SBY\s+(?:\S+\s+)?\[[^\]]*\]\s*)?(?:[a-z_0-9]+:\s+)?',
  );

  /// `file:line: ERROR: msg` (20261021) and `file:line:col: error: msg`
  /// (older yosys-slang, which prints slang's own diagnostics).
  static final RegExp _located = RegExp(
    r'^(.+?):(\d+)(?::(\d+))?:\s+(?:ERROR|error):\s+(.*)$',
  );

  /// yosys-slang's AST dump before `Feature unimplemented`.
  static final RegExp _sourceLine = RegExp(r'^Source line\s+(.+?):(\d+):\d+:');

  /// A message that names the refused construct itself.
  static final RegExp _namedSystemTask = RegExp(
    r"(?:unknown system name|unsupported system task)\s+'(\$\w+)'",
  );

  /// The yosys-slang messages that are about assertions whatever the
  /// statement looks like.
  static const List<String> _slangSvaMessages = <String>[
    'unsupported SVA feature',
    'SVA unsupported',
    'Feature unimplemented',
    'reading net state during design initialization unsupported',
  ];

  /// The frontend a run used, from its Yosys log ([designLog]) first and
  /// its `[script]` lines ([script]) second.
  static FormalFrontend detectFrontend({
    Iterable<String> designLog = const <String>[],
    Iterable<String> script = const <String>[],
  }) {
    var slang = false;
    var builtin = false;
    for (final line in designLog) {
      if (line.contains('Executing VERIFIC') ||
          line.contains('built without Verific support')) {
        return FormalFrontend.verific;
      }
      if (line.contains('Executing SLANG frontend')) slang = true;
      if (line.contains('Executing Verilog-2005 frontend')) builtin = true;
    }
    if (slang) return FormalFrontend.slang;
    if (builtin) return FormalFrontend.builtin;
    for (final raw in script) {
      final words = raw.trim().split(RegExp(r'\s+'));
      if (words.isEmpty) continue;
      switch (words.first) {
        case 'verific':
          return FormalFrontend.verific;
        case 'read_slang':
          slang = true;
        case 'read_verilog' || 'read':
          builtin = true;
      }
    }
    if (slang) return FormalFrontend.slang;
    if (builtin) return FormalFrontend.builtin;
    return FormalFrontend.unknown;
  }

  /// The first refusal in [lines] that is about an assertion, classified,
  /// or null when there is none (or [frontend] is Verific).
  SvaRefusal? classify({
    required Iterable<String> lines,
    required FormalFrontend frontend,
    SvaSourceReader? readSource,
  }) {
    if (frontend == FormalFrontend.verific) return null;
    ({String file, int line})? unimplementedAt;
    var unimplemented = false;
    for (final raw in lines) {
      final line = raw.trimRight().replaceFirst(_sbyPrefix, '');
      final source = _sourceLine.firstMatch(line);
      if (source != null) {
        unimplementedAt ??= (
          file: source.group(1)!,
          line: int.parse(source.group(2)!),
        );
        continue;
      }
      if (line.contains('Feature unimplemented')) unimplemented = true;
      final match = _located.firstMatch(line);
      if (match == null) continue;
      final refusal = _classifyAt(
        file: match.group(1)!.trim(),
        line: int.parse(match.group(2)!),
        message: match.group(4)!,
        frontend: frontend,
        readSource: readSource,
      );
      if (refusal != null) return refusal;
    }
    final at = unimplementedAt;
    if (unimplemented && at != null) {
      return _classifyAt(
        file: at.file,
        line: at.line,
        message: 'Feature unimplemented',
        frontend: frontend,
        readSource: readSource,
      );
    }
    return null;
  }

  SvaRefusal? _classifyAt({
    required String file,
    required int line,
    required String message,
    required FormalFrontend frontend,
    SvaSourceReader? readSource,
  }) {
    final named = _namedSystemTask.firstMatch(message);
    if (named != null) {
      return SvaRefusal(
        constructClass: SvaConstructClass.other,
        frontend: frontend,
        construct: named.group(1),
        file: file,
        line: line,
      );
    }
    final statement = readSource?.call(file, line);
    final classified = statement == null ? null : classifyStatement(statement);
    if (classified != null) {
      return SvaRefusal(
        constructClass: classified.constructClass,
        frontend: frontend,
        construct: classified.construct,
        file: file,
        line: line,
      );
    }
    if (_slangSvaMessages.any(message.contains)) {
      return SvaRefusal(
        constructClass: SvaConstructClass.other,
        frontend: frontend,
        file: file,
        line: line,
      );
    }
    return null;
  }

  static final RegExp _blockComment = RegExp(r'/\*.*?\*/', dotAll: true);
  static final RegExp _lineComment = RegExp(r'//[^\n]*');

  static final RegExp _defaultClocking = RegExp(
    r'\bdefault\s+(clocking|disable\s+iff)\b',
  );
  static final RegExp _namedDeclaration = RegExp(
    r'(?:^|[;:])\s*(sequence|property)\s+[A-Za-z_]\w*\s*[;(]',
    multiLine: true,
  );
  static final RegExp _liveness = RegExp(
    r'\b(s_eventually|eventually|s_always|s_until_with|s_until|s_nexttime|strong)\b',
  );
  static final RegExp _sequenceOp = RegExp(
    r'\b(throughout|within|intersect|until_with|until|first_match)\b',
  );
  static final RegExp _sequenceAndOr = RegExp(r'\)\s*\b(and|or)\b\s*\(');
  static final RegExp _repetition = RegExp(r'\[\s*(?:\*|->|=)[^\]]*\]');
  static final RegExp _delay = RegExp(r'##\s*(?:\[[^\]]*\]|\w+)');
  static final RegExp _nexttime = RegExp(r'\bnexttime\b');
  static final RegExp _implication = RegExp(r'\|->|\|=>|#-#|#=#');
  static final RegExp _concurrent = RegExp(
    r'\b(assert|assume|cover|restrict)\s+property\b',
  );
  static final RegExp _initialAssertion = RegExp(
    r'\binitial\s+(assert|assume|cover)\b',
  );
  static final RegExp _assertion = RegExp(
    r'\b(assert|assume|cover|restrict|property|sequence)\b|\$initstate',
  );

  /// The class and the construct as written for one statement's text, or
  /// null when it holds no assertion at all.
  static ({SvaConstructClass constructClass, String construct})?
  classifyStatement(String text) {
    final code = text
        .replaceAll(_blockComment, ' ')
        .replaceAll(_lineComment, ' ');
    ({SvaConstructClass constructClass, String construct}) hit(
      SvaConstructClass c,
      String construct,
    ) => (constructClass: c, construct: construct.trim());

    final clocking = _defaultClocking.firstMatch(code);
    if (clocking != null) {
      return hit(
        SvaConstructClass.defaultClocking,
        'default ${clocking.group(1)!.replaceAll(RegExp(r'\s+'), ' ')}',
      );
    }
    final declaration = _namedDeclaration.firstMatch(code);
    if (declaration != null) {
      return hit(SvaConstructClass.namedSequence, declaration.group(1)!);
    }
    final liveness = _liveness.firstMatch(code);
    if (liveness != null) {
      return hit(SvaConstructClass.livenessOp, liveness.group(1)!);
    }
    final sequenceOp = _sequenceOp.firstMatch(code);
    if (sequenceOp != null) {
      return hit(SvaConstructClass.sequenceOp, sequenceOp.group(1)!);
    }
    final andOr = _sequenceAndOr.firstMatch(code);
    if (andOr != null && _delay.hasMatch(code)) {
      return hit(SvaConstructClass.sequenceOp, andOr.group(1)!);
    }
    final repetition = _repetition.firstMatch(code);
    if (repetition != null) {
      return hit(
        SvaConstructClass.repetition,
        repetition.group(0)!.replaceAll(RegExp(r'\s+'), ''),
      );
    }
    final delay = _delay.firstMatch(code);
    if (delay != null) {
      return hit(
        SvaConstructClass.delay,
        delay.group(0)!.replaceAll(RegExp(r'\s+'), ''),
      );
    }
    final nexttime = _nexttime.firstMatch(code);
    if (nexttime != null) return hit(SvaConstructClass.delay, 'nexttime');
    final implication = _implication.firstMatch(code);
    if (implication != null) {
      return hit(SvaConstructClass.implication, implication.group(0)!);
    }
    final concurrent = _concurrent.firstMatch(code);
    if (concurrent != null) {
      return hit(SvaConstructClass.other, '${concurrent.group(1)} property');
    }
    final initial = _initialAssertion.firstMatch(code);
    if (initial != null) {
      return hit(SvaConstructClass.other, 'initial ${initial.group(1)}');
    }
    final assertion = _assertion.firstMatch(code);
    if (assertion != null) {
      return hit(SvaConstructClass.other, assertion.group(0)!);
    }
    return null;
  }

  /// The statement starting at 1-based [line] of [text]: that line and the
  /// lines after it up to the first `;`, at most [maxLines].
  static String? statementAt(String text, int line, {int maxLines = 8}) {
    final lines = text.split('\n');
    if (line < 1 || line > lines.length) return null;
    final buffer = StringBuffer();
    for (var i = line - 1; i < lines.length && i < line - 1 + maxLines; i++) {
      buffer.writeln(lines[i]);
      if (lines[i].contains(';')) break;
    }
    return buffer.toString();
  }
}
