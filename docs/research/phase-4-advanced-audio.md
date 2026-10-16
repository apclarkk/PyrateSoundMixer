# Phase 4 research: advanced audio

Scope: per-application routing, modular effects, channel control and balance, and a visual routing workspace, on macOS 14.4+ using public APIs only. This is pre-work; nothing here is implemented yet.

Verification legend:
- **[SDK]** confirmed in the macOS SDK headers shipped with the installed Xcode (`CoreAudio.framework/Headers/AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`, `AudioServerPlugIn.h`, `AudioToolbox.framework/Headers/AudioHardwareService.h`).
- **[UNVERIFIED]** plausible from documentation or community experience but not proven on this machine. Each one needs a runtime spike before we depend on it.

## 1. Relevant API facts

| Fact | Source |
|---|---|
| `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` are available from macOS 14.2 | [SDK] AudioHardwareTapping.h |
| `CATapMuteBehavior`: `Unmuted`, `Muted`, `MutedWhenTapped`. `MutedWhenTapped` silences the process at the hardware only while another client is reading the tap | [SDK] CATapDescription.h |
| Tap initializers: stereo or mono mixdown of listed processes; stereo or mono global tap excluding listed processes; `initWithProcesses:andDeviceUID:withStream:` and `initExcludingProcesses:andDeviceUID:withStream:`, whose format "will match the format of this stream" | [SDK] |
| Tap properties `mono`, `exclusive`, `mixdown`, `privateTap`, `muteBehavior`, `deviceUID`, `stream` | [SDK] |
| macOS 26 adds `bundleIDs` and `processRestoreEnabled` (tap re-attaches to a process by bundle ID after it relaunches) | [SDK] |
| Aggregate keys: `master` (main subdevice, time source), `clock` (clock device overrides the main device for time base), `private`, `stacked`, `taps`, `tapautostart` (requires `private`) | [SDK] |
| Sub-tap keys: `uid`, `latency-in`, `latency-out`, `drift`, `drift quality`; quality range `kAudioAggregateDriftCompensationMinQuality` (0) to `MaxQuality` (0x7F) | [SDK] |
| Process object properties: `PID`, `BundleID`, `Devices` (scoped input/output), `IsRunning`, `IsRunningInput`, `IsRunningOutput` | [SDK] |
| Tap object properties: `kAudioTapPropertyUID`, `Description`, `Format` | [SDK] |
| `kAudioDevicePropertyPreferredChannelsForStereo` (two UInt32 channel numbers) and `kAudioDevicePropertyPreferredChannelLayout` (an `AudioChannelLayout`) | [SDK] AudioHardwareBase.h |
| `kAudioDevicePropertyProcessMute` affects only the calling process and "does not apply to aggregate devices" | [SDK] |
| `kAudioHardwareServiceDeviceProperty_VirtualMainBalance` exists for device-level balance | [SDK] AudioHardwareService.h |
| An AudioServerPlugIn is a `.driver` bundle installed in `/Library/Audio/Plug-Ins/HAL`, runs sandboxed inside the audio server host, and may not call the client HAL API | [SDK] AudioServerPlugIn.h |

## 2. Per-application routing

### 2.1 The mechanism

There is no public "send process X to device Y" switch. The achievable path is a **re-player**:

1. Create a process tap for the app's process objects with `muteBehavior = .mutedWhenTapped` and `privateTap = true`.
2. Create a private aggregate device whose main subdevice is the **destination** output and whose tap list contains the tap, with drift compensation enabled on the sub-tap.
3. Run an IOProc on the aggregate that copies tap input to destination output, applying gain and the source's effect chain.

While our IOProc reads the tap, the app is silent on its own device and audible on the destination. This is the same engine as Phase 1 per-app volume; routing just changes which device is the aggregate's main subdevice. **That is the single most important design takeaway: Phase 1's tap engine should already take the destination device UID as a parameter instead of assuming the default output.**

A useful safety property falls out: if our process crashes or the tap is destroyed, `MutedWhenTapped` stops muting and the app's audio returns to whatever device it chose. Failure degrades to "normal macOS behavior", not silence.

