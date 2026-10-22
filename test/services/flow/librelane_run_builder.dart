// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Final metrics inside every verdict limit, by the meaning of each metric
/// (a non-negative slack, zero violations), not by any reader's output.
const Map<String, Object?> cleanMetrics = <String, Object?>{
  'timing__setup__ws': 1.25,
  'timing__hold__ws': 0.18,
  'timing__setup__wns': 0,
  'timing__setup_vio__count': 0,
  'timing__hold_vio__count': 0,
  'route__drc_errors': 0,
  'magic__drc_error__count': 0,
  'design__lvs_error__count': 0,
  'route__antenna_violation__count': 0,
  'antenna__violating__nets': 0,
  'design__xor_difference__count': 0,
  'design__instance__count': 412,
};

/// Builds a LibreLane run directory by hand, following the layout the plan
/// documents (`runs/<tag>/`, `resolved.json`, `NN-<tool>-<step>/` with
/// `state_out.json` once complete, `final/metrics.json`). No LibreLane is
/// run: these runs exercise the edges of SimCrux's reading that the
/// captured fixtures (`verification/fixtures/flow/librelane/`) do not.
class LibreLaneRunBuilder {
  /// Creates `<base>/runs/<tag>/` with a `resolved.json` stating [version]
  /// (or none) and [pdk].
  LibreLaneRunBuilder(
    String base, {
    String tag = 'RUN_2026-10-21_12-00-00',
    String? version = '3.0.16',
    String? openlaneVersion,
    String pdk = 'sky130A',
  }) : root = p.join(base, 'runs', tag) {
    Directory(root).createSync(recursive: true);
    File(p.join(root, 'resolved.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'meta': <String, Object?>{
          'librelane_version': ?version,
          'openlane_version': ?openlaneVersion,
        },
        'PDK': pdk,
        'DESIGN_NAME': 'counter',
      }),
    );
  }

  /// The run root.
  final String root;

  int _ordinal = 0;

  /// Adds the next step directory; [complete] writes its `state_out.json`.
  void step(String id, {bool complete = true}) {
    _ordinal++;
    final dir = Directory(
      p.join(root, '${_ordinal.toString().padLeft(2, '0')}-$id'),
    )..createSync();
    File(p.join(dir.path, 'config.json')).writeAsStringSync('{}');
    if (complete) {
      File(p.join(dir.path, 'state_out.json')).writeAsStringSync('{}');
    }
  }

  /// Writes `final/metrics.json`.
  void finalMetrics(Map<String, Object?> metrics) {
    Directory(p.join(root, 'final')).createSync(recursive: true);
    File(
      p.join(root, 'final', 'metrics.json'),
    ).writeAsStringSync(jsonEncode(metrics));
  }
}
