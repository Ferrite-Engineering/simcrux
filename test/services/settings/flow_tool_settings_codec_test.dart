// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

/// Settings > Engines > Implementation flow persists under `simcrux.*`, the
/// namespace both prefs domains use (the open core's and the Pro
/// overlay's write the same keys through this one codec), and travels to
/// the flow drivers as `settings.*` options.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const codec = SimcruxSettingsCodec();
  const chosen = FlowToolSettings(
    launcher: FlowLauncher.docker,
    dockerImage: 'example/librelane:3.0',
    pdkRoot: '/pdks',
    klayoutPath: '/opt/klayout/klayout',
    openroadPath: '/opt/openroad/bin/openroad',
    fusesocPath: '/usr/local/bin/fusesoc',
  );

  test('defaults: the path launcher and nothing set', () async {
    final loaded = await codec.load(await SharedPreferences.getInstance());
    expect(loaded.flowTools, const FlowToolSettings());
    expect(loaded.flowTools.launcher, FlowLauncher.path);
  });

  test('every value round-trips under simcrux.* keys', () async {
    final prefs = await SharedPreferences.getInstance();
    await codec.save(prefs, const AppSettings(flowTools: chosen));
    final loaded = await codec.load(prefs);
    expect(loaded.flowTools, chosen);
    for (final key in const [
      SimcruxSettingsCodec.kFlowLauncher,
      SimcruxSettingsCodec.kFlowDockerImage,
      SimcruxSettingsCodec.kFlowPdkRoot,
      SimcruxSettingsCodec.kFlowKlayoutPath,
      SimcruxSettingsCodec.kFlowOpenroadPath,
      SimcruxSettingsCodec.kFlowFusesocPath,
    ]) {
      expect(key, startsWith('simcrux.'));
      expect(prefs.containsKey(key), isTrue, reason: key);
    }
    expect(prefs.getString(SimcruxSettingsCodec.kFlowLauncher), 'docker');
  });

  test(
    'a launcher this build does not know reads as the path launcher',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SimcruxSettingsCodec.kFlowLauncher: 'podman',
      });
      final loaded = await codec.load(await SharedPreferences.getInstance());
      expect(loaded.flowTools.launcher, FlowLauncher.path);
    },
  );

  test('the drivers read the same values back from settings.* options', () {
    final options = chosen.toOptions();
    expect(
      options.keys.every((k) => k.startsWith(kFlowSettingsOptionPrefix)),
      isTrue,
    );
    expect(FlowToolSettings.fromOptions(options), chosen);
    expect(
      FlowToolSettings.fromOptions(const <String, String>{}),
      const FlowToolSettings(),
    );
  });
}