### 2.2 Apps that pick their own output device

Process taps are attached to the process, upstream of the device, so the stereo mixdown initializer should capture the app's output whatever device it targets. [UNVERIFIED: needs a spike with an app pinned to a non-default device, such as a DAW or a meeting app with its own speaker setting.]

Two consequences:
- `kAudioProcessPropertyDevices` (output scope) tells us which devices the app is actually using. The routing UI should show that as the app's **native destination**, distinct from our **routed destination**.
- If we want to capture only the audio an app sends to one particular device (for example a meeting app that sends ringtones to speakers and voice to a headset), use `initWithProcesses:andDeviceUID:withStream:`. That is an advanced, per-stream route and should be modeled as a separate capability.

### 2.3 Multiple destinations at once

Options, in order of preference:

1. **One aggregate per destination**, each fed by the source's tap. Failures are isolated: one destination disconnecting does not tear down the others. Requires either that a single tap may be listed in several aggregates, or that several taps on the same process may coexist. [UNVERIFIED: both need a spike. If neither works, fall back to option 2.]
2. **One aggregate containing several output subdevices.** The IOProc writes the processed signal into each subdevice's channel range. Non-main subdevices need `drift = 1`. Simpler to keep in sync, but a disconnect of any subdevice invalidates the whole aggregate and must be rebuilt.

"Stacked" (`stacked = 0` means outputs all fed the same data) [SDK] is the system's multi-output-device behavior. Whether it applies to private aggregates with taps is [UNVERIFIED]; we should not rely on it and should write each subdevice's channels explicitly.

### 2.4 Clock domains, drift and sample-rate mismatch

When an app is routed, it still renders against the clock of the device it believes it is playing to (usually the default output). Our aggregate runs on the destination's clock. These two clocks drift, so:

- Set `drift = 1` on the sub-tap and pick a quality (start at `MediumQuality`, 0x40; measure CPU at `HighQuality`).
- Make the destination the main subdevice. Do not set `clock` unless the user has a dedicated clock device; the header states that the clock device then controls the time base [SDK].
- Sample-rate mismatch (app at 48 kHz on the default device, destination at 44.1 kHz) is expected to be handled by the aggregate's drift compensation resampler. [UNVERIFIED.] The engine must read `kAudioTapPropertyFormat` and the aggregate's nominal rate after creation, and refuse to start (surfacing a "format not supported" capability) if they differ and no audio arrives within a timeout, rather than playing pitched or garbled audio.
- Listen for `kAudioDevicePropertyNominalSampleRate` changes on both the source device and the destination; rebuild the engine on change.

### 2.5 Latency

Added latency is roughly: tap buffering + aggregate IO buffer (`kAudioDevicePropertyBufferFrameSize`) + destination `kAudioDevicePropertySafetyOffset` + `kAudioDevicePropertyLatency` + stream latency + any lookahead in our effect chain. Expect low tens of milliseconds on wired devices and well over 100 ms on Bluetooth. [UNVERIFIED numbers; measure.]

The app does not know about this extra delay, so **video in a routed app may drift out of lip sync**. This is a real limitation and the UI should say so when a video-capable app (browser, media player) is routed to a Bluetooth destination. Report computed latency per route in diagnostics.

### 2.6 Bluetooth

- Bluetooth devices may be listed before they are ready; wait for `kAudioDevicePropertyDeviceIsAlive` and a successful aggregate start before marking a route active.
- A headset switching between high-quality output and hands-free mode (when any app opens its microphone) changes the format and sample rate of the device, and often its object ID. Treat it as a destination disconnect plus reconnect, matched by UID.
- Bluetooth latency makes the lip-sync warning above most relevant here.

### 2.7 Destination disconnect

Listen on `kAudioHardwarePropertyDevices` and on the destination's `kAudioDevicePropertyDeviceIsAlive`. On loss:

