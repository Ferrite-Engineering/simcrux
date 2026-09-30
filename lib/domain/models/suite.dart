// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/test_spec.dart';

/// A named group of tests sharing a simulator, sources, defines,
/// pass/fail strategy, etc.
///
/// `Suite` is a post-loader, flattened view: the inheritance from
/// project-level `defaults:` and the suite's own configuration has
/// already been applied to each `TestSpec`. The suite name is
/// retained for filtering and grouping in the dashboard.
@immutable
class Suite {
  /// Creates a [Suite].
  Suite({
    required this.name,
    required List<TestSpec> tests,
    this.description,
  }) : tests = List<TestSpec>.unmodifiable(tests);

  /// Suite name as declared in `simcrux.yaml` (e.g. `cpu_unit`).
  final String name;

  /// Human-readable description, surfaced in the dashboard sidebar.
  final String? description;

  /// Tests that belong to this suite, in declaration order.
  final List<TestSpec> tests;

  /// Returns a copy with the given fields replaced.
  Suite copyWith({
    String? name,
    String? description,
    List<TestSpec>? tests,
  }) {
    return Suite(
      name: name ?? this.name,
      description: description ?? this.description,
      tests: tests ?? this.tests,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Suite) return false;
    if (other.name != name) return false;
    if (other.description != description) return false;
    if (other.tests.length != tests.length) return false;
    for (var i = 0; i < tests.length; i++) {
      if (other.tests[i] != tests[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(name, description, Object.hashAll(tests));
}
