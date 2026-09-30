// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/theme/simcrux_theme.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/plugins/extra_localizations_delegates_provider.dart';
import 'package:simcrux/web/web_dashboard_screen.dart';
import 'package:simcrux/web/web_results_provider.dart';

/// Root widget for the read-only web build.
///
/// This is a deliberately small subset of [SimcruxApp]:
///
/// - no router, no settings, no scheduler, no file watcher;
/// - a single [WebDashboardScreen] reading from
///   [webResultsProvider] which fetches a `simcrux-results.json`
///   (or `results.ndjson`) bundled or referenced via `?results=`
///   URL parameter;
/// - same theme + localization as the desktop build so users get
///   the familiar look from the moment a teammate shares a link.
class SimcruxWebApp extends ConsumerWidget {
  /// Creates a [SimcruxWebApp].
  const SimcruxWebApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'SimCrux',
      theme: SimcruxTheme.light(),
      darkTheme: SimcruxTheme.dark(),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        ...ref.watch(extraLocalizationsDelegatesProvider),
      ],
      supportedLocales: L10N.supportedLocales,
      home: const WebDashboardScreen(),
    );
  }
}
