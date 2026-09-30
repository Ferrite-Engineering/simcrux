// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// SimCrux's enablement of the ROUTE-MOUNTED per-tab scope-leak guard.
//
// The rule itself — what it catches, its three accepted forms of re-binding,
// and the seven things it deliberately does NOT catch — lives once in
// crux-shared, next to the scanner it depends on. Read that file first; this
// one only supplies SimCrux's source roots and per-tab seed list.
//
// Why the rule exists, in SimCrux's own terms: a dialog route is a child of
// the Navigator, which sits ABOVE the per-tab `UncontrolledProviderScope`. A
// widget mounted from `showDialog` that reads a per-tab provider through
// `WidgetRef` therefore resolves the ROOT container, where no config is
// loaded. The sibling `per_tab_provider_scope_leak_test` cannot see this: it
// analyses the *provider* graph, and this is a *widget*.
//
// SimCrux had exactly this defect. `LogViewerDialog` watched
// `fullInspectorLogProvider` — per-tab, re-bound by `simcruxTabOverrides` —
// with its own `ref` and no scope on the path, so Inspector → "Open full log"
// rendered the "No log output" empty state over an inspector that was visibly
// streaming lines, and search / jump-to-line / Copy all operated on nothing
// (fixed in `5f15c0f`). It was invisible to the existing tests because every
// one of them pumped the dialog under a single `ProviderScope`, so the button
// and the dialog shared a container.
//
// SEED SET: BOTH MODES, UNIONED — and why that differs from the sibling
// The sibling provider guard is deliberately split by mode: the open-core copy
// validates the open-core effective list over `lib/` alone, and the Pro
// overlay's copy validates the Pro effective list over both trees, because the
// Pro overlay *replaces* `simcruxTabOverrides` with `proTabOverrides` and
// re-homes several providers as root per-project delegates. Splitting is right
// there — that guard reasons about which container a PROVIDER is materialized
// in, which genuinely differs per mode.
//
// This rule does not. It asks a structural question about a WIDGET's route:
// is there a container re-bind between the Navigator and a per-tab read? The
// answer must hold in whichever mode the binary ships, so the seed set is the
// union of both lists — the safe over-approximation. A provider that is
// per-tab only in open-core mode (SimCrux Pro re-homes `activeConfig`,
// `resultStore`, the filter/sort/selection family and `trendStore` to root
// delegates) is still a leak for an open-core user, and a union keeps it
// flagged.
//
// The allowlist is deliberately empty. A violation is fixed, not listed.

import 'dart:io';

import '../../crux-shared/packages/crux_workspace/test/static/route_mounted_scope_leak_guard.dart';

/// The open-core per-tab override list, as `path#symbol`.
const String _coreSeedSpec =
    'lib/features/workspace/providers/simcrux_tab_overrides.dart'
    '#simcruxTabOverrides';

/// The Pro overlay's per-tab override list, relative to this checkout. Absent
/// in a standalone open-core checkout, where it contributes no seeds.
const String _proSeedSpec =
    '../lib/features/workspace/providers/pro_tab_overrides.dart'
    '#proTabOverrides';

void main() {
  defineRouteMountedScopeLeakGuard(
    sourceRoots: _sourceRoots,
    // The two mode-specific per-tab lists the sibling guards each validate on
    // their own — open-core `simcruxTabOverrides` and, when the Pro overlay is
    // checked out around this repo, `proTabOverrides`. See the header for why
    // this rule unions them instead of picking one.
    seedOverrideSpecs: const [_coreSeedSpec, _proSeedSpec],
    bootstrapHint: 'run `flutter pub get` in simcrux/',
  );
}

/// Open-core `lib/`, plus the Pro overlay's `lib/` when this checkout is the
/// Pro overlay's submodule — so a taint chain crossing the repo boundary
/// still resolves. A standalone open-core checkout scans open-core only.
List<Directory> _sourceRoots() {
  final roots = <Directory>[Directory('lib')];
  final proLib = Directory('../lib');
  if (proLib.existsSync() && File('../lib/overrides.dart').existsSync()) {
    roots.add(proLib);
  }
  return roots;
}
