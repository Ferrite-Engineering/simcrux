// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';

/// What the probe found (or did not find) for one toolchain component.
@immutable
class RiscvComponentReport {
  /// Creates a [RiscvComponentReport].
  const RiscvComponentReport({
    required this.component,
    required this.binary,
    required this.found,
    this.version,
    this.remediation,
  });

  /// Which dependency this describes.
  final RiscvToolchainComponent component;

  /// The executable the probe tried, as it would appear on a command line.
  final String binary;

  /// True when the probe ran [binary] successfully.
  final bool found;

  /// The tool's banner line when [found]; null otherwise.
  final String? version;

  /// What the user should do about it, phrased for this component **on
  /// this platform**. Null when [found].
  ///
  /// **Unlocalized English**, deliberately, and this is the same channel as
  /// `SimulatorNotAvailableException.remediation` — a plain string with no
  /// localization path. It is what lands in logs, in a `failureMessage`,
  /// and in the plain-text diagnostics report. The *widget* that renders
  /// the toolchain panel does not print this: it renders localized copy
  /// keyed on [component] and the host platform, authored as widget
  /// strings from the start rather than plumbed out of a value object
  /// (this remediation string is the unlocalized, log-facing channel).
  final String? remediation;

  @override
  bool operator ==(Object other) =>
      other is RiscvComponentReport &&
      other.component == component &&
      other.binary == binary &&
      other.found == found &&
      other.version == version &&
      other.remediation == remediation;

  @override
  int get hashCode =>
      Object.hash(component, binary, found, version, remediation);

  @override
  String toString() =>
      'RiscvComponentReport(${component.wireName}, binary: $binary, '
      'found: $found, version: $version)';
}

/// The per-component result of one `RiscvToolchainProbe` run.
///
/// **Why this type exists at all.** `SimulatorDriver.detectVersion` returns
/// a single `String?`, which is adequate for Icarus and inadequate for a
/// driver with *four independent* dependencies where "not found" carries a
/// different remedy for each. The interface is still honored —
/// `RiscvArchDriver.detectVersion` returns [summaryLine] — but the panel
/// and the failure path get the structured form.
@immutable
class RiscvToolchainReport {
  /// Creates a [RiscvToolchainReport].
  RiscvToolchainReport({required List<RiscvComponentReport> components})
    : components = List<RiscvComponentReport>.unmodifiable(components);

  /// One entry per probed component, in [RiscvToolchainComponent]
  /// declaration order.
  final List<RiscvComponentReport> components;

  /// The report for [component], or null when it was not probed.
  RiscvComponentReport? operator [](RiscvToolchainComponent component) {
    for (final entry in components) {
      if (entry.component == component) return entry;
    }
    return null;
  }

  /// Components the probe could not run.
  List<RiscvComponentReport> get missing =>
      components.where((c) => !c.found).toList(growable: false);

  /// Components the probe ran successfully.
  List<RiscvComponentReport> get present =>
      components.where((c) => c.found).toList(growable: false);

  /// True when every probed component was found.
  bool get complete => components.isNotEmpty && missing.isEmpty;

  /// One line for the diagnostics panel and for
  /// `SimulatorDriver.detectVersion`.
  ///
  /// Lists what was found; when something is missing it says so and points
  /// at the panel rather than dumping four remediation paragraphs into a
  /// field sized for a version banner. Returns null when nothing at all was
  /// found, matching `detectVersion`'s "the tool is not installed" contract
  /// so the diagnostics probe simply omits the row.
  String? get summaryLine {
    if (components.isEmpty) return null;
    final found = present;
    if (found.isEmpty) return null;
    final parts = found
        .map((c) => '${c.component.wireName} ${_shortVersion(c.version)}')
        .join(' · ');
    if (missing.isEmpty) return parts;
    final absent = missing.map((c) => c.component.wireName).join(', ');
    return '$parts · missing: $absent';
  }

  /// A plain-text block for the App Diagnostics report and for log lines.
  /// Unlocalized, like the rest of that report's body.
  String toPlainText() {
    final buf = StringBuffer();
    for (final entry in components) {
      buf.writeln(
        '  ${entry.component.wireName.padRight(16)} '
        '${entry.found ? (entry.version ?? 'found') : 'NOT FOUND'}',
      );
      final remediation = entry.remediation;
      if (remediation != null) buf.writeln('    → $remediation');
    }
    return buf.toString();
  }

  static String _shortVersion(String? version) {
    if (version == null || version.trim().isEmpty) return 'found';
    final trimmed = version.trim();
    if (trimmed.length <= 48) return trimmed;
    return '${trimmed.substring(0, 47)}…';
  }
}
