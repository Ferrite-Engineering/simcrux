// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/cross_project_search_progress.dart';

void main() {
  group('CrossProjectSearchProgress', () {
    test('equality + hashCode field-by-field', () {
      const a = CrossProjectSearchProgress(
        projectId: 'p',
        projectName: 'P',
        status: CrossProjectSearchProgressStatus.searching,
        matchCount: 3,
      );
      const b = CrossProjectSearchProgress(
        projectId: 'p',
        projectName: 'P',
        status: CrossProjectSearchProgressStatus.searching,
        matchCount: 3,
      );
      const c = CrossProjectSearchProgress(
        projectId: 'p',
        projectName: 'P',
        status: CrossProjectSearchProgressStatus.searching,
        matchCount: 4,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('emptyWorkspace sentinel is completed', () {
      expect(
        CrossProjectSearchProgress.emptyWorkspace.status,
        CrossProjectSearchProgressStatus.completed,
      );
      expect(CrossProjectSearchProgress.emptyWorkspace.projectId, '');
    });

    test('truncated + error are visible on the model', () {
      const p = CrossProjectSearchProgress(
        projectId: 'p',
        projectName: 'P',
        status: CrossProjectSearchProgressStatus.failed,
        matchCount: 7,
        truncated: true,
        error: 'boom',
      );
      expect(p.truncated, true);
      expect(p.error, 'boom');
    });

    test('toString includes project + status + counts', () {
      const p = CrossProjectSearchProgress(
        projectId: 'p',
        projectName: 'P',
        status: CrossProjectSearchProgressStatus.searching,
        matchCount: 2,
      );
      expect(p.toString(), contains('P'));
      expect(p.toString(), contains('searching'));
      expect(p.toString(), contains('matches: 2'));
    });
  });
}
