# SimCrux Driver Plugin ABI — protocol contract

> **Current version:** `1`
> **Wire format(s) supported at this version:** `json-lines`

This document is the **canonical contract** between SimCrux and any
process implementing a custom simulator driver plugin (a SimCrux Pro
feature — see
[Custom driver plugins](https://docs.simcrux.app/projects-and-simulators#plugins)).
Plugin authors target this contract; the SimCrux host validates against
it at runtime via the `abiVersion` field on every `manifest.yaml`.

The Dart-side definitions backing this contract live in:

- `simcrux/lib/domain/enums/driver_capability.dart`
- `simcrux/lib/domain/enums/driver_stdio_protocol.dart`
- `simcrux/lib/domain/models/simulator_driver_plugin_manifest.dart`
- `simcrux/lib/services/driver_plugin/driver_wire_protocol.dart`
- `simcrux/lib/domain/interfaces/simulator_driver_plugin_registry.dart`

The host side of this contract (process spawning, the handshake, the
translation of a test into `compile` / `run` requests) ships with SimCrux
Pro; this repository carries the wire vocabulary and the `spec` encoder
(`simcrux/lib/services/driver_plugin/plugin_test_spec_codec.dart`).

---

## Why subprocess isolation (and not `dart:ffi`)

Every plugin runs in its own OS subprocess. This is **non-negotiable
for two reasons:**

1. **License isolation.** Vendor-simulator wrappers may depend on
   proprietary libraries; community-contributed wrappers may bring in
   GPL'd code. Loading those in-process via `dart:ffi` would conflate
   the host's licensing posture with the plugin's. Subprocess
   boundaries keep licensing concerns cleanly separated.
2. **Crash isolation.** A driver subprocess that segfaults, hangs, or
   leaks does not take SimCrux down with it. The host surfaces a
   `PluginCrashed` / `PluginUnresponsive` event in the plugin events
   log and fails just the in-flight request; the user keeps working.

If you find yourself wanting to "embed the simulator directly for
performance," stop. The wire-protocol overhead is on the order of
nanoseconds per envelope; the runtime cost of any real simulation
dwarfs it. The isolation benefits are not negotiable.

---

## Versioning policy

### Major version (`abiVersion` integer)

The ABI version is a single integer (`1`, `2`, `3`, …). Plugins
declare their target version in `manifest.yaml`; the SimCrux host
rejects manifests whose declared version does not match
`kSimcruxDriverPluginAbiVersion` (the build's constant).

**Major-version bumps signal breaking changes.** Examples:

- A new required field in `manifest.yaml` whose absence the loader
  treats as malformed.
- A change to the meaning of an existing wire-protocol envelope
  field (e.g. switching `requestId` from `int` to `string`).
- Removal of an existing envelope kind, capability value, or stdio
  protocol.
- Adding a required handshake step.

**Deprecation policy for the first major bump.** Only ABI `1` exists,
so today a host accepts exactly `1` and rejects any other declared
version at discovery. When ABI `2` is cut, the policy that ships with it
is: both versions are supported in parallel for one full SimCrux release
cycle; the loader logs a one-time deprecation warning per launch for a
plugin targeting the older version but still loads it; after that cycle,
support for the older version is removed and such plugins are rejected.
The window will be announced in the release notes of the version that
introduces the new ABI, in the plugin events log, and on the plugin's row
in **Settings > Custom Driver Plugins**.

### Minor / patch versions (the plugin's own `version` field)

The plugin's own `version` (semver) is independent of the ABI
version. It describes plugin-internal changes — bug fixes, support
for new simulator releases, etc. The host displays it but does not
gate on it.

### Adding new capabilities, kinds, and stdio protocols

**Adding new values is a minor change**, not a major bump, as long as:

- Existing values keep their wire ids.
- Older hosts silently ignore unknown values (the v1 host already
  does this for unknown [DriverCapability] entries and unknown
  message kinds — see "Forward compatibility" below).

This means future ABI revisions can add new capabilities and new
optional message kinds without requiring plugin re-authoring. v1
plugins continue to work on v2 hosts; v2 plugins targeting only the
v1 capability set work on v1 hosts.

---

## v1 contract

### Manifest schema (`manifest.yaml`)

Required fields:

| Field | Type | Description |
|---|---|---|
| `pluginId` | string | Globally unique reverse-DNS identifier (e.g. `com.simcrux.example.verilator`). |
| `displayName` | string | User-facing label. |
| `description` | string | Short blurb describing the plugin. |
| `version` | semver string | Plugin's own version. |
| `licenseSpdx` | string | SPDX license id (e.g. `MIT`, `GPL-3.0-only`, `Proprietary`). |
| `supportedSimulators` | non-empty list of string | Simulator family names this plugin handles. |
| `abiVersion` | integer | Must equal `1` for the v1 contract. |
| `executablePath` | string | Subprocess binary path, relative to the install directory. |
| `stdioProtocol` | string | Must be `"json-lines"` at v1. |
| `minSimcruxVersion` | semver string | Advisory minimum host version. |
| `declaredCapabilities` | list of string | Each entry is a [DriverCapability] wire id. |

Optional fields:

| Field | Type | Description |
|---|---|---|
| `authorName` | string | Plugin author / maintainer. |
| `authorContact` | string | Email / URL for support. |
| `homepage` | string | Plugin homepage URL. |
| `repository` | string | Plugin source-repository URL. |

### Wire-protocol envelopes (JSONL)

Every line is a single UTF-8 JSON object terminated by `\n`. The
envelope shape is:

```jsonc
{
  "kind": "<wire id from DriverWireMessageKind>",
  "requestId": <int>,
  "payload": { ... }
}
```

**Host → driver requests:**

| Kind | When | Payload |
|---|---|---|
| `initialize` | Immediately after spawn | `{ "hostVersion": "<semver>", "hostAbiVersion": <int> }` |
| `compile` | Per-test compile pass | `{ "testId": "...", "simulatorId": "...", "workingDirectory": "...", "spec": { ... } }` |
| `run` | Per-test execution | `{ "testId": "...", "simulatorId": "...", "workingDirectory": "...", "spec": { ... }, "compileArtifactPath"?: "..." }` |
| `cancel` | Abort in-flight | `{ "targetRequestId": <int> }` |
| `shutdown` | Graceful exit | `{}` |
| `queryCapability` | Runtime probe — **reserved**: ABI 1 hosts never send it, but a driver should answer it | `{ "capability": "<wire id>" }` |

`hostVersion` is the SimCrux product version (for example `"1.0.0"`).
`workingDirectory` is the test's own scratch directory, allocated fresh for
each test; it is not the plugin's working directory (see Lifecycle).

**Driver → host responses:**

| Kind | When | Payload |
|---|---|---|
| `initialized` | After receiving `initialize` | `{ "abiVersion": <int>, "declaredCapabilities": [ ... ] }` |
| `compileProgress` | Optional during compile | Driver-defined (e.g. `{ "percent": 0.42 }`) |
| `compileComplete` | Terminal compile | `{ "success": <bool>, "artifactPath"?: "...", "failureMessage"?: "..." }` |
| `runProgress` | Optional during run | Driver-defined |
| `runComplete` | Terminal run | `{ "status": "pass"|"fail"|...,  "exitCode"?: <int>, "metrics": {...}, "failureMessage"?: "...", "waveformPath"?: "..." }` |
| `log` | Streamed stdout / stderr | `{ "line": "...", "fromStderr": <bool> }` |
| `error` | Driver-internal failure | `{ "message": "...", "code"?: "..." }` |
| `capabilityQueried` | After receiving `queryCapability` | `{ "capability": "<wire id>", "supported": <bool> }` |

`runComplete.status` is one of `pass`, `fail`, `timeout`, `skipped`
(`skip` is accepted) or `unknown`; anything else reads as `unknown`.

### The `spec` object

`compile` and `run` carry the test to build and run in `spec`. Every
field is always present; lists and maps may be empty and `seed` may be
`null`. Enum values use the spellings of `simcrux.yaml`.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Test id, `<suite>/<name>` plus any `+PARAM=value` / `+seed=N` suffix. Same as `testId`. |
| `name` | string | Test name as written in `simcrux.yaml`. |
| `suite` | string | Suite name. |
| `simulatorId` | string | The simulator id the test selected (`simulator:` in `simcrux.yaml`). |
| `top` | string | Top-level module or entity. |
| `sources` | list of string | Source files in order, resolved against the project directory. |
| `sourceLanguages` | map of string → string | Per-source language overrides (`verilog`, `system_verilog`, `vhdl`, `python`, `mixed`); a source absent from the map has no override. |
| `includeDirs` | list of string | Include directories. |
| `defines` | map of string → string | Preprocessor defines. |
| `parameters` | map of string → string | Parameter values, one value per key (a sweep has already been expanded into separate tests). |
| `seed` | int or `null` | The seed to run with; `null` means the test declared none. |
| `timeoutMs` | int | The test's timeout in milliseconds. SimCrux enforces it; the driver need not. |
| `waveform` | object | `{ "capture": "always"\|"on_failure"\|"on_demand"\|"never", "format": "vcd"\|"fst"\|"ghw" }`. |

The pass/fail detector, resource locks and sweep declarations stay on the
host: SimCrux classifies the run from the driver's `log` lines, exit code
and status. Adding a field to `spec` is an additive change; renaming or
removing one requires a major version.

The `requestId` on every response correlates back to the originating
request (e.g. `runComplete` echoes the `requestId` of the `run`
request it terminates). Driver-initiated envelopes that do not
correlate to a host request (rare) use `requestId: 0`.

### Lifecycle

1. **Spawn.** Host spawns the subprocess via `Process.start(executablePath, [])`.
   No shell. `executablePath` is resolved against, and the working
   directory is, the directory the plugin's `manifest.yaml` was found in —
   whatever that directory is called.
2. **Initialize.** Host writes one `initialize` request to the driver's
   stdin. Driver responds with `initialized` within the configurable
   handshake timeout (default 10 s). On timeout, host kills the
   subprocess and surfaces a `PluginCrashed` event.
3. **ABI check.** Host validates the `initialized` envelope's
   `abiVersion` matches `kSimcruxDriverPluginAbiVersion`. On mismatch,
   host shuts down the subprocess and surfaces a `PluginCrashed` event
   tagged with the mismatch reason.
4. **Steady state.** Host sends `compile` / `run` requests; driver
   replies with `log` envelopes followed by a terminal `compileComplete`
   or `runComplete`. Multiple requests may be in flight if the driver
   advertises the capability and uses distinct `requestId`s.
5. **Shutdown.** Host sends `shutdown`; driver flushes and exits zero.
   The host stops waiting as soon as every driver has gone, so a prompt
   exit is what keeps quitting SimCrux quick. If the driver does not
   exit within 5 s, host sends SIGTERM. After another 2 s, host sends
   SIGKILL.

### Forward compatibility

The host ignores, without failing the plugin:

- Unknown fields in any envelope payload.
- Unknown values in `declaredCapabilities` (the manifest parser
  silently skips them).
- Unknown envelope kinds and lines that are not valid envelopes. The
  decoder rejects them; the host writes a diagnostic to its stderr and
  moves on, before and after the handshake alike.
- Optional fields that are absent.

The driver should follow the same discipline for forward compatibility
with future SimCrux releases.

---

## See also

- [Custom driver plugins](https://docs.simcrux.app/projects-and-simulators#plugins)
  — installing and managing plugins in SimCrux.
