// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
// The Flutter-free barrel only: this file sits inside the headless CLI's
// import closure, which `dart build cli` links without `dart:ui`.
import 'package:crux_license/crux_license_core.dart';

/// A `simcrux license` invocation the parser cannot interpret, with the
/// usage block so the caller can print both.
class LicenseCliException implements Exception {
  /// Creates the exception.
  const LicenseCliException(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'simcrux license: $message\n\n${LicenseCli.usage}';
}

/// `simcrux license fingerprint` and `simcrux license request --out <file>`.
///
/// A machine file licenses a headless run on the install it was issued for,
/// and the install is named by the suite's shared fingerprint. The desktop
/// app publishes that fingerprint from its credential store, and `--ci` mints
/// one if no product has run; until now nothing printed it, so on a dedicated
/// build agent where the desktop app never runs there was no way to learn the
/// value a machine file had to be issued for. These two sub-commands close
/// that: the first prints the fingerprint, the second writes the offline
/// activation request the desktop app's License panel would export, from the
/// same shared file, with no credential store and no network.
///
/// A licence key or a licence file names no machine and needs neither.
class LicenseCli {
  /// Creates the sub-command handler.
  ///
  /// [environment] locates the shared fingerprint file and the per-product
  /// one earlier releases wrote; it defaults to the process environment, and
  /// a test points it at a temporary directory. [machineName] and [platform]
  /// label the request for a human matching it to a desk; they default to
  /// the host name and the operating system.
  LicenseCli({
    this._environment,
    String Function()? machineName,
    String? platform,
  }) : _machineName = machineName ?? _hostName,
       _platform = platform ?? Platform.operatingSystem;

  /// The `fingerprint` verb.
  static const String kFingerprint = 'fingerprint';

  /// The `request` verb.
  static const String kRequest = 'request';

  /// The `request` verb's output option.
  static const String kOutOption = 'out';

  /// The document kind the request carries, the one the desktop app's
  /// License panel exports and the issuer's tooling reads.
  static const String kRequestKind = 'crux.offline-activation-request/v1';

  /// Usage block for `simcrux license --help` and every usage error.
  static const String usage = '''
Usage: simcrux license <command>

Commands:
  fingerprint              Print this install's machine fingerprint, the value
                           a machine file is issued for. Minted and recorded on
                           first use if no EDACrux product has run here yet.
  request --out <file>     Write an offline activation request for this install
                           to <file>, as the desktop app's License panel would.

The fingerprint is read from the suite's shared file, which every EDACrux
product on this account shares, so a suite licence counts this computer once.
No credential store and no network are used.''';

  final Map<String, String>? _environment;
  final String Function() _machineName;
  final String _platform;

  /// Runs [args], the words after `license`, writing output lines through
  /// [stdoutWriter]. Throws [LicenseCliException] on a usage error and
  /// [FileSystemException] when the request file cannot be written.
  Future<void> run(
    List<String> args, {
    required void Function(String line) stdoutWriter,
  }) async {
    if (args.isEmpty) {
      throw const LicenseCliException('expected a command');
    }
    switch (args.first) {
      case '-h' || '--help':
        stdoutWriter(usage);
      case kFingerprint:
        if (args.length > 1) {
          throw LicenseCliException(
            'unexpected argument `${args[1]}` after `$kFingerprint`',
          );
        }
        stdoutWriter(await fingerprint());
      case kRequest:
        final out = _parseRequestOut(args.skip(1).toList());
        final request = requestDocument(await fingerprint());
        await File(out).writeAsString('$request\n');
        stdoutWriter('simcrux: wrote $out');
      default:
        throw LicenseCliException('unknown command `${args.first}`');
    }
  }

  /// This install's machine fingerprint: the suite's shared file, else the
  /// value an earlier SimCrux release kept in its own file, adopted into the
  /// shared one, else a fresh one, minted and recorded. The same resolution
  /// `--ci` applies when it validates a machine file.
  Future<String> fingerprint() async {
    final value =
        await SharedInstallFingerprint(
          environment: _environment,
        ).readOrCreate(
          legacy: [
            InstallFingerprintFile.legacy(
              'simcrux',
              environment: _environment,
            ).read,
          ],
        );
    if (value == null) {
      throw const LicenseCliException(
        'the install fingerprint could not be read or recorded: the suite '
        'data directory is not writable by this user',
      );
    }
    return value;
  }

  /// The offline activation request for [fingerprint]: the product asking,
  /// the fingerprint a seat would be counted against, and a label a human
  /// can match to a machine. It carries no secret, so it can travel on a USB
  /// stick or in an email, and it is the document the desktop app's License
  /// panel exports.
  String requestDocument(String fingerprint) =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'kind': kRequestKind,
        'product': CruxProduct.simCrux.entitlementCode,
        'fingerprint': fingerprint,
        'machine': _machineName(),
        'platform': _platform,
      });

  static String _parseRequestOut(List<String> args) {
    final parser = ArgParser()
      ..addOption(kOutOption, help: 'The file to write the request to.');
    final ArgResults results;
    try {
      results = parser.parse(args);
    } on FormatException catch (e) {
      throw LicenseCliException(e.message);
    }
    final out = results.option(kOutOption);
    if (out == null || out.isEmpty) {
      throw const LicenseCliException('`$kRequest` needs --$kOutOption <file>');
    }
    if (results.rest.isNotEmpty) {
      throw LicenseCliException(
        'unexpected argument `${results.rest.first}` after `$kRequest`',
      );
    }
    return out;
  }

  static String _hostName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty) return host;
    } on Object {
      // Sandboxed and restricted environments refuse the hostname lookup.
    }
    return Platform.operatingSystem;
  }
}
