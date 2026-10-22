// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/flow_config.dart';

/// The `SimulatorBinaryConfig.options` key prefix the Settings values below
/// travel under to the flow drivers. The loader drops any project-file
/// option with this prefix, so a project cannot pose as the user's Settings.
const String kFlowSettingsOptionPrefix = 'settings.';

/// The user's Settings > Engines > Implementation flow values that are not
/// a driver's own binary path: how LibreLane is launched, where the PDKs
/// are, and the viewers and FuseSoC.
///
/// Settings-chosen values are the user's own and are not gated; a project
/// file can override some of them only under project-tooling consent.
@immutable
class FlowToolSettings {
  /// Creates the settings.
  const FlowToolSettings({
    this.launcher = FlowLauncher.path,
    this.pdkRoot = '',
    this.klayoutPath = '',
    this.openroadPath = '',
    this.fusesocPath = '',
    this.dockerImage = '',
  });

  /// The settings [options] carry, defaults for anything absent.
  factory FlowToolSettings.fromOptions(Map<String, String> options) {
    String read(String key) => options['$kFlowSettingsOptionPrefix$key'] ?? '';
    return FlowToolSettings(
      launcher:
          FlowLauncher.fromWireName(read('launcher')) ?? FlowLauncher.path,
      pdkRoot: read('pdk_root'),
      klayoutPath: read('klayout'),
      openroadPath: read('openroad'),
      fusesocPath: read('fusesoc'),
      dockerImage: read('docker_image'),
    );
  }

  /// How LibreLane is started.
  final FlowLauncher launcher;

  /// `PDK_ROOT` for LibreLane runs; empty uses the environment's.
  final String pdkRoot;

  /// The KLayout executable; empty uses `klayout` on PATH.
  final String klayoutPath;

  /// The OpenROAD executable; empty uses `openroad` on PATH.
  final String openroadPath;

  /// The FuseSoC executable; empty uses `fusesoc` on PATH.
  final String fusesocPath;

  /// The image the `docker` launcher runs.
  final String dockerImage;

  /// These values as `SimulatorBinaryConfig.options` entries, empty values
  /// left out.
  Map<String, String> toOptions() => <String, String>{
    '${kFlowSettingsOptionPrefix}launcher': launcher.wireName,
    if (pdkRoot.isNotEmpty) '${kFlowSettingsOptionPrefix}pdk_root': pdkRoot,
    if (klayoutPath.isNotEmpty)
      '${kFlowSettingsOptionPrefix}klayout': klayoutPath,
    if (openroadPath.isNotEmpty)
      '${kFlowSettingsOptionPrefix}openroad': openroadPath,
    if (fusesocPath.isNotEmpty)
      '${kFlowSettingsOptionPrefix}fusesoc': fusesocPath,
    if (dockerImage.isNotEmpty)
      '${kFlowSettingsOptionPrefix}docker_image': dockerImage,
  };

  @override
  bool operator ==(Object other) =>
      other is FlowToolSettings &&
      other.launcher == launcher &&
      other.pdkRoot == pdkRoot &&
      other.klayoutPath == klayoutPath &&
      other.openroadPath == openroadPath &&
      other.fusesocPath == fusesocPath &&
      other.dockerImage == dockerImage;

  @override
  int get hashCode => Object.hash(
    launcher,
    pdkRoot,
    klayoutPath,
    openroadPath,
    fusesocPath,
    dockerImage,
  );
}
