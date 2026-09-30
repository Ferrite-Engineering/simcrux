// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';

/// The surfaces an action can be discovered from.
enum SimcruxActionSurface {
  /// The app toolbar's icon buttons. `SimcruxToolbar` places its buttons
  /// by hand rather than reading this set, so the conformance test holds
  /// the two together.
  toolbar,

  /// The desktop menu bar, and the toolbar's overflow menu (every category
  /// but App).
  menu,

  /// The command palette's searchable list.
  palette,
}

/// Where an action appears and when it is usable.
///
/// One descriptor per action, resolved by an exhaustive switch in
/// `simcrux_action_descriptors.dart`, so adding an enum value fails to compile
/// until its placement and gating are declared. Never re-introduce a
/// per-surface "hidden actions" set or a per-surface enablement copy — that
/// architecture is exactly what drifted apart across the four products.
@immutable
class SimcruxActionDescriptor {
  /// Creates a descriptor. The default is invisible-everywhere and
  /// always-enabled, so a surface-less action must opt in explicitly.
  const SimcruxActionDescriptor({
    this.surfaces = const <SimcruxActionSurface>{},
    this.isEnabled = _alwaysTrue,
  });

  /// The surfaces this action structurally appears in.
  final Set<SimcruxActionSurface> surfaces;

  /// Whether the action is currently invocable.
  ///
  /// A visible-but-disabled action renders greyed rather than vanishing, so
  /// the menu keeps a stable shape and the user can see the command exists.
  /// The command palette is the exception — it has no greyed state, so it
  /// omits disabled entries.
  final bool Function(SimcruxActionContext) isEnabled;

  static bool _alwaysTrue(SimcruxActionContext _) => true;
}
