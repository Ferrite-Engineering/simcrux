// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:meta/meta.dart';

/// How a LibreLane entry is started.
///
/// `path` runs a `librelane` executable (on `PATH`, or the one Settings or
/// the project names). `nix` runs it inside `nix develop` in a LibreLane
/// checkout. `docker` runs it in a container SimCrux names, so a cancel can
/// stop the container as well as the client.
enum FlowLauncher {
  /// A `librelane` executable.
  path('path'),

  /// `nix develop <checkout> --command librelane …`.
  nix('nix'),

  /// `docker run --name <container> <image> librelane …`.
  docker('docker');

  const FlowLauncher(this.wireName);

  /// The `launcher:` value in `simcrux.yaml` and the Settings key value.
  final String wireName;

  /// The launcher [wireName] names, or null.
  static FlowLauncher? fromWireName(Object? wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// The FPGA families a nextpnr entry may target.
///
/// Each one is a `synth_<family>` Yosys pass and a nextpnr architecture:
/// `nextpnr-ice40`, `nextpnr-ecp5`, and `nextpnr-himbaechel` for Gowin and
/// GateMate (one report schema for all four, measured).
enum NextpnrFamily {
  /// Lattice iCE40.
  ice40('ice40', 'nextpnr-ice40'),

  /// Lattice ECP5.
  ecp5('ecp5', 'nextpnr-ecp5'),

  /// Gowin, through himbaechel.
  gowin('gowin', 'nextpnr-himbaechel'),

  /// Cologne Chip GateMate, through himbaechel.
  gatemate('gatemate', 'nextpnr-himbaechel');

  const NextpnrFamily(this.wireName, this.binary);

  /// The `family:` value in `simcrux.yaml`.
  final String wireName;

  /// The nextpnr executable for this family.
  final String binary;

  /// The family [wireName] names, or null.
  static NextpnrFamily? fromWireName(Object? wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// The `gls:` sub-block of a LibreLane entry: which tests rerun at gate
/// level against this entry's netlist.
///
/// Parsed and validated here so a project written for gate-level simulation
/// loads; the runner that reads it is separate.
@immutable
class FlowGlsConfig {
  /// Creates the block.
  const FlowGlsConfig({
    this.tests = const <String>[],
    this.netlist = 'nl',
    this.strictX = false,
    this.clock,
  });

  /// The netlists a run writes that gate-level simulation may read.
  static const List<String> kNetlists = <String>['nl', 'pnl'];

  /// SimCrux test names or `tag:<tag>` selectors.
  final List<String> tests;

  /// `nl` (the default) or `pnl`.
  final String netlist;

  /// Whether a difference that is only X-asymmetry fails the test.
  final bool strictX;

  /// The clock the comparison samples on, when the RTL top has more than
  /// one.
  final String? clock;

  @override
  bool operator ==(Object other) =>
      other is FlowGlsConfig &&
      _listEq(other.tests, tests) &&
      other.netlist == netlist &&
      other.strictX == strictX &&
      other.clock == clock;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(tests), netlist, strictX, clock);
}

/// The `equiv:` sub-block of a LibreLane entry: the netlist-equivalence
/// check's per-entry options.
@immutable
class FlowEquivConfig {
  /// Creates the block.
  const FlowEquivConfig({
    this.partitionTimeoutS,
    this.acceptBlackbox = const <String>[],
  });

  /// Seconds per partition; a timed-out partition is inconclusive.
  final int? partitionTimeoutS;

  /// Cell-type globs the user accepts as unproven.
  final List<String> acceptBlackbox;

  @override
  bool operator ==(Object other) =>
      other is FlowEquivConfig &&
      other.partitionTimeoutS == partitionTimeoutS &&
      _listEq(other.acceptBlackbox, acceptBlackbox);

  @override
  int get hashCode =>
      Object.hash(partitionTimeoutS, Object.hashAll(acceptBlackbox));
}

/// The `fusesoc:` sub-block of a nextpnr entry: the core and target FuseSoC
/// builds instead of SimCrux's own synthesis and place-and-route.
@immutable
class FlowFusesocConfig {
  /// Creates the block.
  const FlowFusesocConfig({
    required this.core,
    required this.target,
    this.binary,
  });

  /// The VLNV of the core (`award-winning:serv:servant`).
  final String core;

  /// The FuseSoC target (`icebreaker`).
  final String target;

  /// A `fusesoc` executable the project names. Honoured only under
  /// project-tooling consent.
  final String? binary;

  @override
  bool operator ==(Object other) =>
      other is FlowFusesocConfig &&
      other.core == core &&
      other.target == target &&
      other.binary == binary;

  @override
  int get hashCode => Object.hash(core, target, binary);
}

/// One entry of the `flow:` block: one implementation-flow run, which
/// becomes one `TestSpec` in the synthesised `flow` suite.
///
/// Paths are as written in the project file until the loader resolves them
/// against [projectRoot]. Keys that choose an executable or argv
/// ([launcher], [librelaneBinary], [dockerImage], [fusesoc], [extraArgs],
/// [handoff]) reach this object only when the user allowed project-defined
/// tooling; otherwise the loader dropped or refused them.
///
/// **Never tier-gated.** A flow verdict is correctness and is free.
@immutable
class FlowEntry {
  /// Creates an entry.
  FlowEntry({
    required this.name,
    required this.kind,
    this.config,
    this.launcher,
    this.librelaneBinary,
    this.dockerImage,
    this.pdk,
    this.tagPrefix = kDefaultTagPrefix,
    this.gls,
    this.equiv,
    this.family,
    this.device,
    this.package,
    this.constraints,
    this.top,
    List<String> sources = const <String>[],
    this.freqMhz,
    this.detailedTiming = false,
    this.netlist,
    this.fusesoc,
    List<String> extraArgs = const <String>[],
    Map<String, List<String>> handoff = const <String, List<String>>{},
    this.projectRoot,
  }) : sources = List<String>.unmodifiable(sources),
       extraArgs = List<String>.unmodifiable(extraArgs),
       handoff = Map<String, List<String>>.unmodifiable(
         handoff.map((k, v) => MapEntry(k, List<String>.unmodifiable(v))),
       );

  /// The run-tag prefix when the entry names none.
  static const String kDefaultTagPrefix = 'simcrux';

  /// The viewers a `handoff:` block may give a command for.
  static const List<String> kHandoffViewers = <String>[
    'klayout',
    'openroad_gui',
    'nextpnr_gui',
  ];

  /// The entry's name, one safe path segment, unique in the project.
  final String name;

  /// LibreLane or nextpnr.
  final FlowKind kind;

  /// LibreLane: the design configuration file.
  final String? config;

  /// LibreLane: how LibreLane is started, when the project chose.
  final FlowLauncher? launcher;

  /// LibreLane: a `librelane` executable the project names.
  final String? librelaneBinary;

  /// LibreLane: the image the `docker` launcher runs.
  final String? dockerImage;

  /// LibreLane: the PDK name (`sky130A`).
  final String? pdk;

  /// LibreLane: the run tag is `<tagPrefix>-<UTC timestamp>`.
  final String tagPrefix;

  /// LibreLane: the gate-level simulation block.
  final FlowGlsConfig? gls;

  /// LibreLane: the netlist-equivalence block.
  final FlowEquivConfig? equiv;

  /// nextpnr: the FPGA family.
  final NextpnrFamily? family;

  /// nextpnr: the device (`up5k`, `25k`, `GW1NR-LV9QN88PC6/I5`, `CCGM1A1`).
  final String? device;

  /// nextpnr: the package (`sg48`, `CABGA256`).
  final String? package;

  /// nextpnr: the constraints file (`.pcf`, `.lpf`, `.cst`, `.ccf`).
  final String? constraints;

  /// nextpnr: the top module.
  final String? top;

  /// nextpnr: the RTL sources.
  final List<String> sources;

  /// nextpnr: the target clock frequency.
  final double? freqMhz;

  /// nextpnr: whether `--detailed-timing-report` is passed.
  final bool detailedTiming;

  /// nextpnr: the synthesised netlist a worst path is mapped back to the RTL
  /// through, as a path inside the run directory (`netlist.json`,
  /// `build/top.json`). When it names no file the run holds, the mapping
  /// falls back to `synth.json`, then to the run's single Yosys netlist.
  ///
  /// Never absolute and never leaving the run directory
  /// ([netlistPathProblem]).
  final String? netlist;

  /// nextpnr: a FuseSoC core and target built instead.
  final FlowFusesocConfig? fusesoc;

  /// nextpnr: arguments appended to the nextpnr command line.
  final List<String> extraArgs;

  /// Per-viewer hand-off commands the project names (viewer id from
  /// [kHandoffViewers] to argv with `{run_dir}`, `{gds}`, `{odb}`, `{json}`
  /// placeholders).
  final Map<String, List<String>> handoff;

  /// The directory of the project file the entry came from, set by the
  /// loader. Run roots must resolve inside it.
  final String? projectRoot;

  /// Whether this is a FuseSoC-built nextpnr entry.
  bool get isFusesoc => fusesoc != null;

  /// Why [value] cannot be a [netlist] path, or null when it can: it is
  /// empty, absolute (a rooted path or a drive), holds a NUL or a line
  /// break, or has a `..` segment.
  static String? netlistPathProblem(String value) {
    if (value.trim().isEmpty) return 'it is empty';
    if (value.contains('\x00')) return 'it contains a NUL byte';
    if (value.contains('\n') || value.contains('\r')) {
      return 'it contains a line break';
    }
    if (value.startsWith('/') ||
        value.startsWith(r'\') ||
        value.startsWith('~') ||
        RegExp('^[A-Za-z]:').hasMatch(value)) {
      return 'it must be relative to the run directory';
    }
    if (value.split(RegExp(r'[/\\]')).contains('..')) {
      return 'it must stay inside the run directory';
    }
    return null;
  }

  /// A copy with the given fields replaced.
  FlowEntry copyWith({
    String? config,
    String? constraints,
    List<String>? sources,
    String? projectRoot,
  }) => FlowEntry(
    name: name,
    kind: kind,
    config: config ?? this.config,
    launcher: launcher,
    librelaneBinary: librelaneBinary,
    dockerImage: dockerImage,
    pdk: pdk,
    tagPrefix: tagPrefix,
    gls: gls,
    equiv: equiv,
    family: family,
    device: device,
    package: package,
    constraints: constraints ?? this.constraints,
    top: top,
    sources: sources ?? this.sources,
    freqMhz: freqMhz,
    detailedTiming: detailedTiming,
    netlist: netlist,
    fusesoc: fusesoc,
    extraArgs: extraArgs,
    handoff: handoff,
    projectRoot: projectRoot ?? this.projectRoot,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FlowEntry) return false;
    if (other.handoff.length != handoff.length) return false;
    for (final entry in handoff.entries) {
      final theirs = other.handoff[entry.key];
      if (theirs == null || !_listEq(theirs, entry.value)) return false;
    }
    return other.name == name &&
        other.kind == kind &&
        other.config == config &&
        other.launcher == launcher &&
        other.librelaneBinary == librelaneBinary &&
        other.dockerImage == dockerImage &&
        other.pdk == pdk &&
        other.tagPrefix == tagPrefix &&
        other.gls == gls &&
        other.equiv == equiv &&
        other.family == family &&
        other.device == device &&
        other.package == package &&
        other.constraints == constraints &&
        other.top == top &&
        _listEq(other.sources, sources) &&
        other.freqMhz == freqMhz &&
        other.detailedTiming == detailedTiming &&
        other.netlist == netlist &&
        other.fusesoc == fusesoc &&
        _listEq(other.extraArgs, extraArgs) &&
        other.projectRoot == projectRoot;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    name,
    kind,
    config,
    launcher,
    librelaneBinary,
    dockerImage,
    pdk,
    tagPrefix,
    gls,
    equiv,
    family,
    device,
    package,
    constraints,
    top,
    Object.hashAll(sources),
    freqMhz,
    detailedTiming,
    netlist,
    fusesoc,
    Object.hashAll(extraArgs),
    Object.hashAllUnordered(
      handoff.entries.map((e) => Object.hash(e.key, Object.hashAll(e.value))),
    ),
    projectRoot,
  ]);

  @override
  String toString() => 'FlowEntry($name, ${kind.wireName})';
}

/// The project's `flow:` block: the entries SimCrux runs and the paths it
/// indexes read-only.
@immutable
class FlowConfig {
  /// Creates the block.
  FlowConfig({
    List<FlowEntry> entries = const <FlowEntry>[],
    List<String> ingest = const <String>[],
  }) : entries = List<FlowEntry>.unmodifiable(entries),
       ingest = List<String>.unmodifiable(ingest);

  /// The entries, in declaration order.
  final List<FlowEntry> entries;

  /// Run directories and `report.json` files to index, as written.
  final List<String> ingest;

  /// This block followed by [other]'s entries and ingest paths.
  FlowConfig followedBy(FlowConfig other) => FlowConfig(
    entries: <FlowEntry>[...entries, ...other.entries],
    ingest: <String>[...ingest, ...other.ingest],
  );

  @override
  bool operator ==(Object other) =>
      other is FlowConfig &&
      _listEq(other.entries, entries) &&
      _listEq(other.ingest, ingest);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(entries), Object.hashAll(ingest));
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
