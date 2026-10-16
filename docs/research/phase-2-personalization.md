# Phase 2 research: Personalization

Scope: equalizer and DSP, input devices, global shortcuts, layouts and ordering, diagnostics. This is pre-work; nothing here is implemented yet.

Verification legend:
- **[SDK]** checked against headers in `MacOSX.sdk` shipped with the installed Xcode (CoreAudio `AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`, Carbon `HIToolbox.tbd`).
- **[Unverified]** based on prior knowledge or reasoning; needs a spike before we rely on it.

## 0. API facts that shape everything below

| Fact | Status |
|---|---|
| `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` are macOS 14.2+ | [SDK] |
| `CATapDescription` initializers: `initStereoMixdownOfProcesses:`, `initStereoGlobalTapButExcludeProcesses:`, `initMonoGlobalTapButExcludeProcesses:`, `initWithProcesses:andDeviceUID:withStream:`, `initExcludingProcesses:andDeviceUID:withStream:` | [SDK] |
| `CATapMuteBehavior`: `CATapUnmuted`, `CATapMuted`, `CATapMutedWhenTapped` | [SDK] |
| `exclusive` property means "tap everything except `processes`" | [SDK] |
| `bundleIDs` and `processRestoreEnabled` (re-attach processes by bundle ID after relaunch) are macOS 26.0+ only | [SDK] |
| `kAudioTapPropertyFormat` returns the ASBD of the tap stream as seen inside an aggregate | [SDK] |
| `kAudioAggregateDeviceTapAutoStartKey` requires the aggregate to be private | [SDK] |
| `kAudioSubTapDriftCompensationKey` exists for sub-taps in the tap list | [SDK] |
| `kAudioProcessPropertyIsRunningInput` / `IsRunningOutput` / `Devices` (scoped input or output) exist | [SDK] |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` returns `kAudioObjectUnknown` (no error) for unknown PIDs | [SDK] |
| `kAudioDevicePropertyProcessMute` zeroes the calling process's own audio, physical devices only | [SDK] |
| `RegisterEventHotKey` is still exported by HIToolbox | [SDK, symbol in `.tbd`] |
| Tap creation triggers the "System Audio Recording" TCC prompt, keyed by `NSAudioCaptureUsageDescription` | [Unverified, matches Apple sample behavior] |

## 1. Equalizer

### 1.1 Where EQ lives

Phase 1's tap engine already gives us a signal path we own for every tapped app:

```
app process -> process tap (mutedWhenTapped) -> private aggregate -> IOProc [gain] -> output device
```

EQ slots into the IOProc between reading the tap buffer and writing the output buffer:

```
tap input -> pre-gain (headroom) -> EQ biquads -> app gain/mute ramp -> clip guard -> output
```

Gain sits after EQ so a quiet app does not starve the filters of precision, and the clip guard is last so it protects against the sum of everything upstream.

Two scopes, both legitimate:

- **Per-app EQ.** Free once the app is tapped. Cheap, precise, honest: it only affects that app. Requires the app to be tapped even at 100% volume, so "EQ active" becomes a second reason to engage a tap (Phase 1 engages lazily only for non-unity gain or mute; Phase 2 extends that predicate).
- **Per-device (system-wide) EQ.** What most users mean by "an equalizer". Needs a path that carries untapped audio too. See 1.6.

Recommendation: ship per-device EQ via a global tap as the headline feature, keep per-app EQ as an advanced option on the same DSP code. The data model treats an EQ chain as a value that can be attached to either a device UID or a source ID.

### 1.2 Filter design

Use RBJ Audio EQ Cookbook biquads (Direct Form II Transposed, `Float` state is fine for EQ in this range; use `Double` coefficients computation, `Float` processing).

- **Graphic EQ:** 10 peaking bands at ISO octave centers 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz. Fixed Q around 1.41 (one octave). Range plus or minus 12 dB. Low and high bands may optionally be shelves.
- **Parametric EQ:** up to 8 bands, each with type (peak, low shelf, high shelf, low cut, high cut), frequency 20 Hz to 20 kHz, gain plus or minus 18 dB, Q 0.1 to 10.
- Coefficients depend on sample rate. Recompute on `kAudioDevicePropertyNominalSampleRate` change of the output device (aggregate's main subdevice) and on tap format change.
- Frequency response curve for the UI: evaluate the product of each biquad's `H(e^jw)` at ~256 log-spaced points on the main thread. No FFT needed; this is exact and cheap. Accelerate (`vDSP_biquad`) is available [SDK] but our band count is small enough that a scalar loop per channel is simpler and allocation-free. `vDSP_biquadm` is worth a benchmark if we go past 8 bands across many taps [Unverified performance claim].

### 1.3 Realtime-safe parameter updates

The IOProc runs on a realtime thread: no locks, no allocation, no Swift runtime calls that may allocate (no class instance creation, no array appends, no `print`), no ObjC messaging.

Pattern:

1. Main thread computes a full `BiquadCoefficientSet` (fixed-size struct, e.g. 8 bands x 5 coefficients, plus `bandCount`, `preGain`, `bypass`).
2. Writes it into one slot of a preallocated triple buffer (`UnsafeMutablePointer<BiquadCoefficientSet>` of 3) and publishes the slot index with an atomic store (`Synchronization.Atomic` is macOS 15+; for a 14.4 floor use a tiny C shim with `stdatomic.h` or `OSAtomic`-free `atomic_store_explicit` in a C target).
3. The IOProc does an atomic load of the index at the top of each callback. If it changed, it **crossfades** rather than swapping: run old and new coefficient sets in parallel for one buffer (or a fixed 256 to 512 frames) and linearly mix output. This removes zipper noise and transients when a band jumps. Filter state (`z1`, `z2`) carries over from the old set into the new; for small changes that alone is usually inaudible, crossfade covers large ones.
4. Slider drags generate many updates; coalesce on the main thread to at most one publish per ~10 ms.

Gain (app volume, pre-gain) already ramps per sample in Phase 1; reuse that smoother.

### 1.4 Headroom and clip guard

Boosting bands can push a full-scale signal past 0 dBFS. Float math will not clip internally, but the output device will.

- **Auto pre-gain:** set pre-gain to minus the maximum positive peak of the computed response curve (from 1.2), capped at minus 12 dB. Expose as "Auto headroom" toggle, default on. This is the honest fix; it makes boosted presets slightly quieter overall.
- **Clip guard:** a cheap soft clipper or a fast lookahead-free peak limiter after gain. Proposed: a `tanh`-style soft knee above minus 1 dBFS, or a 1-pole envelope limiter (attack ~1 ms, release ~100 ms, ceiling minus 0.3 dBFS). The limiter is a Phase 4 "effect" in full form; in Phase 2 it is a fixed safety stage, always on when EQ is active, not user-tunable.
- Optional meter: publish per-buffer peak to an atomic for the UI to show a "limiting" indicator.

### 1.5 Bypass and A/B

- **Bypass** is a flag in the coefficient set, so it crossfades like any other change. Bypass skips EQ and pre-gain, keeps app gain and clip guard.
- **A/B compare:** two named slots (A and B) in the presentation state; toggling publishes the other slot's coefficients. Store the "unsaved edits" separately from the preset so comparing never discards work.
- **Undo:** keep a bounded undo stack (e.g. 50) of `EQSettings` values on the main thread; trivially Codable value types make this cheap.

### 1.6 System-wide EQ via a global tap

`initStereoGlobalTapButExcludeProcesses:` with `muteBehavior = CATapMutedWhenTapped` [SDK] gives us a stereo mix of every process except the ones listed, muting their direct output while we read it. Feed that into a private aggregate whose main subdevice is the current output, apply EQ, write to output. Effectively a software system EQ without a virtual driver.

Tradeoffs and open questions:

- **Must exclude ourselves.** Our own aggregate's playback is process audio from Pyrate Sounds. If it is not excluded we feed back. Resolve our process object with `kAudioHardwarePropertyTranslatePIDToProcessObject` on `getpid()` [SDK] and put it in the exclusion list. [Unverified: whether aggregate IO is attributed to our process object; spike needed, but excluding it is required regardless.]
- **Interaction with per-app taps.** If an app is per-app tapped (Phase 1) and also captured by the global tap, it is processed twice or double-muted. Rule: the global tap excludes every process that has an active per-app tap, and per-app engines run their own EQ copy (device EQ chain applied after app gain) so the user hears a consistent result. Every per-app tap engage or release therefore rebuilds the global tap's exclusion list. [Unverified: cost and glitch of rebuilding a global tap; test whether changing `processes` on a live tap via `kAudioTapPropertyDescription` set is possible, which would avoid destroy and recreate.]
- **Stereo only.** The global tap is a stereo (or mono) mixdown. Multichannel outputs (5.1 interfaces, spatial) lose channels. The UI must say "System EQ works on stereo outputs" and disable it for devices with more than 2 output channels, rather than silently downmixing. An alternative is `initExcludingProcesses:andDeviceUID:withStream:` which matches the device stream format [SDK]; this may preserve channel count and is the preferred path to spike first.
- **Latency.** Adds one aggregate IO cycle plus any drift compensation. Fine for music and video; may be noticeable for live monitoring. [Unverified magnitude; measure with loopback.]
- **New processes.** A global exclusive tap includes processes that start later automatically, which is exactly what we want (unlike include-list taps that need rebuilding on macOS 14 and 15).
- **Sample rate and device changes.** On default output change, tear down and rebuild against the new device; coefficients recompute for the new rate.
- **Failure mode is safe.** If our process dies, taps go away and audio returns unprocessed. Document this as a feature.
- **Permission.** Same audio capture TCC as Phase 1, no new prompt.

Verdict: feasible and the right default. Ship behind a capability check: `systemEQ.isAvailable = tapAPIAvailable && permissionGranted && outputChannelCount <= 2 (or device-stream tap works)`.

### 1.7 Preset data model

```swift
struct EQBand: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: Kind            // peak, lowShelf, highShelf, lowCut, highCut
    var frequency: Double     // Hz
    var gainDB: Double
    var q: Double
    var isEnabled: Bool
}

