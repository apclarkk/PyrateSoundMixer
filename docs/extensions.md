# Extending Pyrate Sounds

## The supported seam today: commands

Everything an outside trigger can do goes through `PyrateCommand` (`Sources/PyrateCore/Commands.swift`). The `pyratesounds://` URL scheme parses into it, and new integrations (an AppleScript dictionary, App Intents for the Shortcuts app, a CLI) should parse into the same type instead of calling the store directly. That keeps one set of behaviors, one place for validation, and one entry in Activity per command.

| URL | Command |
|---|---|
| `pyratesounds://profile/<name>` | Activate a profile |
| `pyratesounds://volume/<app>?level=0-100` | Set an app's volume |
| `pyratesounds://volume/<app>?change=-100-100` | Change an app's volume |
| `pyratesounds://mute/<app>`, `unmute/<app>`, `toggle-mute/<app>` | Mute control |
| `pyratesounds://output?level=0-100` | Output volume |
| `pyratesounds://output/mute` | Toggle output mute |
| `pyratesounds://output/select/<device>` | Switch output |
| `pyratesounds://eq/<app>?preset=<name>` | Apply an EQ preset |
| `pyratesounds://undo-profile` | Undo the last profile |

Apps match by name or bundle ID, devices and profiles by name, case-insensitively. URL commands are off until enabled in Settings > Integrations.

## Internal interfaces new features should use

- **Sources and devices:** `ProcessMonitor` (discovery), `DeviceControl` and `DeviceMonitor` (devices), identified by `SourceID` and `DeviceID`, never names.
- **Processing:** one `ProcessingChain` per tapped source. A new stage needs a main-thread setter that publishes through an atomic or the triple buffer, and a branch in `process` that does no allocation, locking, or Objective-C messaging. Add a "needs tap" reason in `TapCoordinator.Request.needsTap`.
- **Automation:** add a `RuleTrigger` (with `Facts.satisfies`) or a `RuleAction` (with its `setting` if it is revertible) and the engine's priority, hand-over, and manual-override behavior comes for free.
- **Persistence:** add optional fields with `decodeIfPresent` so older files keep loading; bump `ConfigurationBundle.currentVersion` only for breaking changes, with a migration.

## Apple's Audio Units

The effects rack loads only Audio Units whose manufacturer is Apple, from the set listed in `AppleEffectCatalog`. They ship with macOS, run in-process, and are built for real-time use. Adding another Apple unit means adding a catalog entry (key parameters and a starting point); the generic parameter UI covers the rest.

## Deferred: third-party extensions

Third-party audio processing is intentionally not supported yet. Code in the real-time path must never block or allocate, which can't be enforced on outside code; any plug-in would hear every processed app; and loading it would mean relaxing library validation. The likely path is hosting AUv3 audio units out of process. Non-real-time extensions (new commands or triggers) can come first through the interfaces above.
