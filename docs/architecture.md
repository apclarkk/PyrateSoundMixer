# Architecture (Phase 1)

## Layers

| Layer | Module | Responsibility |
|---|---|---|
| Presentation | `PyrateSounds` | Menu bar panel, settings window. Views express intent by calling `AppStore` methods and never touch Core Audio. |
| Domain and state | `PyrateCore` + `AppStore` | Stable identities, capability model, volume and mute state, requested vs confirmed values, row stabilization, preferences. |
| Audio services | `PyrateAudio` | Device enumeration and control, process discovery, tap engines. |
| macOS | Core Audio | Process objects, process taps, private aggregate devices. |

## Key decisions

**Identity.** Sources are keyed by `SourceID` (the outermost app bundle's identifier, so Chrome's helper processes count as Chrome). Devices are keyed by `DeviceID` (the Core Audio UID), never by name. The system WebKit GPU process is one shared source labeled "Safari and WebKit apps", because controlling it affects every WebKit app.

**Per-app volume.** `TapEngine` creates a private process tap with `mutedWhenTapped`, a private aggregate device whose main subdevice is the destination output, and an IOProc that copies the tap to the device's preferred stereo pair with a ramped gain. If the app quits or crashes, the tap goes away and apps play normally again. Taps are engaged only for sources not at 100% and unmuted; returning to unity lingers 3 seconds before teardown. An engine stays alive while the app's processes exist, even when idle, so a muted app never blips at full volume when it resumes. The cost is some background IO for adjusted apps.

**Realtime safety.** The IOProc does no allocation, locking, or Objective-C messaging. Gain and peak are shared through aligned 32-bit floats (`RenderControls`).

**Requested vs confirmed.** `TrackedValue` holds the confirmed system value and any in-flight request. Output switching shows the requested device with a spinner, confirms when Core Audio reports the change, and reverts with an explanation after 6 seconds otherwise.

**Discovery vs presentation.** `ProcessMonitor` reports what exists, event driven through property listeners. `SourceListStabilizer` decides what to show: new rows append, vanished rows linger 4 seconds, and the row being dragged is never removed. Pinned apps are shown even when idle so their level can be set ahead of time.

**State categories.** Live state (`DeviceVolume`, discovered sources), session state (`sessionVolumes`), and durable preferences (`Preferences`, versioned JSON, lenient decoding, corrupt files moved aside) are separate. Precedence for an app's level: manual change this session, then remembered preference, then 100%.

**Capabilities.** `SourceCapabilities` and `DeviceCapabilities` decide which controls are enabled, and every unavailable reason carries an explanation shown in the UI (fixed-level devices, missing mute, unsupported OS, tap failures).

**Background cost.** Meters run at 15 Hz only while the panel is open. Nothing polls.

## Per-source processing (Phase 2)

Every tapped source owns a `ProcessingChain`: loudness makeup, a 10-band graphic EQ (RBJ peaking biquads at ISO octave centers, Q 1.41, plus or minus 12 dB, double precision), the cross-app leveler, the volume ramp, then a lookahead peak limiter. Nothing is shared between sources, so one app's EQ never affects another. An active EQ is a second reason to tap a source, alongside non-unity volume or mute.

