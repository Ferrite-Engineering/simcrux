// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_handoff_provider.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';
import 'package:simcrux/services/flow/nextpnr_flow_driver.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Every Flow binding is reached from the app or the binary: a driver
/// nothing registers, an importer nothing calls or a CLI nothing routes to
/// would ship green and dead.
void main() {
  String source(String path) => File(path).readAsStringSync();

  test('both drivers are registered in the app registry', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final registry = container.read(simulatorDriverRegistryProvider);
    expect(registry.driverFor('librelane'), isA<LibreLaneFlowDriver>());
    expect(registry.driverFor('nextpnr'), isA<NextpnrFlowDriver>());
  });

  test('both drivers are registered in the headless registry', () {
    final registry = SimcruxCli.defaultDriverRegistry();
    expect(registry.driverFor('librelane'), isA<LibreLaneFlowDriver>());
    expect(registry.driverFor('nextpnr'), isA<NextpnrFlowDriver>());
  });

  test('the loader builds the flow suite through the importer', () {
    final loader = source('lib/services/config/config_loader.dart');
    expect(loader, contains('importer.suiteFor('));
    expect(loader, contains("part 'config_loader_flow.dart';"));
  });

  test('flow is a subcommand of the binary and of the app', () {
    expect(CliArgParser.kSubcommands, contains('flow'));
    expect(
      source('lib/core/cli/simcrux_cli.dart'),
      contains('FlowCli('),
    );
    expect(source('lib/app.dart'), contains('FlowCli('));
  });

  test('the ingestor is reached by the CLI and by the regression runner', () {
    expect(source('lib/core/cli/flow_cli.dart'), contains('ingestor.ingest('));
    expect(
      source('lib/features/dashboard/providers/regression_runner.dart'),
      contains('FlowRunIngestor.readForResult('),
    );
  });

  test('the probe is reached by Settings and by the hand-off', () {
    expect(
      source(
        'lib/features/settings/widgets/settings_implementation_flow_section.dart',
      ),
      contains('FlowToolchainProbe()'),
    );
    expect(
      source('lib/services/flow/flow_handoff_launcher.dart'),
      contains('_probe.guidanceFor('),
    );
  });

  test('the inspector hands a flow result to the launcher', () {
    expect(
      source('lib/features/inspector/widgets/inspector_actions.dart'),
      contains('flowHandoffButtons('),
    );
    expect(
      source('lib/features/inspector/widgets/flow_handoff_buttons.dart'),
      contains('flowHandoffLauncherProvider'),
    );
  });

  test('the hand-off launcher is bound to the consented telemetry', () {
    const service = NoopTelemetryService();
    final container = ProviderContainer(
      overrides: [telemetryServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final launcher = container.read(flowHandoffLauncherProvider);
    expect(launcher, isA<FlowHandoffLauncher>());
    expect(launcher.telemetry, same(service));
  });
}