struct EQPreset: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var mode: Mode            // graphic10, parametric
    var bands: [EQBand]
    var preGainDB: Double?    // nil means auto headroom
    var isBuiltIn: Bool       // built-ins are read-only; duplicate to edit
    var schemaVersion: Int
}

struct EQAssignment: Codable, Hashable {
    enum Target: Codable, Hashable { case device(uid: String), source(id: String) }
    var target: Target
    var presetID: EQPreset.ID?
    var unsavedOverride: [EQBand]?
    var bypassed: Bool
}
```

Built-ins: Flat, Bass Boost, Vocal Clarity, Treble Lift, Loudness (low and high shelf), Podcast. Described in UI as starting points.

Device assignments key on device UID, never name.

## 2. Input devices

- **Enumeration:** same `kAudioHardwarePropertyDevices` path as outputs, filter by `kAudioDevicePropertyStreams` with input scope. Reuse the Phase 1 device service with a `direction` parameter.
- **Default input:** get/set `kAudioHardwarePropertyDefaultInputDevice` [SDK], confirm via listener, same operation lifecycle as output switching.
- **Input volume and mute:** `kAudioDevicePropertyVolumeScalar` and `kAudioDevicePropertyMute` on input scope; check `AudioObjectIsPropertySettable` per element (main element first, then channels 1 and 2). Many USB mics expose no input volume; show "Gain is set on the device" instead of a dead slider.
- **Who is using the mic:** `kAudioProcessPropertyIsRunningInput` per process object [SDK] tells us which processes have active input streams, and `kAudioProcessPropertyDevices` with input scope says which device [SDK]. This is metadata only, no audio access, and needs no microphone permission [Unverified that no TCC is needed to read it; spike]. This is a strong honest feature: "Zoom is using MacBook Pro Microphone".
- **Level metering:** reading input samples requires **microphone TCC** (`NSMicrophoneUsageDescription`), not audio capture. Implement via AVAudioEngine input node tap or an IOProc on the input device. Only meter while the panel is open, and only after the user turns metering on, so the orange mic indicator does not appear unexpectedly. The UI must state that metering turns on the system mic indicator.
- **System vs per-app selection:** Copy for the input picker: "Default input for apps that follow the system setting. Apps like Zoom or Logic may choose their own." Use `kAudioProcessPropertyDevices` to flag apps whose active input differs from the default.
- Per-app input gain is not feasible with public API (taps capture output, not another process's input). State that plainly; do not offer it.

## 3. Global shortcuts

| Option | Permission | Can consume the key | Notes |
|---|---|---|---|
| Carbon `RegisterEventHotKey` | None | Yes | Old but still exported [SDK]; used by most shipping utilities; no sandbox issue |
| `NSEvent.addGlobalMonitorForEvents` | Accessibility (or Input Monitoring) | No, observe only | Wrong tool: the key also reaches the front app |
| `CGEventTap` | Accessibility / Input Monitoring | Yes | Needed only for media keys or remapping; heavy permission |
| KeyboardShortcuts (sindresorhus) | None | Yes | Wraps Carbon hot keys plus a SwiftUI recorder and UserDefaults storage |

Recommendation: **Carbon `RegisterEventHotKey` behind our own `ShortcutService`**, modeled on the KeyboardShortcuts package pattern (a recorder view, named shortcut identifiers, central registry). Either adopt that package (MIT, small, no permissions) or write a ~200 line equivalent. Adopting it is faster; writing it keeps zero dependencies. Lean toward adopting it unless the project decides on no third-party packages.

Conflict detection:
- `RegisterEventHotKey` returns `eventHotKeyExistsErr` when another app holds the combo [Unverified on current macOS; it historically does not always detect conflicts with other apps]. Surface that error in the recorder.
- Check system shortcuts with `CopySymbolicHotKeys` (HIToolbox) [Unverified availability in current headers; symbol check needed] and warn on matches.
- Check internal duplicates in our registry.
- Reject combos without a modifier except F-keys.

Media keys: the volume keys and F10 to F12 cannot be captured by `RegisterEventHotKey`; they are system-defined `NSEvent` subtype 8 events. Intercepting them needs a `CGEventTap` with Accessibility permission. Phase 2 should **not** do this; instead, offer shortcuts like Option+Shift+Up for "raise focused app". Revisit media-key takeover as an opt-in advanced feature later.

Contextual keys (panel open): handled by SwiftUI focus and `onKeyPress` in the panel, not global registration. Arrow keys adjust the focused slider, M toggles mute on the focused row, Space toggles too.

## 4. Layouts, favorites, ordering

Keep presentation state strictly separate from discovery state (Phase 1 already does this at the domain level).

```swift
struct InterfaceConfiguration: Codable {
    var schemaVersion: Int
    var density: Density                // compact, regular, comfortable
    var layout: Layout                  // compact (master + pinned only), expanded (all sections)
    var sectionOrder: [SectionID]       // output, input, apps, eq
    var collapsedSections: Set<SectionID>
    var hiddenSections: Set<SectionID>
    var appOrdering: AppOrdering        // manual, name, recentActivity
    var manualOrder: [SourceID]         // only used when manual
    var pinned: [SourceID]              // ordered
    var hidden: Set<SourceID>           // user chose to hide this app
    var showInactiveApps: Bool
}
```

Rules:
- Rows are keyed by `SourceID`, so pinning and manual order survive a source disappearing and returning.
- Merge algorithm for display: pinned (in pinned order, present or shown as "Not playing" placeholder if the user opts in) then others by chosen ordering. Sources absent from `manualOrder` append at the end, never insert at the top.
- **No reordering during interaction.** Activity-based sort is frozen while the pointer is in the list or a slider is being dragged, and re-sorts with a short animation (respecting Reduce Motion) when interaction ends. Phase 1's stabilizer already has a grace period; extend it with a `isInteracting` freeze flag.
- Drag to reorder in the expanded layout (SwiftUI `onMove` in a `List`, or `draggable`/`dropDestination` in a custom stack). Keyboard alternative: context menu "Move up / Move down / Pin to top" so reordering is not pointer-only.
- Compact layout: master volume, output picker, pinned apps only, with a "Show all" disclosure.
- Density changes row height, slider thickness, and whether the value readout is inline or on hover; never hides the mute control.

## 5. Diagnostics view basics

A "Diagnostics" tab in Settings (Advanced), read-only, no audio content:

- Output and input devices: name, UID, transport, nominal sample rate, channel count per scope, settable volume/mute flags, alive state.
- Audio processes: PID, bundle ID, attributed source, running input/output, devices in use.
- Active taps and aggregates owned by us: tap UID, included processes, tap format, aggregate UID, IO running, last error.
- Engine stats: number of active IOProcs, overload count (`kAudioDeviceProcessorOverload` listener) [Unverified selector name; check header], limiter activation count.
- Permission states: audio capture, microphone.
- "Copy diagnostics" button that produces a plain-text report, with bundle IDs but no window titles or media metadata. Shows the exact text before copying.

## 6. Task breakdown and acceptance criteria

1. **DSP core (`PyrateDSP` target, pure Swift + tiny C atomics shim).** Biquad struct, RBJ coefficient functions, response evaluator, smoothers, soft clip / limiter.
   Acceptance: unit tests show response within 0.1 dB of reference at band centers; impulse test for stability at all preset extremes; zero allocations in `process()` (verified with an allocation counter in tests).
2. **Realtime parameter handoff.** Triple buffer, atomic index, crossfade on change.
   Acceptance: stress test toggling coefficients at 1 kHz from main thread while processing produces no NaN, no discontinuity above a threshold in a sine sweep.
3. **Per-app EQ in the tap engine.** Extend engage predicate to "gain != 1 or muted or EQ assigned".
   Acceptance: assigning an EQ to an app at 100% engages its tap; removing it releases the tap; audible change confirmed manually.
4. **System EQ spike, then implementation.** Spike: device-stream exclusive tap vs stereo global tap, self-exclusion, rebuild cost, latency.
   Acceptance: spike doc with measurements; implementation passes "play music, enable system EQ, change output device, unplug headphones" without stuck mute or feedback; disabled with explanation on multichannel devices if unresolved.
5. **EQ UI.** 10-band graphic view, parametric editor, live curve, presets (save, rename, duplicate, delete), bypass, A/B, undo, auto headroom toggle, VoiceOver adjustable per band.
   Acceptance: every band operable by keyboard; curve updates under 16 ms per change; presets persist across relaunch.
6. **Input devices.** Picker, default switch with confirmation, settable volume/mute, "who is using the mic" list, opt-in metering with clear mic-indicator copy.
   Acceptance: no microphone prompt unless metering is turned on; unsettable devices show explanation not a slider.
7. **ShortcutService.** Carbon hot keys, recorder UI, registry, conflict warnings, default set empty (user opts in).
   Acceptance: shortcuts work with panel closed, survive relaunch, duplicate combos rejected, no Accessibility prompt ever.
8. **Interface configuration.** Model above, compact/expanded, pin, hide, manual order, interaction freeze.
   Acceptance: rows never move while a slider is dragged; pinned app that quits and relaunches returns to its pinned slot; all reordering available from keyboard.
9. **Diagnostics tab.**
   Acceptance: report contains no media titles; copy shows preview; refreshes live while open and stops polling when closed.

## 7. Notes for the Phase 1 tap engine

- Exclude Pyrate Sounds' own process object from any tap (`TranslatePIDToProcessObject(getpid())`) to avoid feedback.
- Read `kAudioTapPropertyFormat` instead of assuming float32 stereo; the IOProc should handle interleaved and non-interleaved.
- Aggregate input buffers can include the output device's own input streams (headsets); the tap streams must be located, not assumed to be buffer 0.
- Design the IOProc as `pre-gain -> [slot for DSP chain] -> gain ramp -> [slot for clip guard]` now, with empty slots, so Phase 2 does not restructure it.
- Keep the engage predicate a single function (`needsTap(source)`) so EQ and later routing can extend it.
- `bundleIDs` and `processRestoreEnabled` on `CATapDescription` are macOS 26+ only; on 14.4 to 15.x we must rebuild include-list taps when process objects change. Gate the 26+ path with `#available`.
