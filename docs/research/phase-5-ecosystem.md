# Phase 5 Pre-work: Ecosystem

Scope: configuration import and export, backup and restore, stable internal extension interfaces, and a restricted extension model. This is design input; nothing here is built in Phase 1, but Phase 1 persistence should already follow the schema rules below so Phase 5 is a migration, not a rewrite.

## 1. Configuration schema

### Principles

- **One versioned document format** for everything the user configures. Live audio state is never exported.
- **Portable vs machine-specific is explicit in the schema**, not inferred at import time.
- **Never silently remap.** A reference that does not resolve becomes an unresolved reference the user can map, skip, or keep for later.
- **Unknown fields survive round trips.** Newer files opened by older builds keep data they do not understand.

### Envelope

```json
{
  "format": "com.pyrate.sounds.config",
  "schemaVersion": 3,
  "createdBy": { "app": "Pyrate Sounds", "version": "1.4.0", "build": "212" },
  "createdAt": "2026-10-13T18:20:00Z",
  "origin": { "machineID": "a3f1…", "macOS": "15.6" },
  "sections": {
    "interface": { },
    "applications": { },
    "devices": { },
    "eqPresets": [ ],
    "profiles": [ ],
    "rules": [ ],
    "shortcuts": { }
  },
  "extensions": { }
}
```

- `machineID` is a random UUID generated per install, not a hardware identifier. It only tells the importer "this came from a different Mac".
- `sections` are independently optional, so exporting just EQ presets or just one profile uses the same format.
- `extensions` is a namespaced bag (`"com.example.thing": {…}`) for future extension data, preserved verbatim.

### References

Every pointer to an app or device is a reference object, never a bare string:

```json
{ "kind": "app", "bundleID": "com.spotify.client", "displayName": "Spotify" }
{ "kind": "device", "uid": "BuiltInSpeakerDevice", "displayName": "MacBook Pro Speakers",
  "transport": "builtIn", "modelUID": "…", "portability": "machine" }
{ "kind": "deviceClass", "transport": "bluetooth", "nameHint": "AirPods Pro" }
```

- **Apps**: bundle ID is portable across Macs. Path-identified apps (no bundle ID) are marked `portability: "machine"`.
- **Devices**: Core Audio UIDs are stable on one Mac but not guaranteed across Macs (Bluetooth UIDs embed the MAC address and do match for the same headphones; USB UIDs can embed port location). Store UID plus `modelUID`, transport, and display name so the importer can **suggest** a match.
- `deviceClass` references let profiles say "any Bluetooth headphones" or "built-in speakers" portably. Prefer these in shared presets.

### Versioning and migration

- `schemaVersion` is a single integer for the whole document. Bump on any breaking change.
- Migrations are pure functions `vN -> vN+1` over a JSON tree, chained at load time, each with a fixture test (`Tests/Fixtures/config-vN.json`).
- Loading never writes back automatically. The migrated document is saved only after the app successfully applies it, and the pre-migration file is kept as `config.vN.bak`.
- Files newer than the running build: open read-only, warn, preserve unknown fields, refuse to save over them unless the user confirms a downgrade.

### Validation

Validate in three stages and report all problems at once:

1. **Structural**: format string, schema version range, JSON types. Failure rejects the file.
2. **Semantic**: value ranges (volume 0...1, EQ gain within limits, Q > 0), unique IDs, rules referencing profiles that exist in the same file. Failure rejects the affected item, keeps the rest.
3. **Environmental**: references resolved against this Mac. Failure never rejects; it produces unresolved references.

Imported values are clamped, not trusted. EQ gain over the safe limit is clamped and reported, so a malicious or broken preset cannot blast the user's ears.

### Import flow (remap prompts, not silent remap)

1. Parse and validate; show a summary: "3 profiles, 5 EQ presets, 2 rules. 2 devices and 1 app are not on this Mac."
2. For each unresolved device: offer **Map to…** (pre-select a suggestion only if transport and model match), **Keep for later** (stored as unresolved, applied automatically if that UID appears), or **Skip**.
3. Name collisions: **Replace**, **Keep both** (suffix " 2"), or **Skip**, per item or for all.
4. Apply atomically: either the whole accepted import lands, or nothing changes.
5. Log one history entry: "Imported 3 profiles from file X (2 references unresolved)."

## 2. Backup and restore

- **Automatic local snapshots**: write `Application Support/Pyrate Sounds/Backups/config-<timestamp>.json` before migrations, imports, and profile deletions. Keep the last 10 plus one per week for 4 weeks.
- **Manual export**: "Export Configuration…" writes the full envelope. Optional "Include machine-specific device mappings" (on by default for backups, off by default for sharing).
- **Restore**: pick a snapshot, see a diff summary (what will change), apply atomically. Restoring is itself snapshotted first, so it can be undone.
- **Reinstall**: if Application Support survives, nothing to do. Otherwise import the exported file. iCloud sync is out of scope until the format has been stable for a release cycle.
- Backups contain app names and device names, so they are user data: never uploaded, and the export panel says what is included.

