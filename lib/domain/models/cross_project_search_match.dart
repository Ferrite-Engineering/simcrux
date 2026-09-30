// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/cross_project_search_target.dart';

/// Discriminates what surface inside a project produced the match.
enum CrossProjectSearchMatchKind {
  /// Match was found inside a `TestSpec.id` or `TestResult.testId`.
  testName,

  /// Match was found inside a `TestResult.failureMessage`.
  failureMessage,

  /// Match was found inside a source file path under the project tree.
  filePath,
}

/// Inclusive-start / exclusive-end range over the [matchedText]
/// string. Used by the dialog UI to draw inline highlights on the
/// matched substring while keeping the surrounding context legible.
///
/// Distinct from Flutter's `TextRange` so the model stays in the
/// domain layer (no Flutter import).
@immutable
class CrossProjectSearchHighlight {
  /// Creates a [CrossProjectSearchHighlight].
  const CrossProjectSearchHighlight({
    required this.start,
    required this.end,
  }) : assert(start >= 0, 'start must be >= 0'),
       assert(end >= start, 'end must be >= start');

  /// Inclusive start index into [CrossProjectSearchMatch.contextSnippet].
  final int start;

  /// Exclusive end index into [CrossProjectSearchMatch.contextSnippet].
  final int end;

  /// JSON serialization for isolate boundary marshalling.
  Map<String, Object?> toJson() => <String, Object?>{
    'start': start,
    'end': end,
  };

  /// Tolerant JSON parser. Out-of-order / negative bounds return
  /// `null` so an isolate corrupt payload never blows up the host.
  static CrossProjectSearchHighlight? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['start'];
    final end = raw['end'];
    if (start is! int || end is! int) return null;
    if (start < 0 || end < start) return null;
    return CrossProjectSearchHighlight(start: start, end: end);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CrossProjectSearchHighlight &&
        other.start == start &&
        other.end == end;
  }

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'CrossProjectSearchHighlight($start..$end)';
}

/// A single hit produced by [CrossProjectSearchService.search].
///
/// Stream-friendly: matches arrive as workers find them, one per
/// emission. The dialog UI groups by [projectId] at the presentation
/// layer; the service itself never batches.
@immutable
class CrossProjectSearchMatch {
  /// Creates a [CrossProjectSearchMatch].
  CrossProjectSearchMatch({
    required this.projectId,
    required this.projectName,
    required this.matchKind,
    required this.matchedText,
    required this.contextSnippet,
    required this.target,
    List<CrossProjectSearchHighlight>? highlights,
  }) : highlights = List<CrossProjectSearchHighlight>.unmodifiable(
         highlights ?? const <CrossProjectSearchHighlight>[],
       );

  /// Stable id of the project that produced the match. Matches
  /// `ProjectDescriptor.id`; used for grouping in the dialog UI and
  /// for routing the click-to-jump activation.
  final String projectId;

  /// Display name of the project at the moment the match was
  /// produced. Captured eagerly so the UI does not have to re-resolve
  /// it from the registry when rendering each row.
  final String projectName;

  /// What surface inside the project produced the match.
  final CrossProjectSearchMatchKind matchKind;

  /// The text that actually matched the pattern (test id, failure
  /// excerpt, file path). May overlap with [contextSnippet] entirely
  /// for short identifiers.
  final String matchedText;

  /// ~80 character context snippet surrounding [matchedText]. For
  /// short matches this is just [matchedText]; for longer texts
  /// (failure messages) it's a centered window with leading /
  /// trailing ellipsis markers added by the worker.
  final String contextSnippet;

  /// Inclusive-start / exclusive-end ranges into [contextSnippet]
  /// for each pattern occurrence the worker found. Empty when the
  /// match is whole-string (no highlight needed).
  final List<CrossProjectSearchHighlight> highlights;

  /// Opaque pointer to the underlying object so click-to-jump can
  /// navigate without re-querying.
  final CrossProjectSearchTarget target;

