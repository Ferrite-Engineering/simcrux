// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/cross_project_search_scope.dart';

/// User input for a single cross-project search. Immutable so the
/// Pro service can ship the same value across an isolate boundary
/// without copying the field by field.
///
/// The query is intentionally simple in v1 — substring with optional
/// `*` glob wildcard. Anchored regex was considered and dropped:
/// engineers searching across N projects benefit more from low-cost
/// matching than from regex flexibility, and the live-search UX
/// re-fires on every keystroke (so even the cheap substring path is
/// hot).
@immutable
class CrossProjectSearchQuery {
  /// Creates a [CrossProjectSearchQuery].
  const CrossProjectSearchQuery({
    required this.pattern,
    this.scope = CrossProjectSearchScope.all,
    this.caseSensitive = false,
    this.limit = defaultPerProjectLimit,
  });

  /// Per-project hit ceiling. Each project's worker stops emitting
  /// matches after this many hits and signals the truncation via
  /// `CrossProjectSearchProgress.truncated`.
  ///
  /// Tuned for the live-search UX: 200 matches per project across 10
  /// open projects yields 2000 rows on screen, which renders in a
  /// virtualized list comfortably and is far more than a user
  /// realistically scans before refining the pattern.
  static const int defaultPerProjectLimit = 200;

  /// The pattern to match. Treated as a literal substring with one
  /// transformation: `*` characters mean "match any characters
  /// (including nothing)". Regex metacharacters are NOT honored —
  /// `.()[]?+^$\` are matched literally.
  ///
  /// Empty patterns are valid and instruct the service to emit zero
  /// matches without scheduling any workers; the UI uses that path
  /// to render the "Type to search" empty state.
  final String pattern;

  /// Which surfaces inside each project the worker traverses.
  final CrossProjectSearchScope scope;

  /// When false (default) the pattern is matched ASCII-case-
  /// insensitively; both pattern and candidate text are lowered
  /// before comparison. When true the case is preserved on both
  /// sides.
  final bool caseSensitive;

  /// Maximum matches emitted per project before the worker stops.
  /// `null` disables the limit (every match streams to the host).
  /// Defaults to [defaultPerProjectLimit].
  final int? limit;

  /// Convenience: is the pattern empty (no work to schedule)?
  bool get isEmpty => pattern.isEmpty;

  /// JSON serialization for crossing the isolate boundary. The
  /// Pro service marshals the query into a worker via `Isolate.spawn`
  /// and reconstructs it on the other side; the JSON form survives
  /// SendPort transport without any custom registration.
  Map<String, Object?> toJson() => <String, Object?>{
    'pattern': pattern,
    'scope': scope.name,
    'case_sensitive': caseSensitive,
    'limit': limit,
  };

  /// Tolerant JSON parser. Unknown scope names fall back to
  /// [CrossProjectSearchScope.all] so a forward-compatible serialized
  /// query never throws on the worker side.
  static CrossProjectSearchQuery? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pattern = raw['pattern'];
    if (pattern is! String) return null;
    final scopeRaw = raw['scope'];
    final scope = CrossProjectSearchScope.values.firstWhere(
      (s) => s.name == scopeRaw,
      orElse: () => CrossProjectSearchScope.all,
    );
    final caseSensitiveRaw = raw['case_sensitive'];
    final caseSensitive = caseSensitiveRaw is bool && caseSensitiveRaw;
    final limitRaw = raw['limit'];
    final int? limit;
    if (limitRaw is int) {
      limit = limitRaw;
    } else if (raw.containsKey('limit')) {
      limit = null;
    } else {
      limit = defaultPerProjectLimit;
    }
    return CrossProjectSearchQuery(
      pattern: pattern,
      scope: scope,
      caseSensitive: caseSensitive,
      limit: limit,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CrossProjectSearchQuery) return false;
    return other.pattern == pattern &&
        other.scope == scope &&
        other.caseSensitive == caseSensitive &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(pattern, scope, caseSensitive, limit);

  @override
  String toString() =>
      'CrossProjectSearchQuery(pattern: "$pattern", scope: ${scope.name}, '
      'caseSensitive: $caseSensitive, limit: $limit)';
}