1. Stop the IOProc and destroy the aggregate (never call into a dead device from the realtime thread).
2. Apply the route's **loss policy**:
   - **Fall back**: destroy the tap. The app returns to its native device. Good for speakers or displays.
   - **Hold silent** (recommended default for headphones and Bluetooth): keep the source muted by keeping a tap read alive on a silent sink, so audio does not suddenly play aloud in a shared room. This needs a running aggregate on some live device writing zeros. [UNVERIFIED that `MutedWhenTapped` stays muted while we read and discard.] Using `CATapMuted` is an alternative, but then the source stays muted even if we stop reading, so it must be paired with very careful teardown.
3. Mark the route `suspended(destinationUnavailable)` in domain state, keep the user's intended route, and restore automatically when a device with the same UID returns.

### 2.8 Virtual audio driver comparison

| | Process tap re-player (recommended) | AudioServerPlugIn virtual device |
|---|---|---|
| macOS versions | 14.2+ (taps), 14.4+ for our floor | Any modern macOS |
| Install | None. App plus a one-time audio capture permission (`NSAudioCaptureUsageDescription`) | Admin install into `/Library/Audio/Plug-Ins/HAL`, then the audio server must be restarted (reboot or privileged restart) |
| Distribution | Developer ID signed and notarized app. Mac App Store compatibility [UNVERIFIED] | Developer ID signed and notarized driver plus installer and uninstaller. Not shippable through the Mac App Store |
| Failure mode | Audio returns to the app's own device | If the virtual device is the default output and our companion app is not running, the user hears silence |
| Code constraints | Normal app code; realtime rules in the IOProc | Driver runs sandboxed in the audio server host and may not call the client HAL API [SDK]; crashes affect system audio |
| What it enables extra | Nothing beyond taps | Apps can explicitly choose "Pyrate" as a device; pre-14.2 support |

Conclusion: **do not ship a driver in Phase 4.** Revisit only if a must-have requirement is proven impossible with taps.

### 2.9 What is and is not achievable

Achievable with public APIs:
- Route a running app's output to any single live output device, with gain, mute and effects.
- Route to several devices at once (exact mechanism pending a spike).
- Detect and recover from destination loss with a clear policy.
- Show the app's native device next to our routed destination.

Not achievable, or not honestly promisable:
- Zero added latency or guaranteed A/V sync for routed apps.
- Routing apps that are not exposed as audio process objects.
- Separating apps that share one audio process. Safari and other WebKit clients may play through a shared WebKit process; that process can only be routed as a group, and the UI must say so.
- Routing per browser tab.
- Controlling an app's input device choice (taps are output side here; input routing needs a different design).
- Surviving app relaunch without rebuilding the tap before macOS 26 (`processRestoreEnabled` helps only on 26+).

## 3. Effects graph

### 3.1 Model

```
Source tap ─▶ [Source chain: gain, EQ, balance, limiter] ─▶ Bus(destination) ─▶ [Device chain] ─▶ Output
```

`Stage` contract, split into control side and realtime side:

```swift
protocol StageDefinition: Sendable {          // control side, value type, Codable
    var kind: StageKind { get }               // .gain, .eq, .balance, .limiter
    var isBypassed: Bool { get }
    func makeProcessor(format: StreamFormat, maxFrames: Int) -> StageProcessor
}

final class StageProcessor {                  // realtime side
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int)  // no alloc, no locks, no ObjC
    var latencyFrames: Int { get }            // e.g. limiter lookahead
    var tailFrames: Int { get }
}
```

A `Chain` is an immutable array of processors built off the realtime thread.

### 3.2 Realtime-safe parameter handoff

- **Scalar parameters** (gain, band gain, balance, threshold): one atomic Float per parameter, written by the main thread, read once per IO cycle, then smoothed per sample or per block (about 10 to 20 ms ramps) to avoid zipper noise.
- **Coefficient changes** (EQ biquads): compute coefficients off-thread, publish via an atomic pointer to a preallocated double buffer; the IOProc interpolates or crossfades between old and new coefficients across one block.
- **Structural changes** (adding, removing or reordering stages, format changes): build a whole new `Chain` off-thread, publish with an atomic pointer swap, and hand the old chain back through a lock-free single-producer single-consumer queue for release on the main thread. The IOProc never frees memory.
- Audio thread priority: join the device's `kAudioDevicePropertyIOThreadOSWorkgroup` [SDK] if we ever spawn helper threads (we should not need to).

