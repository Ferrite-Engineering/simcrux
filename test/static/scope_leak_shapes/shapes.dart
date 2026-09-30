// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Synthetic provider shapes exercising the reach analysis in
// `../per_tab_provider_scope_leak_test.dart`.
//
// Each shape reproduces an indirection through which a per-tab read is
// invisible to textual matching: the read is not written as a literal
// `ref.watch(xProvider)` inside the provider's own declaration. The analysis
// must resolve every one of them back to `seedProvider`. `decoyProvider` is the
// control: it names no per-tab state and must stay clean, so a test that passes
// by over-reporting fails here.
//
// This file is deliberately outside `lib/`, so the production scan never sees
// it; it is resolved on its own by the shape test.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stands in for a per-tab seed such as `selectedTestIdProvider`.
final seedProvider = Provider<int>((ref) => 0);

final unrelatedProvider = Provider<int>((ref) => 1);

// --- Shape 1: the read happens through a `Ref` stored on a field. ------------

class _StoredRefReader {
  _StoredRefReader(this._ref);
  final Ref _ref;

  int load() => _ref.watch(seedProvider);
}

final storedRefProvider = Provider<int>((ref) => _StoredRefReader(ref).load());

// --- Shape 2: the read happens inside a helper object's method. --------------

class _Helper {
  int compute(Ref ref) => ref.watch(seedProvider);
}

final helperObjectProvider = Provider<int>((ref) => _Helper().compute(ref));

// --- Shape 3: the read happens inside an extension method on `Ref`. ----------

extension _SeedReading on Ref {
  int get seedValue => watch(seedProvider);
}

final extensionProvider = Provider<int>((ref) => ref.seedValue);

// --- Shape 4: the provider argument is selected at run time. -----------------

// The family's inferred type is riverpod-internal and spelling it out here
// would pin the fixture to a riverpod version.
// ignore: specify_nonobvious_property_types
final familyProvider = Provider.family<int, String>((ref, key) => key.length);

Provider<int> _pick(bool flag) => flag ? seedProvider : unrelatedProvider;

final runtimeSelectedProvider = Provider<int>(
  (ref) => ref.watch(_pick(DateTime.now().isUtc)),
);

final familyArgProvider = Provider<int>(
  (ref) => ref.watch(familyProvider(DateTime.now().toIso8601String())),
);

// --- Shape 5: a two-hop chain, the reach the fixed point must still find. ----

final middleProvider = Provider<int>((ref) => ref.watch(seedProvider));
final leafProvider = Provider<int>((ref) => ref.watch(middleProvider));

// --- Control: reads only root state, must never be reported. -----------------

final decoyProvider = Provider<int>((ref) => ref.watch(unrelatedProvider));
