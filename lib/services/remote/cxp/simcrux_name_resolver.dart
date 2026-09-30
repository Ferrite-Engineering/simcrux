// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:meta/meta.dart';

/// Maps SimCrux's natural references into and out of canonical
/// [ElementId]s for the v1 CXP wire format.
///
/// SimCrux's natural references are tests (suite-qualified test ids,
/// optionally seed-/parameter-suffixed), breakpoints (file:line — the
/// breakpoint editor surface lands in a follow-up; the resolver mapping
/// is in place so cross-product cross-probe works the day breakpoints
/// arrive), source-code locations (file + optional line), and waveform
/// files emitted by simulation runs (VCD / FST / GHW paths).
///
/// **Waveform → source mapping (the v1 vocabulary trick).** v1 CXP does
/// not define a `request_open_waveform` message kind. SimCrux's marquee
/// "Debug in WaveCrux" flow models the waveform file as an
/// [ElementKind.source] whose [ElementId.path] is the waveform file's
/// absolute path. Receivers (WaveCrux) inspect the path's extension
/// (`.vcd` / `.fst` / `.ghw` / `.wavecrux`) and treat it as a waveform
/// to open rather than a source file to edit. The dedicated message
/// type (`request_open_waveform`) is not part of CXP v1.
///
/// **Stateless and thread-safe** per the [NameResolver] contract — the
/// resolver is a pure shape-translation layer with no per-call state.
@immutable
class SimCruxNameResolver implements NameResolver {
  /// Creates a SimCrux-flavored name resolver.
  const SimCruxNameResolver();

  /// File extensions SimCrux treats as waveform files when emitting or
  /// receiving an [ElementKind.source] reference. Lowercase, leading
  /// dot included for direct string comparison.
  static const Set<String> waveformExtensions = <String>{
    '.vcd',
    '.fst',
    '.ghw',
    '.wavecrux',
  };

  /// Returns `true` if [path] looks like a waveform file SimCrux can
  /// hand off to WaveCrux via the [ElementKind.source] vocabulary.
  ///
  /// Used by the inbound `request_highlight` handler to disambiguate
  /// "open this waveform" from "open this source file" when both fall
  /// under the v1 [ElementKind.source] kind.
  static bool looksLikeWaveformPath(String path) {
    final lower = path.toLowerCase();
    for (final ext in waveformExtensions) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  @override
  ElementId? toCanonical({required ElementKind kind, required String local}) {
    if (local.isEmpty) return null;
    switch (kind.known) {
      case null:
        // [ElementKind] is an open wire type: a peer built against a
        // later protocol revision (or a third-party tool with its own
        // vocabulary) may name a kind this build has never heard of.
        // The resolver has no local vocabulary to map it into, so it
        // declines rather than throwing — an unrecognised kind is not
        // an error, it is a kind we simply do not participate in.
        return null;
      case KnownElementKind.test:
      case KnownElementKind.breakpoint:
      case KnownElementKind.source:
      case KnownElementKind.signal:
      case KnownElementKind.scope:
      case KnownElementKind.instance:
      case KnownElementKind.net:
      case KnownElementKind.port:
      case KnownElementKind.marker:
      case KnownElementKind.rule:
        // The element kinds SimCrux participates in (whether
        // originating or receiving) all carry an opaque string
        // identifier on the wire. Tests are canonicalised as
        // `<suite>/<name>[+param=value...][+seed=N]` (the value of
        // `TestSpec.id`, already canonical at construction); breakpoints
        // and source locations are canonicalised as `file[:line[:col]]`;
        // waveform-source references are canonicalised as the absolute
        // file path. Each form is already canonical at the call site —
        // SimCrux producers are responsible for handing the resolver
        // the right string. The resolver passes the local form through
        // unchanged.
        return ElementId(kind: kind, path: local);
    }
  }

  @override
  String? toLocal(ElementId id) {
    if (id.path.isEmpty) return null;
    switch (id.kind.known) {
      case null:
        // Same forward-compatibility contract as [toCanonical]: an
        // unknown kind has no local form, so decline gracefully.
        return null;
      case KnownElementKind.test:
      case KnownElementKind.breakpoint:
      case KnownElementKind.source:
      case KnownElementKind.signal:
      case KnownElementKind.scope:
      case KnownElementKind.instance:
      case KnownElementKind.net:
      case KnownElementKind.port:
      case KnownElementKind.marker:
      case KnownElementKind.rule:
        return id.path;
    }
  }
}