### 3.3 Bypass

Each stage and each whole chain has a bypass that crossfades processed and dry signal over 10 to 20 ms. Bypass keeps the processor and its parameters alive, which gives the instant A/B comparison the brief asks for. A latency-adding stage (limiter lookahead) keeps delaying the dry path when bypassed, so A/B does not shift timing.

### 3.4 Per-source vs per-device chains

- **Per-source chains** run inside each source's tap IOProc. Straightforward.
- **Per-device chains** need every app's audio for that device. Two sources feed the device:
  1. Apps we already tap: apply the device chain inside our own engines after the source chain (a shared "bus" stage instance per destination).
  2. All other apps: a global tap that excludes our own process (`initExcludingProcesses:andDeviceUID:withStream:` with our process object) and is `MutedWhenTapped`, re-played through the device chain. Excluding our own process is essential to avoid a feedback loop.
  Because these two paths run on different IOProcs, stateful stages (limiter, dynamics) see two separate signals. A true single limiter over the full mix requires every source to go through one aggregate. Document this and prefer the single-aggregate design for devices with a limiter. [Design decision for Phase 4 kickoff.]

### 3.5 Gain staging and latency reporting

- Process in Float32; clip only at the final output.
- When EQ adds boost, apply automatic pre-gain equal to the maximum band boost (user can disable), and put the limiter last.
- Report per route: chain latency (sum of `latencyFrames`), engine latency (section 2.5), and the total in milliseconds.

## 4. Channel control and balance

### 4.1 Balance math

Balance for a stereo source, `b` in [-1, 1], unity at center, no center dip:

```
gainL = min(1, 1 - b)
gainR = min(1, 1 + b)
```

Constant-power pan for a mono source, `p` in [-1, 1], -3 dB at center:

```
theta = (p + 1) * pi / 4
gainL = cos(theta)
gainR = sin(theta)
```

Use the balance law for stereo material (it never moves the left signal into the right channel) and the pan law only when the input is genuinely mono. Neither should change perceived overall level at center; a balance control must not act like a master volume.

Device-level balance: read and set `kAudioHardwareServiceDeviceProperty_VirtualMainBalance` [SDK] when settable. Our own per-source balance is a stage in the source chain.

### 4.2 Multichannel devices

