// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

// The Flutter-free barrels only: this file sits inside the headless CLI's
// import closure (`SimcruxCli` → here), which `dart build cli` links without
// `dart:ui`.
import 'package:crux_license/crux_license_core.dart';
import 'package:crux_policy/crux_policy.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

/// Environment variable naming a licence file for headless runs.
const String kSimcruxLicenseFileEnvVar = 'SIMCRUX_LICENSE_FILE';

/// A licence source the user named explicitly (`--license-file` or
/// [kSimcruxLicenseFileEnvVar]) could not be read.
///
/// Fatal for the run: a CI job that asked for a licence and silently ran as
/// Open Core would drop every Pro sweep and still report success.
class HeadlessLicenseException implements Exception {
  /// Creates the exception with a user-facing [message].
  const HeadlessLicenseException(this.message);

  /// What went wrong, naming the source.
  final String message;

  @override
  String toString() => message;
}

/// The tier a headless run resolved, and what to tell the user about it.
@immutable
class HeadlessLicenseResolution {
  /// Creates a resolution.
  const HeadlessLicenseResolution({
    required this.tier,
    this.notes = const <String>[],
  });

  /// The tier the project should load at.
  final LicenseTier tier;

  /// Lines worth printing: where the licence came from, or why it was not
  /// honoured.
  final List<String> notes;
}

/// Resolves the licence tier for `--ci` without the desktop app's licence
/// store.
///
/// The desktop app learns its tier from a keychain-backed licence controller
/// that starts asynchronously; a CI agent has no keychain entry and no GUI
/// session. So a headless run looks for a credential in, first hit wins:
///
/// 1. `--license-file <path>`
/// 2. the [kSimcruxLicenseFileEnvVar] environment variable
/// 3. the `license` key of the organization's `.crux-policy.json`
///    (inline, or a file path)
///
/// and validates it offline with [CruxLicenseValidator.production] — the
/// same Ed25519 check the desktop app runs, with no network call. Licence
/// files parse at every tier. An expired licence keeps its tier through the
/// suite grace period, as it does in the app. Anything that does not resolve
/// to a grant runs as Open Core with a note saying why; a source the user
/// named explicitly that cannot be read throws [HeadlessLicenseException].
///
/// A machine file — the offline-activation credential — resolves only on the
/// machine whose fingerprint it names, so for one of those the resolver also
/// says which machine this is. It reads the suite's shared fingerprint file
/// ([SharedInstallFingerprint]) — the one the desktop app of every EDACrux
/// product on this account writes too — never the OS credential store: that
/// store is a plugin this binary cannot link, and on a build agent it would
/// block on a prompt. A licence key or licence file names no machine and
/// needs no fingerprint.
///
/// The result passes through [applyLicenseTierOverride], so a build made with
/// `--dart-define=LICENSE_TIER=…` behaves the same headless as in the app.
class HeadlessLicenseTierResolver {
  /// Creates a resolver. Every collaborator is injectable for tests.
  ///
  /// [installFingerprint] defaults to the shared machine fingerprint for
  /// [environment]: read from the suite's shared file, or, when there is none
  /// yet, adopted from the per-product file earlier SimCrux releases wrote
  /// (so a machine file issued for that value keeps resolving), or minted.
  HeadlessLicenseTierResolver({
    LicenseValidator? validator,
    Map<String, String>? environment,
    PolicyLoadResult Function()? loadPolicy,
    Future<String> Function(String path)? readFile,
    DateTime Function()? clock,
    Future<String?> Function()? installFingerprint,
    this.grace = LicenseGracePolicy.standard,
  }) : _validator =
           validator ??
           CruxLicenseValidator.production(product: CruxProduct.simCrux),
       _environment = environment,
       _loadPolicy = loadPolicy ?? const PolicyLoader().load,
       _readFile = readFile ?? _defaultReadFile,
       _clock = clock ?? DateTime.now,
       _installFingerprint =
           installFingerprint ??
           (() =>
               SharedInstallFingerprint(environment: environment).readOrCreate(
                 legacy: [
                   InstallFingerprintFile.legacy(
                     'simcrux',
                     environment: environment,
                   ).read,
                 ],
               ));

  final LicenseValidator _validator;
  final Map<String, String>? _environment;
  final PolicyLoadResult Function() _loadPolicy;
  final Future<String> Function(String path) _readFile;
  final DateTime Function() _clock;
  final Future<String?> Function() _installFingerprint;

  /// Grace windows applied to an expired licence.
  final LicenseGracePolicy grace;

  static Future<String> _defaultReadFile(String path) =>
      File(path).readAsString();

  /// Resolves the tier, naming [licenseFilePath] as the explicit source when
  /// the user passed `--license-file`.
  Future<HeadlessLicenseResolution> resolve({String? licenseFilePath}) async {
    final flag = licenseFilePath?.trim();
    if (flag != null && flag.isNotEmpty) {
      return await _fromExplicitFile(
        flag,
        'license file $flag (--license-file)',
      );
    }

    final env =
        (_environment ?? Platform.environment)[kSimcruxLicenseFileEnvVar]
            ?.trim();
    if (env != null && env.isNotEmpty) {
      return await _fromExplicitFile(
        env,
        'license file $env ($kSimcruxLicenseFileEnvVar)',
      );
    }

    return await _fromPolicy();
  }