## 3. Stable internal extension interfaces

Built-in features must use these first. They are internal Swift protocols, not a public SDK, until several genuinely different features have proven them.

```swift
/// Supplies audio sources (apps, shared processes, future: virtual sources).
protocol SourceProvider: AnyObject {
    var id: ProviderID { get }
    /// Async stream of full snapshots; consumers diff by SourceID.
    func sources() -> AsyncStream<[SourceSnapshot]>
    func capabilities(of source: SourceID) -> SourceCapabilities
}

/// Supplies devices and performs device-level operations.
protocol DeviceProvider: AnyObject {
    var id: ProviderID { get }
    func devices() -> AsyncStream<[DeviceSnapshot]>
    func capabilities(of device: DeviceID) -> DeviceCapabilities
    func perform(_ op: DeviceOperation) async -> OperationResult
}

/// A realtime processing stage. Built-in only (see section 5).
protocol ProcessingStage: AnyObject {
    static var kind: StageKind { get }
    /// Called off the realtime thread. Allocate everything here.
    func prepare(format: StreamFormat, maxFrames: Int) throws
    /// Called on the realtime thread. No locks, no allocation, no ObjC/Swift runtime calls.
    func process(_ buffer: UnsafeMutableAudioBufferListPointer, frames: Int)
    /// Parameters published through a lock-free parameter block.
    var parameters: ParameterBlock { get }
    var latencyFrames: Int { get }
}

/// An automation action. Non-realtime, main-actor or background.
protocol AutomationAction {
    static var kind: ActionKind { get }
    var summary: String { get }               // human readable for rule list and history
    func validate(in env: Environment) -> [ValidationIssue]
    func perform(in env: Environment) async -> ActionOutcome  // includes undo token if reversible
}
```

Rules for these interfaces:

- **Snapshots in, operations out.** Providers emit immutable snapshots; changes go through the operation model (requested, pending, confirmed, failed) shared with Phase 1.
- **Capabilities are mandatory.** Anything a provider supplies must declare capabilities; the UI renders nothing it cannot back.
- **Identity is stable and provider-scoped.** `SourceID` and `DeviceID` include the provider ID so two providers never collide.
- **Serializable configuration.** Every stage and action has a `Codable` configuration with its own version, stored inside the schema above.

Validation targets before freezing: per-app tap sources and a global-mix source (two `SourceProvider`s); built-in EQ and limiter (two `ProcessingStage`s); set-volume, activate-profile, and notify (three `AutomationAction`s).

## 4. Restricted non-realtime extension model

When the interfaces have held for a release, open a narrow door:

- **What extensions may do**: add `AutomationAction`s and triggers, add read-only panels (diagnostics, integrations), import/export converters, and contribute EQ presets as data.
- **How they run**: out of process. Preferred: a declarative extension (JSON/data-only presets and rule templates) needing no code. For code, use an XPC service or a separate helper with a narrow message protocol, so a crash or hang cannot touch the audio engine or the UI.
- **What they never get**: direct Core Audio access, the realtime thread, tap creation, or the user's full configuration. They see a scoped `Environment` with the operations they declared.
- **Trust**: declared permissions in a manifest, shown to the user at install; every action an extension performs is attributed in the history ("Rule from Extension X lowered Music to 20%").
- **Timeouts**: actions have a deadline; a misbehaving extension is disabled and reported, never retried in a loop.

## 5. Why third-party realtime DSP is deferred

- **Realtime safety cannot be enforced** on arbitrary code in-process. One allocation, lock, or log call in `process` causes dropouts for every tapped app.
- **Isolation costs latency.** Running DSP out of process means an extra IPC hop per buffer on the audio thread, which is exactly the latency and glitch risk we are trying to avoid. Audio Unit v3 extensions solve this with Apple's hosting; hosting AUv3 is the realistic future path, not a custom plugin ABI.
- **Security and trust**: a DSP plugin sees the audio content of every tapped app. That breaks the privacy promise unless sandboxed and clearly disclosed.
- **Signing and notarization**: loading third-party code requires disabling library validation under the hardened runtime (`com.apple.security.cs.disable-library-validation`), which weakens the whole app.
- **Support burden**: crashes and glitches would be blamed on Pyrate Sounds.

Revisit when: the built-in `ProcessingStage` chain is stable, latency is measured, and AUv3 hosting has been prototyped (`AVAudioUnitComponentManager` discovery, out-of-process instantiation). AUv3 hosting would satisfy "third-party processing" without inventing an unsafe ABI.

## 6. Phase 1 implications

- Store preferences as versioned JSON with an envelope and `schemaVersion` now.
- Key app preferences by bundle ID (or path with `portability: "machine"`) and device preferences by UID plus display name and transport.
- Keep live state out of the persisted document.
- Write the first migration test fixture when Phase 1 persistence lands.
