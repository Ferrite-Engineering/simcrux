// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:url_launcher/url_launcher.dart';

/// Opens an external URL in the user's browser.
///
/// A mutable top-level seam rather than a direct `launchUrl` call so widget
/// tests can exercise Help → Documentation without the `url_launcher`
/// platform channel.
Future<bool> Function(Uri uri) simcruxLaunchUrl = launchUrl;