  Future<HeadlessLicenseResolution> _fromExplicitFile(
    String path,
    String label,
  ) async {
    final String credential;
    try {
      credential = await _readFile(path);
    } on Object catch (e) {
      throw HeadlessLicenseException('cannot read $label: $e');
    }
    if (credential.trim().isEmpty) {
      throw HeadlessLicenseException('$label is empty');
    }
    return await _validate(credential, label);
  }

  Future<HeadlessLicenseResolution> _fromPolicy() async {
    final PolicyLoadResult loaded;
    try {
      loaded = _loadPolicy();
    } on Object {
      // The loader is documented never to throw; an injected one that does
      // must not take the run down with it.
      return _openCore(const <String>[]);
    }
    if (loaded.wasRejected) {
      final note =
          'license: ignored the policy file ${loaded.sourcePath ?? ''} '
          '(${loaded.rejection!.name}: ${loaded.detail ?? ''}); '
          'running as Open Core.';
      return _openCore(<String>[note]);
    }
    final license = DayOnePolicy.of(loaded.document).license;
    if (license == null) return _openCore(const <String>[]);

    final label = switch (license.kind) {
      PolicyLicenseKind.inline => 'the license in the policy file',
      PolicyLicenseKind.file => 'license file ${license.value} (policy file)',
    };
    final String credential;
    switch (license.kind) {
      case PolicyLicenseKind.inline:
        credential = license.value;
      case PolicyLicenseKind.file:
        try {
          credential = await _readFile(license.value);
        } on Object catch (e) {
          // An organization share that is unreachable from this agent is not
          // the user's typo, so it degrades rather than failing the run.
          return _openCore(<String>[
            'license: cannot read $label ($e); running as Open Core.',
          ]);
        }
    }
    return await _validate(credential, label);
  }

  Future<HeadlessLicenseResolution> _validate(
    String credential,
    String label,
  ) async {
    final now = _clock();
    final validation = await _validator.validate(
      credential,
      now: now,
      fingerprint: await _fingerprintFor(credential),
    );
    switch (validation) {
      case LicenseAccepted(:final grant):
        return _resolved(grant.tier, <String>[
          'license: ${_tierName(grant.tier)} from $label.',
        ]);
      case LicenseExpired(:final grant):
        final expiry = grant.expiry;
        if (expiry != null &&
            grace.covers(expiry: expiry, tier: grant.tier, now: now)) {
          final ends = grace.endsAfter(expiry, grant.tier);
          final note =
              'license: ${_tierName(grant.tier)} from $label expired on '
              '${_date(expiry)}; its grace period ends on ${_date(ends)}.';
          return _resolved(grant.tier, <String>[note]);
        }
        final on = expiry == null ? '' : ' on ${_date(expiry)}';
        final note =
            'license: $label expired$on and is past its grace period; '
            'running as Open Core.';
        return _openCore(<String>[note]);
      case LicenseRejected(:final reason, :final detail):
        final why = detail.isEmpty ? reason.name : '${reason.name}: $detail';
        return _openCore(<String>[
          'license: $label was not accepted ($why); running as Open Core.',
        ]);
      case LicenseAbsent():
        return _openCore(<String>[
          'license: $label holds no credential; running as Open Core.',
        ]);
    }
  }

  /// This machine's fingerprint when [credential] is a machine file, else
  /// `null`.
  ///
  /// Only a machine file names a machine, so only a machine file asks which
  /// machine this is, and a run licensed by a key or a licence file never
  /// creates the fingerprint file. A fingerprint that cannot be had is `null`,
  /// which the validator refuses as the wrong machine: failing closed.
  Future<String?> _fingerprintFor(String credential) async {
    final kind = parseLicenseCredential(credential).envelope?.kind;
    if (kind != LicenseCredentialKind.machineFile) return null;
    try {
      return await _installFingerprint();
    } on Object {
      return null;
    }
  }

  HeadlessLicenseResolution _openCore(List<String> notes) =>
      _resolved(LicenseTier.openCore, notes);

  HeadlessLicenseResolution _resolved(LicenseTier tier, List<String> notes) =>
      HeadlessLicenseResolution(
        tier: applyLicenseTierOverride(tier),
        notes: List<String>.unmodifiable(notes),
      );

  static String _tierName(LicenseTier tier) => switch (tier) {
    LicenseTier.openCore => 'Open Core',
    LicenseTier.edu => 'EDU',
    LicenseTier.pro => 'Pro',
    LicenseTier.enterprise => 'Enterprise',
  };

  static String _date(DateTime at) =>
      at.toUtc().toIso8601String().substring(0, 10);
}

/// The resolver the desktop app's `--ci` path uses. Overridden in tests.
///
/// `package:riverpod` rather than `flutter_riverpod`, so this file stays in
/// the headless CLI's Flutter-free import closure.
final Provider<HeadlessLicenseTierResolver>
headlessLicenseTierResolverProvider = Provider<HeadlessLicenseTierResolver>(
  (_) => HeadlessLicenseTierResolver(),
);