- Read `kAudioDevicePropertyPreferredChannelsForStereo` [SDK] to find which output channels are "left" and "right". These are not necessarily channels 1 and 2 on an interface.
- Read `kAudioDevicePropertyPreferredChannelLayout` [SDK] for the full layout. Handle `kAudioChannelLayoutTag_UseChannelDescriptions` and `UseChannelBitmap` [SDK] as well as named tags.
- Write stereo sources only to the preferred stereo pair; zero all other channels. Never spread stereo across all channels by index modulo (a common Phase 1 shortcut that would put audio on an interface's headphone or line outs unexpectedly).
- Listen for layout and stream configuration changes; rebuild the chain on change.

### 4.3 Tap mixdown vs non-mixdown

- Stereo mixdown taps (`initStereoMixdownOfProcesses`) give a predictable 2-channel signal. Fine for per-app volume, stereo EQ and balance. They destroy surround information from apps that play multichannel audio.
- Device-stream taps (`initWithProcesses:andDeviceUID:withStream:`) match the device stream's format [SDK], preserving channel count. Use these for routed multichannel sources when the destination has a compatible layout.
- Rule: **choose the tap type from source and destination capabilities**, and record in diagnostics when a downmix happens so it is never silent.

## 5. Visual routing workspace

### 5.1 Graph model

```swift
enum NodeKind { case source(SourceID), stage(StageInstanceID), bus(DeviceID), destination(DeviceID) }
struct Node { let id: NodeID; let kind: NodeKind; var availability: Availability }   // .live, .unavailable(reason)
struct Edge { let from: NodeID; let to: NodeID; var state: EdgeState }               // .requested, .pending, .active, .failed(Error), .suspended(reason)
struct RoutingGraph { var nodes: [NodeID: Node]; var edges: [Edge] }                 // value type, Codable
```

The graph is domain state, separate from layout (node positions, collapsed groups), which is presentation state persisted separately. Saved configurations store the **intended** graph by stable IDs; the live graph is derived by reconciling intended edges with reality.

### 5.2 Capability model so only real edges are offered

```swift
struct RouteCapabilities {
    var canRoute: Bool                 // source is a tappable process group
    var canMultiRoute: Bool            // pending spike outcome
    var sharedProcessGroup: [SourceID]? // e.g. WebKit clients that must move together
    var preservesChannels: Bool        // device-stream tap available for this pair
    var addedLatency: Duration?        // estimate, for warnings
    var blockers: [RouteBlocker]       // .permissionDenied, .destinationNotOutput, .formatUnsupported, .destinationUnavailable
}

func capabilities(source: SourceID, destination: DeviceID) -> RouteCapabilities
```

The UI asks this function before showing a drop target or a menu item. An edge with blockers is drawn disabled with the reason as tooltip and accessibility hint. Every edge goes through the Phase 1 operation lifecycle (requested, pending, confirmed, failed) so the graph never claims an active route that the engine has not confirmed (audio actually flowing: IOProc running and tap format confirmed).

Accessibility: the graph view is optional; every operation it offers must also exist in the simple per-row destination picker, and VoiceOver users get a list representation ("Music: routed to AirPods, via EQ, active").

## 6. Task breakdown

1. Spike A: tap an app that chose a non-default device; confirm capture and `MutedWhenTapped` silence. (1 day)
2. Spike B: one tap in two aggregates, or two taps on one process. Decide the multi-destination design. (1 day)
3. Spike C: sample-rate mismatch and drift compensation quality vs CPU; measure route latency on wired and Bluetooth. (1 to 2 days)
4. Refactor tap engine into `RouteEngine(source, destinationUID, chain)` if Phase 1 has not already. (1 day)
5. Destination loss policies and reconnect by UID. (2 days)
6. `Stage` protocol, chain builder, atomic parameter and chain swap, retire queue. (3 days)
7. Stages: gain, balance, biquad EQ, limiter with lookahead. (4 days)
8. Channel layout reader and stereo-pair writer; tap type selection. (2 days)
9. Routing capability function and per-row destination picker. (2 days)
10. Graph domain model, reconciliation, persistence. (3 days)
11. Visual workspace view with accessible list fallback. (4 days)
12. Diagnostics: per-route latency, formats, downmix notices. (1 day)

## 7. Risks

- **Spike outcomes**: multi-destination and sample-rate behavior are unverified and could force the single-aggregate design.
- **Lip sync**: unavoidable added latency for routed video.
- **Shared processes**: WebKit-style shared audio processes limit per-app routing honesty.
- **Bluetooth mode switches** cause route churn; must be debounced without hiding real failures.
- **CPU**: one aggregate and IOProc per routed app; measure with 5 to 10 routed apps.
- **Feedback loops** if a global tap ever includes our own process.
- **macOS changes**: tap behavior is young (14.2); macOS 26 already changed the API surface. Gate features by OS version in the capability matrix.

## 8. Acceptance criteria

- A user can route a supported app to a non-default output from its row; audio moves within one second on wired devices, and the row shows pending, then active, only after audio is confirmed flowing.
- The app's native device and the routed destination are both visible.
- Unplugging the destination applies the configured loss policy within 500 ms, never plays private audio aloud under "hold silent", and restores the route when the same device (by UID) returns.
- Quitting or force-quitting Pyrate Sounds returns every routed app to its native device.
- Routes that cannot work (shared process, permission denied, unsupported format) are shown disabled with a plain-language reason.
- Effect parameter changes, bypass and chain edits produce no clicks or dropouts and do no allocation on the IO thread (verified with Instruments and an allocation counter in debug builds).
- Balance at center is level-neutral; stereo sources on multichannel interfaces play only on the preferred stereo pair.
- Diagnostics show per-route latency, tap format, destination format and any downmix.