  /// JSON serialization for crossing the isolate boundary.
  Map<String, Object?> toJson() => <String, Object?>{
    'project_id': projectId,
    'project_name': projectName,
    'match_kind': matchKind.name,
    'matched_text': matchedText,
    'context_snippet': contextSnippet,
    'highlights': highlights.map((h) => h.toJson()).toList(),
    'target': target.toJson(),
  };

  /// Tolerant JSON parser. Returns `null` on any structural failure
  /// (missing required field, unknown matchKind, unknown target kind).
  static CrossProjectSearchMatch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final projectId = raw['project_id'];
    final projectName = raw['project_name'];
    final matchKindRaw = raw['match_kind'];
    final matchedText = raw['matched_text'];
    final contextSnippet = raw['context_snippet'];
    final highlightsRaw = raw['highlights'];
    if (projectId is! String || projectId.isEmpty) return null;
    if (projectName is! String || projectName.isEmpty) return null;
    if (matchedText is! String) return null;
    if (contextSnippet is! String) return null;
    final matchKind = CrossProjectSearchMatchKind.values.firstWhere(
      (k) => k.name == matchKindRaw,
      orElse: () => CrossProjectSearchMatchKind.testName,
    );
    final highlights = <CrossProjectSearchHighlight>[];
    if (highlightsRaw is List) {
      for (final entry in highlightsRaw) {
        final h = CrossProjectSearchHighlight.fromJson(entry);
        if (h != null) highlights.add(h);
      }
    }
    final target = CrossProjectSearchTarget.fromJson(raw['target']);
    if (target == null) return null;
    return CrossProjectSearchMatch(
      projectId: projectId,
      projectName: projectName,
      matchKind: matchKind,
      matchedText: matchedText,
      contextSnippet: contextSnippet,
      highlights: highlights,
      target: target,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CrossProjectSearchMatch) return false;
    if (other.projectId != projectId) return false;
    if (other.projectName != projectName) return false;
    if (other.matchKind != matchKind) return false;
    if (other.matchedText != matchedText) return false;
    if (other.contextSnippet != contextSnippet) return false;
    if (other.target != target) return false;
    if (other.highlights.length != highlights.length) return false;
    for (var i = 0; i < highlights.length; i++) {
      if (other.highlights[i] != highlights[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    projectId,
    projectName,
    matchKind,
    matchedText,
    contextSnippet,
    Object.hashAll(highlights),
    target,
  );

  @override
  String toString() =>
      'CrossProjectSearchMatch(project: $projectName ($projectId), '
      'kind: ${matchKind.name}, matched: "$matchedText")';
}

/// Computes the highlight ranges produced by matching [pattern]
/// against [haystack] under the (case-sensitive | case-insensitive)
/// rule the [CrossProjectSearchQuery] selected.
///
/// The pattern uses a tiny grammar: `*` is a wildcard, everything
/// else is matched literally. Multiple `*` segments work
/// (`foo*bar*baz`).
///
/// Returns the list of ranges where the pattern matched; an empty
/// list means no match. Worker code calls this once per candidate
/// string to populate [CrossProjectSearchMatch.highlights].
List<CrossProjectSearchHighlight> computeHighlights({
  required String pattern,
  required String haystack,
  required bool caseSensitive,
}) {
  if (pattern.isEmpty) return const <CrossProjectSearchHighlight>[];
  final segments = pattern
      .split('*')
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) return const <CrossProjectSearchHighlight>[];
  final searchHaystack = caseSensitive ? haystack : haystack.toLowerCase();
  final results = <CrossProjectSearchHighlight>[];
  var cursor = 0;
  for (final seg in segments) {
    final needle = caseSensitive ? seg : seg.toLowerCase();
    final idx = searchHaystack.indexOf(needle, cursor);
    if (idx < 0) return const <CrossProjectSearchHighlight>[];
    results.add(
      CrossProjectSearchHighlight(start: idx, end: idx + needle.length),
    );
    cursor = idx + needle.length;
  }
  return results;
}
