// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_linux_integration/crux_linux_integration.dart';

/// Open-core SimCrux's freedesktop identity, installed as a host `.desktop`
/// entry when the app runs from an AppImage.
///
/// [LinuxDesktopApp.appId] and [LinuxDesktopApp.execName] must equal
/// `APPLICATION_ID` and `BINARY_NAME` in `linux/CMakeLists.txt`: the GTK
/// runner sets the window's app id from the former, and a `.desktop` entry
/// whose `StartupWMClass` differs is not matched to the window. `bootstrap`
/// takes the identity as a parameter so the Pro overlay passes its own.
///
/// [LinuxDesktopApp.fileTypes] is the Linux half of the document types
/// `macos/Runner/Info.plist` registers — without it a file manager offers
/// SimCrux for nothing, which is the Linux shape of the same defect that had
/// a macOS double-click open an empty window. The two lists describe the same
/// five extensions; [kSimcruxLinuxFileTypes] says what each one is.
///
/// Not `const`, because a declared type is built rather than written down:
/// the constructor rejects a name the system already maps, which is a check
/// worth having at the cost of the keyword.
final LinuxDesktopApp kSimcruxLinuxDesktopApp = LinuxDesktopApp(
  appId: 'com.ferriteengineering.simcrux',
  name: 'SimCrux',
  comment: 'Simulation regression runner and dashboard for HDL testbenches',
  execName: 'simcrux',
  fileTypes: kSimcruxLinuxFileTypes,
);

/// The file kinds a SimCrux `.desktop` entry claims, one per extension the
/// macOS bundle registers.
///
/// A type of ours needs two halves on Linux, not one. A file manager types a
/// file before it looks for handlers, so a name in the entry reaches nothing
/// on its own: with nothing mapping `*.simcrux-workspace` the file is typed
/// as JSON and SimCrux is never offered, however completely the entry lists
/// the name. [LinuxMimeType.declared] supplies the other half — the glob, the
/// "Kind" text a file manager shows, and the parent type — and the integrator
/// installs it as a `shared-mime-info` package.
///
/// `.yaml` / `.yml` are named, never declared. Declaring them would replace
/// the description every YAML file on the machine shows, and a regression
/// manager has no business becoming the default application for all of them.
/// Named, SimCrux is offered *alongside* the user's editor — the Linux
/// counterpart of the `Alternate` handler rank the macOS bundle gives the
/// same two extensions. Both spellings are named because `application/x-yaml`
/// is the older one and `application/yaml` the registered one, and which a
/// file manager reports depends on how new its MIME database is.
///
/// The other three are ours to declare, and each subclasses the type macOS
/// says it conforms to, so a desktop that has never heard of ours still
/// treats the file as YAML or JSON: it opens in a text editor, is searched as
/// text, and shows a sensible icon. `.crux-project` is the EDACrux design
/// manifest, shared by every product in the suite, so all of them claim the
/// one suite type — `application/x-edacrux-project`, the name that matches
/// its macOS identifier `app.edacrux.project`. One file, one name.
final List<LinuxMimeType> kSimcruxLinuxFileTypes =
    List<LinuxMimeType>.unmodifiable(<LinuxMimeType>[
      const LinuxMimeType.registered('application/x-yaml'),
      const LinuxMimeType.registered('application/yaml'),
      LinuxMimeType.declared(
        name: 'application/x-edacrux-project',
        comment: 'EDACrux design manifest',
        extensions: const <String>['crux-project'],
        subClassOf: 'application/x-yaml',
      ),
      LinuxMimeType.declared(
        name: 'application/x-simcrux-session',
        comment: 'SimCrux session',
        extensions: const <String>['simcrux-session'],
        subClassOf: 'application/json',
      ),
      LinuxMimeType.declared(
        name: 'application/x-simcrux-workspace',
        comment: 'SimCrux workspace',
        extensions: const <String>['simcrux-workspace'],
        subClassOf: 'application/json',
      ),
    ]);

/// The extensions the YAML types account for, for
/// [checkLinuxMimeCoverage]'s `registeredExtensionsOf`.
///
/// A named type carries no extensions of its own — the system's glob decides
/// which files it covers — so the pairing guard is told which of the macOS
/// extensions these two stand for. Without it `.yaml` and `.yml` read as
/// extensions nothing on Linux maps.
const Map<String, List<String>> kSimcruxLinuxYamlExtensions =
    <String, List<String>>{
      'application/x-yaml': <String>['yaml', 'yml'],
    };
