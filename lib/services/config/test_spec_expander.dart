// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/test_spec.dart';

/// Pure expansion of a parameterized [TestSpec] template into the
/// concrete, fully-bound [TestSpec]s the scheduler executes.
///
/// Expansion fans out two orthogonal axes:
///
/// 1. **Seed sweep.** When [TestSpec.seeds] is non-null and non-empty,
///    the spec is duplicated once per seed value, with each child
///    receiving that seed in [TestSpec.seed].
/// 2. **Parameter cartesian product.** When [TestSpec.parameterSweeps]
///    is non-null and non-empty, the spec is fanned out across the
///    cartesian product of every sweep axis, with each child receiving
///    one bound value per swept parameter in [TestSpec.parameters].
///
/// **Ordering.** Seeds expand first (outer loop), then parameter axes
/// expand in declaration order (inner loops). The first declared
/// parameter axis advances slowest; the last advances fastest. This
/// order is part of the contract — re-run workflows depend on stable
/// expansion ordering so that "re-run with seed N" picks the same
/// expanded child every time. Tests pin this ordering explicitly.
///
/// **Identity.** Each expanded child carries:
/// - a synthesized [TestSpec.id] of the form
///   `<parentId>+key1=val1+key2=val2[+seed=N]` (parameter keys are
///   sorted alphabetically inside the suffix for stable ids);
/// - the parent's id in [TestSpec.parentSpecId];
/// - `seeds = null` and `parameterSweeps = null` (template axes are
///   consumed by expansion);
/// - the parent's existing bound [TestSpec.parameters] merged with
///   the sweep slice (test-level scalar parameters override sweep
///   values when the same key appears in both — sweep slices win in
///   practice because the parser flattens scalar values into
///   single-element sweeps before reaching this expander).
///
/// **Backward compatibility.** When [TestSpec.seeds] and
/// [TestSpec.parameterSweeps] are both null/empty, expansion is a
/// no-op identity: the function returns `[source]` unchanged. This
/// preserves the open-core "specs that don't parameterize pass
/// through" semantics that all existing tests rely on.
///
/// **Runaway protection.** The expander itself does not cap the
/// expansion size — that's a Pro-overlay decision exposed via
/// `Settings → Test Execution → Parameterization → Max expansion
/// size`. Callers that need a cap consult [expansionSize] first and
/// reject the spec when it exceeds their budget.
class TestSpecExpander {
  /// Const default. The expander is stateless.
  const TestSpecExpander();

  /// Returns the expanded children for [source]. When the spec is not
  /// parameterized (no [TestSpec.seeds], no [TestSpec.parameterSweeps]),
  /// returns `[source]` unchanged.
  ///
  /// See class-level docs for ordering and identity guarantees.
  Iterable<TestSpec> expand(TestSpec source) sync* {
    if (!source.isParameterized) {
      yield source;
      return;
    }
    final seeds = source.seeds ?? const <int?>[null];
    final seedAxis = seeds.isEmpty ? const <int?>[null] : seeds;
    final paramAxes = _orderedParamAxes(source.parameterSweeps);
    for (final seedValue in seedAxis) {
      yield* _expandParamAxes(
        source: source,
        seedValue: seedValue is int ? seedValue : null,
        axes: paramAxes,
        accumulator: <String, String>{},
        axisIndex: 0,
      );
    }
  }

  /// Returns the total number of concrete children expansion would
  /// produce. O(axes) without materializing the children; safe to call
  /// before [expand] to enforce a max-expansion-size guard.
  int expansionSize(TestSpec source) {
    if (!source.isParameterized) return 1;
    final seedFactor = (source.seeds == null || source.seeds!.isEmpty)
        ? 1
        : source.seeds!.length;
    var paramFactor = 1;
    final sweeps = source.parameterSweeps;
    if (sweeps != null) {
      for (final values in sweeps.values) {
        if (values.isEmpty) return 0;
        paramFactor *= values.length;
      }
    }
    return seedFactor * paramFactor;
  }

  // ── internals ───────────────────────────────────────────────────────

  /// Returns the parameter axes in declaration order. Stable order is
  /// part of the expander's public contract.
  List<MapEntry<String, List<String>>> _orderedParamAxes(
    Map<String, List<String>>? sweeps,
  ) {
    if (sweeps == null || sweeps.isEmpty) {
      return const <MapEntry<String, List<String>>>[];
    }
    return sweeps.entries.toList(growable: false);
  }

  Iterable<TestSpec> _expandParamAxes({
    required TestSpec source,
    required int? seedValue,
    required List<MapEntry<String, List<String>>> axes,
    required Map<String, String> accumulator,
    required int axisIndex,
  }) sync* {
    if (axisIndex == axes.length) {
      yield _materialize(source, seedValue, accumulator);
      return;
    }
    final axis = axes[axisIndex];
    for (final value in axis.value) {
      final next = Map<String, String>.of(accumulator);
      next[axis.key] = value;
      yield* _expandParamAxes(
        source: source,
        seedValue: seedValue,
        axes: axes,
        accumulator: next,
        axisIndex: axisIndex + 1,
      );
    }
  }

  /// Materializes one fully-bound child spec from the source template
  /// and the current cursor (seed + parameter slice).
  TestSpec _materialize(
    TestSpec source,
    int? seedValue,
    Map<String, String> sweepSlice,
  ) {
    final mergedParameters = <String, String>{
      ...source.parameters,
      ...sweepSlice,
    };
    final id = _buildExpandedId(
      parentId: source.id,
      seed: seedValue,
      parameters: sweepSlice,
    );
    return source.copyWith(
      id: id,
      seed: seedValue,
      parameters: mergedParameters,
      clearSeeds: true,
      clearParameterSweeps: true,
      parentSpecId: source.id,
    );
  }

  String _buildExpandedId({
    required String parentId,
    required int? seed,
    required Map<String, String> parameters,
  }) {
    final buffer = StringBuffer(parentId);
    if (parameters.isNotEmpty) {
      final sorted = parameters.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in sorted) {
        buffer.write('+${entry.key}=${entry.value}');
      }
    }
    if (seed != null) {
      buffer.write('+seed=$seed');
    }
    return buffer.toString();
  }
}
