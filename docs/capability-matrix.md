# Pyrate Sounds: Capability Matrix

This expands the brief's Floor 35 table and answers Floor 26: for every capability, what macOS actually permits, at what version, behind which permission, and with which known limits. The UI must derive its controls from this, never promise beyond it.

**Verification key**

- **H**: verified against SDK headers (`MacOSX.sdk`, Xcode with SDK 26.2), by grepping `API_AVAILABLE` in `CoreAudio.framework/Headers` (`AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`) and `AudioToolbox.framework/Headers/AudioHardwareService.h`.
- **D**: from Apple documentation or sample code, not visible in headers.
- **U**: unverified; must be confirmed on hardware before we rely on it.

## Target platform decision

**Minimum macOS: 14.4.** Process taps exist from 14.2 (H), but 14.4 is where the audio-capture permission flow and `NSAudioCaptureUsageDescription` behave reliably (D/U, see notes). Holding at 14.4 avoids a version band where taps exist but permission behavior is inconsistent.

## Verified API availability

| API | Header availability | Key | Notes |
|---|---|---|---|
| `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` | `macos(14.2)`, unavailable on iOS | H | `AudioHardwareTapping.h` |
| `CATapDescription` class | header says `macos(12.0)` | H | Class predates usable taps; only useful with 14.2 creation function |
| `CATapMuteBehavior` (`CATapUnmuted`, `CATapMuted`, `CATapMutedWhenTapped`) | `macos(13.0)` | H | `MutedWhenTapped` silences the original only while our IO reads the tap, so a crash restores audio |
| `initStereoMixdownOfProcesses:` and related initializers | inherit class availability | H | Take process **object IDs**, not PIDs |
| `CATapDescription.bundleIDs` | `macos(26.0)` | H | Tap by bundle ID, survives process restarts. Use only behind `#available(macOS 26, *)` |
| `CATapDescription.processRestoreEnabled` | `macos(26.0)` | H | Lets a tap persist across target relaunch. macOS 26 only |
| `kAudioHardwarePropertyProcessObjectList` (`prs#`) | no per-constant macro | H/D | Documented as macOS 14.0+. Treat as 14.2+ in practice |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` (`id2p`) | no per-constant macro | H/D | Same as above |
| `kAudioHardwarePropertyTapList`, `kAudioHardwarePropertyTranslateUIDToTap` | no per-constant macro | H/D | 14.2+ in practice |
| `kAudioProcessPropertyPID`, `BundleID`, `Devices`, `IsRunning`, `IsRunningInput`, `IsRunningOutput` | no per-constant macro | H/D | Documented 14.0+. `IsRunningOutput` is our activity signal |
| `kAudioTapPropertyUID`, `Description`, `Format` | no per-constant macro | H/D | 14.2+ |
| `kAudioAggregateDeviceTapListKey` (`"taps"`), `kAudioAggregateDeviceTapAutoStartKey` | no macro | H | Auto-start requires the aggregate to be private |
| `kAudioSubTapDriftCompensationKey` and sub-tap latency keys | no macro | H | Needed when tap clock differs from output clock |
| `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` / `VirtualMainBalance` | long-standing | H | Replaces deprecated `VirtualMasterVolume` |
| `kAudioDevicePropertyProcessMute` (`appm`) | no macro | H | Mutes **our own** process on a device, not other apps. Not a per-app mute mechanism |
| `kAudioDevicePropertyVoiceActivityDetectionEnable` / `State` | no macro | H | Input voice activity for our own client; possible Phase 2 meter aid |

## Permissions and distribution summary

| Concern | Requirement | Key |
|---|---|---|
| Process taps (per-app volume, mute, routing, EQ on app audio) | `NSAudioCaptureUsageDescription` in Info.plist; user grants "Audio Capture" (TCC service `kTCCServiceAudioCapture`) on first tap | D; exact TCC service name **U** |
| Microphone level meter or input processing | `NSMicrophoneUsageDescription`; TCC microphone | D |
| Device enumeration, default device switching, master volume | No permission | D |
| Launch at login | `SMAppService.mainApp`, no permission, user can revoke in System Settings | D |
| Global shortcuts | Carbon `RegisterEventHotKey` needs no Accessibility permission; event taps would | D |
| App Store sandbox | Process taps in a sandboxed app: **U**. Assume direct distribution (Developer ID, hardened runtime, notarization) | U |
| Ad-hoc signed dev builds | TCC grants are tied to code signature; rebuilding with ad-hoc signing can re-prompt or lose the grant | D/U |
| AudioServerPlugIn (virtual device) | Installs to `/Library/Audio/Plug-Ins/HAL`, needs admin rights, `coreaudiod` restart, separate signing and notarization, uninstaller. **Avoid unless taps cannot do the job** | D |

## Capability matrix

| Capability | Product expectation | Mechanism / API | Min macOS | Permissions | Limitations | Distribution | Phase |
|---|---|---|---|---|---|---|---|
| Menu bar controls | Fast access to essentials, live state | `MenuBarExtra` (`.window` style), `NSStatusItem` if finer popover control is needed | 13.0 (H/D for SwiftUI) | None | `.window` dismissal rules are fixed by the system; keyboard focus on open needs care | None | 1 |
| Master volume | Control current output | `VirtualMainVolume` on default output; check `AudioObjectIsPropertySettable` | 10.5+ | None | HDMI/DisplayPort and many USB DACs are **fixed level**: not settable. Show "fixed by device" instead of a slider | None | 1 |
| Master mute | Toggle output mute | `kAudioDevicePropertyMute` (output scope, main element) | long-standing | None | Some devices expose no mute; fall back is **not** volume 0 silently. Report as unsupported | None | 1 |
| Per-app volume and mute | Independent level per source | Process tap (`CATapMutedWhenTapped`) + private aggregate device with output device as main sub-device + IOProc applying gain | 14.2 (H), target 14.4 | Audio Capture | Adds a small latency; only works for processes that appear in the process object list; apps outputting through exclusive/hog mode (`kAudioDevicePropertyHogMode`) may not be tappable (U); shared processes (below) cannot be split | Non-sandboxed, Developer ID | 1 |
| Shared audio processes | Honest attribution | Resolve outermost `.app` in process path; flag known shared hosts | 14.2 | None | `com.apple.WebKit.GPU` (and related WebKit helpers) plays audio for Safari, Mail, and any WKWebView app at once: one control for all of them, labeled as shared. Chrome/Electron helpers attribute cleanly to their parent `.app` | None | 1 |
| Source discovery | Live app list | `kAudioHardwarePropertyProcessObjectList` listener + per-process `IsRunningOutput` listener; `NSRunningApplication` for name/icon | 14.0 (D) | None | A process can exist with no output; apps that open a stream but stay silent look "running" not "active". Helper PIDs change on relaunch: key prefs by bundle ID, not PID | None | 1 |
| Output devices | List, select, react to changes | `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultOutputDevice` (get, set, listen), `DeviceUID`, `TransportType`, `DeviceIsAlive` | long-standing | None | Bluetooth may report present before ready, and A2DP/HFP profile switches change sample rate and channel count; switching must be confirmed by listener, with timeout. Hide our own private aggregates (filter by UID prefix) | None | 1 |
| Input devices | List, select, gain where supported | Same device APIs, input scope; `kAudioHardwarePropertyDefaultInputDevice`; volume via `kAudioDevicePropertyVolumeScalar` input scope | long-standing | None for selection; **Microphone** for a level meter | Apps can pick their own mic (Zoom, Logic): system default is not universal. Many mics have no settable gain | None | 2 |
| Input level meter | Show mic activity | Our own input IOProc reading peaks | long-standing | Microphone | Triggers the orange mic indicator while metering. Meter only while panel is open | None | 2 |
| Which app uses the mic | Activity monitor | `kAudioProcessPropertyIsRunningInput` | 14.0 (D) | None (U) | Reports stream activity only, never content | None | 2 |
| Equalizer | Shape supported paths | Biquad chain inside the tap IOProc (per app), or a global tap via `initStereoGlobalTapButExcludeProcesses:` for "system EQ" | 14.2 | Audio Capture | Applies only to tapped audio; a global tap misses processes that bypass the HAL mix. Needs headroom and limiter to avoid clipping. Adds CPU on the realtime thread | Non-sandboxed | 2 |
| Additional effects | Modular chain, bypass | Same IOProc, `ProcessingStage` chain with preallocated state | 14.2 | Audio Capture | Each stage must be realtime safe; latency budget must be measured | Non-sandboxed | 4 |
| Per-app routing | Send app to chosen output | Tap with `MutedWhenTapped`, aggregate whose main sub-device is the **destination** device | 14.2 | Audio Capture | Original stream is muted, not moved: if our app dies, audio returns to the default device (a safe failure). Drift compensation needed across clocks. Apps that select their own device are still tappable but the result is "duplicate then mute" (U on edge cases) | Non-sandboxed | 4 |
| Per-app routing to multiple outputs | One source, many destinations | One aggregate with several output sub-devices, or several aggregates | 14.2 | Audio Capture | Clock drift between devices; latency mismatch | Non-sandboxed | 4 |
| Balance | L/R balance | `VirtualMainBalance` when settable; otherwise per-channel gain in our tap path | long-standing / 14.2 | None / Audio Capture | Not all devices expose balance; mono devices must hide it | None | 4 |
| Multichannel | Accurate channel layouts | `kAudioDevicePropertyPreferredChannelLayout`, stream formats; non-mixdown taps via `initWithProcesses:andDeviceUID:withStream:` | 14.2 | Audio Capture | Stereo mixdown taps flatten channels: multichannel must use device/stream taps | Non-sandboxed | 4 |
| Profiles | Save and restore configs | Versioned JSON in Application Support | n/a | None | Profiles referencing absent devices or apps must apply partially and report | None | 3 |
| Automation | Rules on events | Triggers from `NSWorkspace` launch/terminate notifications, process `IsRunningOutput`, device list and default-device listeners | 14.0 | None beyond the actions' own | No public "meeting started" signal; approximate with app + `IsRunningInput`. Calendar triggers would need EventKit permission | None | 3 |
| Shortcuts | Global and contextual | Carbon `RegisterEventHotKey` (or a maintained wrapper) | long-standing | None | Media volume keys cannot be reliably intercepted without an event tap (Accessibility/Input Monitoring) | None | 2 |
| Custom layouts | Persistent presentation config | Versioned JSON, separate from audio prefs | n/a | None | None | None | 2 |
| Activity history | Explain changes | Local ring buffer, metadata only, retention cap | n/a | None | Must never store audio content; app names are stored, so honor a "clear history" control | None | 3 |
| Diagnostics | Troubleshooting | `os_log` with privacy annotations; export bundle on request | n/a | None | Exports must be user initiated and previewable | None | 2 |
| Import/export | Move configs | Versioned schema; see `research/phase-5-ecosystem.md` | n/a | None | Device UIDs are machine specific; bundle IDs mostly portable | None | 5 |
| Extension architecture | Future capabilities | Internal protocols first; restricted non-realtime extensions later | n/a | Depends | No third-party realtime DSP until isolation is solved | Plugins would affect notarization | 5 |
| Launch at login | Start with session | `SMAppService.mainApp` | 13.0 (D) | None | User can disable in System Settings; reflect actual status | None | 1 |
| macOS 26 enhancements | Survive relaunch without rebuild | `CATapDescription.bundleIDs`, `processRestoreEnabled` | 26.0 (H) | Audio Capture | Optional path; 14.4 baseline must keep working | None | 2+ |

## Open items to verify on hardware

1. Exact OS version where the Audio Capture TCC prompt first appears, and behavior on 14.2/14.3 (U).
2. Whether process taps work inside the App Store sandbox and with which entitlement (U).
3. Behavior of taps on apps using hog mode or their own device selection (U).
4. Whether `IsRunningInput` is readable without microphone permission (U).
5. Latency added by tap plus aggregate on built-in speakers, AirPods, and a USB interface (measure).
6. TCC grant persistence across ad-hoc rebuilds during development (D/U).