- **Thread handoff.** Coefficients are computed on the main thread (`EQDesign`) and published through a lock-free triple buffer in the `PyrateAtomics` C target; gain and peak use C11 atomic floats. The IO thread never locks or allocates.
- **Click-free changes.** When a new coefficient set arrives, the IO thread runs the old and new filters side by side for one buffer and crossfades between them.
- **Loudness matching.** With "Match loudness" on (default), the EQ's change in perceived loudness is cancelled: a weighted power average of the curve (each octave equal, 200 Hz to 6 kHz weighted fully, easing to 0.25 at the extremes), clamped to plus or minus 12 dB.
- **Lookahead limiter.** Ceiling -1 dBFS, 5 ms lookahead, 120 ms release, stereo linked. Required gain per sample, then a sliding-window minimum over the lookahead (monotonic deque), then a box average of the same length, so gain reaches each peak's value exactly as the peak leaves the delay line. No overshoot and no gain jumps inside a waveform; an overloaded 60 Hz tone measures third harmonic below -40 dB. Adds a constant 5 ms latency to tapped sources only. The ceiling only applies while EQ or leveling is active; otherwise it sits at full scale.
- **Cross-app normalizer.** Off by default. Measures each playing source the BS.1770 integrated way: K-weighted 400 ms blocks every 100 ms over a sliding 30 s window, ignoring blocks below -70 LUFS and more than 10 LU under the average, so silence and quiet passages don't count. Holds until 3 s of real audio has been heard. If the trim is more than 2 dB from where it should be, it moves toward the target (-18, -14 default, or -11 LUFS) at 1 dB/s (3 dB/s in the first 10 s), capped at plus or minus 6 dB, then stops; an optional boost-only mode never cuts. Measured before the trim (open loop). A source's settled trim is remembered for the session and seeds its next engine. Only playing sources are tapped for normalizing; engines linger 8 s after they stop.
- **Sample rate.** Coefficients follow the aggregate device's nominal rate and are recomputed when it changes.
- **Presets.** 16 read-only built-ins (R&B matches SoundSource's band values) plus user presets in `preferences.json`. Deleting a preset keeps each app's curve and only drops the name. EQ is always remembered per app, independent of the "remember volumes" setting.

## Phase 2 to 5 additions

**Inputs and microphone use.** Input devices are enumerated and switched like outputs, with gain and mute where the device supports them. "In use by" comes from `kAudioProcessPropertyIsRunningInput`, which is process metadata: no audio is read and no microphone permission is needed. Apps that choose their own microphone are unaffected by the system input.

**Shortcuts.** Carbon `RegisterEventHotKey` (no accessibility permission). Bindings need Command, Option, or Control, common system combinations are refused, duplicates are caught, and a combination another app owns is reported as such.

**Profiles.** A profile captures only the aspects it includes (app volumes, app EQ, output, input), so profiles layer. Activation records what it replaced (`ProfileUndo`) for one-step undo. A missing device is skipped with an explanation.

**Rules** (`RuleEngine`, pure and unit tested). Triggers are conditions (app playing, app using the microphone, device connected, output is a device). Actions on start; volume, mute, and EQ changes can revert when the condition ends. Priority is list order: the highest active claimant of a setting wins, hand-over goes to the next claimant, and the pre-rule value returns when none remain. A manual change releases the setting until a claiming rule newly activates. "Playing" uses the stabilized row list, so a gap between tracks doesn't end a rule. Rule changes never overwrite remembered volumes.

**Activity.** Local JSON, 7 days or 500 entries, metadata only (app names, levels, devices). Every change carries an origin (user, profile, rule, device, failure).

**Routing.** A per-app route points the app's tap engine at another device's aggregate. `RouteResolution` decides: follow the system, routed, or fallback when the chosen device is missing (shown in the row and the routing window, restored automatically when the device returns). Routing to the device that is already the system output needs no tap.

**Effects.** Channel mode (stereo, swap, mono) and level-neutral balance run after EQ in the same per-source chain, ramped per buffer.

**Apple effects rack.** Up to 6 of macOS's built-in Audio Units per source (reverb, room reverb, echo, distortion, pitch shift, compressor, multiband compressor, low-, high-, and band-pass filters, walkie-talkie beep), found at run time by subtype with manufacturer Apple; a missing unit is skipped and reported. The chain runs in three passes per chunk of up to 4096 frames: per-sample EQ, channel mode, and balance into scratch buffers; the rack in place via `AudioUnitRender` with a pull callback that copies from scratch (no allocation on the IO thread); then per-sample gains and the lookahead limiter, whose ceiling is on whenever a rack is present so reverb and echo build-up can't clip. Parameter and bypass changes go to the running units (`AudioUnitSetParameter` is safe while rendering); adding, removing, reordering, or changing a preset builds a new `EffectRack` on the main thread and swaps it in through an atomic pointer, and the old rack is released a second later, well after any render that saw it. `AppleEffectLibrary` reads parameter ranges, units, factory presets, and each preset's values for the UI, cached. Only Apple's units are loaded; third-party Audio Units remain out of scope (see `extensions.md`).

**Routing workspace.** A window drawing each app to its actual destination, marking processed versus native paths and fallbacks; clicking an app re-routes it.

**Import, export, backups.** `ConfigurationBundle` is versioned (`format`, `version`); foreign, damaged, and newer files are refused with a reason. An import shows counts and missing devices first; devices are only remapped when the user picks a replacement. Replace or merge (merge adds presets, profiles, rules, and unknown apps without touching device choices). A backup is written before every import or restore; 15 are kept. Profiles export alone with the custom presets they use.

**Commands and integrations.** `PyrateCommand` is the single command set that integrations go through; `pyratesounds://` URLs parse into it (off by default, every command logged). See `extensions.md`.

## Known limitations and open questions

- There is no public API to query audio capture permission. If permission is denied, taps deliver silence; the panel warns when an adjusted app reports playing but its tap stays silent for 4 seconds. This needs confirmation on a machine where permission was denied.
- Apps that pick their own output device have not been tested with taps yet (see `research/phase-4-advanced-audio.md`).
- Rule-applied EQ is saved like any EQ change; if Pyrate Sounds quits mid-rule, that EQ stays until changed.
- Changing channel mode switches instantly and can click; balance and every level change are ramped.
- Bypassing a rack effect stops it immediately, so a reverb or echo tail is cut rather than faded.
- Rack effects add their own latency (pitch shift most); Diagnostics shows each source's total.
- Loudness normalizing (`LevelingSettings`, the normalizer in `ProcessingChain`) has no UI and is always off; the code is kept dormant in case it returns.
- When an app gains a new helper process, its tap is rebuilt, which can cause a brief glitch.
