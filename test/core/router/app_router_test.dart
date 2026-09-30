// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simcrux/core/router/app_router.dart';

void main() {
  group('appRouterProvider', () {
    test('initialLocation is / (the workspace screen)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Reading the provider builds the router; pre-routerDelegate
      // initialization the runtime URI is empty, but the configured
      // initial location is observable via the route table's first
      // top-level entry.
      final router = container.read(appRouterProvider);
      final firstTopLevel = router.configuration.routes
          .whereType<GoRoute>()
          .first;
      expect(firstTopLevel.path, '/');
      expect(firstTopLevel.name, 'workspace');
    });

    test('route table contains the workspace-era named routes', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final router = container.read(appRouterProvider);
      final names = <String>{};
      void collect(List<RouteBase> routes) {
        for (final route in routes) {
          if (route is GoRoute && route.name != null) {
            names.add(route.name!);
          }
          collect(route.routes);
        }
      }

      collect(router.configuration.routes);
      // `project` is retired (workspace now owns the project landing);
      // `welcome` was the legacy Welcome screen, replaced by
      // `workspace`.
      expect(
        names,
        containsAll(<String>{
          'workspace',
          'settings',
          'run',
          'testDetail',
        }),
      );
      expect(names.contains('welcome'), isFalse);
      expect(names.contains('project'), isFalse);
    });
  });
}
