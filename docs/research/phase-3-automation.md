# Phase 3 research: profiles, automation, conflicts, history

Status: design pre-work. Nothing here is implemented yet. This document defines how Pyrate Sounds decides which value an audio setting should have when several parties (the user, preferences, profiles, rules) all have an opinion, and how the app explains every change afterwards.

## 1. Vocabulary

- **Target**: one controllable setting. Phase 3 targets are `appVolume(SourceID)`, `appMute(SourceID)`, `outputDevice`, `masterVolume(DeviceID)`, `masterMute(DeviceID)`, and later `eqPreset(DeviceID)`. A target is the unit of conflict resolution.
- **Layer**: a party that can contribute a value for a target. Layers are ordered; see section 2.
- **Claim**: a layer's value for one target, plus metadata (who, when, why).
- **Operation**: a request to change live state, always carrying an `Origin`. Every change, manual or automatic, goes through the same operation pipeline built in Phase 1.
- **Effective value**: the value the resolver says a target should have right now.
- **Live value**: what Core Audio or the tap engine reports. Effective and live can differ briefly (an operation is pending) or persistently (a capability is missing, which the UI must explain).

## 2. Precedence model

### 2.1 The layer stack

From lowest to highest priority:

| # | Layer | Lifetime | Example |
|---|---|---|---|
| 0 | Built-in default | Forever | App volume 100%, unmuted |
| 1 | User preference | Until the user changes it | "Spotify defaults to 40%" |
| 2 | Active profiles | While a profile is active | Night profile: master 30% |
| 3 | Rule overrides | While a rule's condition holds (level) or until superseded (edge) | Meeting ducks Music to 25% |
| 4 | Manual override | Until a defined reset point | User drags Music to 60% |

The resolver walks the stack from the top and takes the first layer that has a claim for the target. Layers are sparse: a profile that only declares app volumes has no claim on the output device, so the output device falls through to lower layers. This is what makes profiles composable instead of monolithic.

### 2.2 Profiles inside layer 2

Several profiles can be active at once. Each profile declares an `aspects` set (for example `[.appVolumes]` or `[.outputDevice, .eqPreset]`) and only contributes claims inside those aspects. Within layer 2, profiles are ordered by activation order with an optional explicit `priority` integer; higher priority wins, ties go to the most recently activated. Example: "Focus" (app volumes) plus "Headphones EQ" (eq preset) never conflict. "Focus" plus "Night" both claim master volume, so the later or higher priority one wins and the UI shows the other as "overridden by Night".

Profiles can also be exclusive within a named group (`exclusivityGroup: "context"`), so activating "Meetings" deactivates "Music" if both are in that group. This covers users who want classic one-at-a-time profiles without forcing it on everyone.

### 2.3 Manual override lifetime

Manual changes are the user speaking directly, so they sit on top. The question is when they expire. Proposed default, configurable in Settings > Automation:

- A manual override on a target is **cleared** when a higher-intent event explicitly addresses that target: the user activates or deactivates a profile that claims it, or a rule with an edge trigger fires and claims it.
- A manual override is **not cleared** by level-triggered rules re-evaluating, by device reconnects, or by app restarts within the same session.
- On session start (app launch or login), manual overrides from the previous session are discarded unless the user opted into "remember manual levels across launches", in which case they are folded into layer 1 as preferences. This keeps the stack honest: the only persistent things are preferences and profiles, both of which the user can see.

The phrase from the brief "manual changes take precedence until the next clearly defined rule activation" maps exactly onto "edge-triggered claims clear manual overrides".

### 2.4 Defined moments

**Session start.** Load preferences and the set of profiles that were active (profiles persist their active flag). Evaluate all rules in level mode against current observed facts, but do not fire edge triggers for conditions that were already true at launch (no "app launched" events for apps that were running before us). Resolve every target, then emit one batched operation with origin `.sessionRestore`. History records one summary entry, not one per app.

**Profile activation.** Clear manual overrides for targets the profile claims. Insert the profile into layer 2. Resolve affected targets only. Emit operations with origin `.profile(id)`.

**Profile deactivation.** Remove its claims. Affected targets fall through to whatever is underneath. No snapshot restore is needed because the stack already knows the value underneath; this is the main advantage of a layer model over "save old value, write new value".

**Manual change.** Write a layer 4 claim. Resolve that one target. Origin `.user(surface)` where surface is `menuBar`, `settings`, `shortcut`, and so on.

**Rule activation (level trigger becomes true).** Add the rule's claims to layer 3. Record a **restore token** per target: the effective value just before the rule applied and the identity of the layer that produced it.

**Rule deactivation (level trigger becomes false).** Remove the rule's claims. For each target:
- If a manual override was written after the rule activated, keep it. The user has since changed it; do not yank it back.
- Otherwise the target falls through to the layer below. Because layer 3 claims were removed, this is automatically the pre-rule value in almost all cases. The restore token is used only for validation and for the history message ("Music restored to 45%").

Edge-triggered rules ("when headphones connect, set Music to 50%") have no deactivation. Their claim lives in layer 3 until superseded by another edge claim on the same target, a profile change on that target, or a manual change. This is the "not every rule is reversible" distinction the brief asks for, and the rule editor must show it: level rules say "while", edge rules say "when".

## 3. Rule engine

### 3.1 Observable facts (trigger catalog)

Only facts that public APIs can report. Each fact source is a Phase 1 or Phase 2 service publishing typed events into a single `FactStream`.

| Fact | Source | Kind |
|---|---|---|
| App launched / terminated | `NSWorkspace.didLaunchApplicationNotification`, `didTerminateApplicationNotification` | edge |
| App is running | `NSWorkspace.runningApplications` | level |
| App is producing audio | Core Audio process object `kAudioProcessPropertyIsRunningOutput`, aggregated per SourceID | level (with debounce) |
| App started / stopped producing audio | derived from the level fact | edge |
| Device connected / disconnected | `kAudioHardwarePropertyDevices` listener, diffed by UID | edge |
| Device present | same | level |
| Default output / input device is X | `kAudioHardwarePropertyDefaultOutputDevice` / `DefaultInputDevice` listeners | level |
| Profile active | internal | level |
| Profile activated / deactivated | internal | edge |
| Time window | timer, wall clock | level |
| Microphone in use by some process | `kAudioProcessPropertyIsRunningInput` | level, Phase 3 stretch, privacy note below |

Explicitly out of scope: reading window titles, calendar events, meeting URLs, or audio content. "Meeting started" is expressed as "Zoom is producing audio" or "any process is using the microphone", which the user can understand and verify.

### 3.2 Rule shape

```
Rule
  trigger:    Condition (level) or Event (edge)
  conditions: [Condition]    all must hold at evaluation time
  actions:    [Action]
  priority:   Int            higher wins within layer 3
  cooldown:   Duration       minimum time between firings (edge rules)
  enabled:    Bool
```

Actions: set app volume (absolute or relative "duck by 50%"), mute or unmute app, select output device (if present), set master volume, apply EQ preset (Phase 2 dependency), activate or deactivate profile, post notification.

A relative action ("duck to 50% of current") is resolved against the effective value of the layers below layer 3 at activation time and then stored as an absolute claim, so re-evaluation does not compound ("50% of 50% of 50%").

### 3.3 Evaluation loop

1. A fact changes. Level facts that flap are debounced at the source: `IsRunningOutput` must hold for 1.5 s to become true and be absent for 4 s to become false (tunable; browsers toggle output constantly between tracks and ads).
2. The engine re-evaluates only rules whose trigger or conditions reference the changed fact (index rules by fact key).
3. Level rules whose truth value changed are added to or removed from layer 3. Edge rules whose event matched and whose cooldown has expired fire once.
4. Resolve affected targets and emit a single batched operation per evaluation pass.

### 3.4 Loop prevention

- Rules may only trigger on **external facts** and profile state. Pyrate's own operations never produce facts that rules consume, with one exception: profile activation. Profile activation from a rule is allowed but each evaluation pass carries a `causalDepth`; passes beyond depth 3 are dropped and logged as "rule chain stopped".
- Device selection by a rule changes the default output device, which is an observable fact. The engine tags facts with the operation ID that caused them when known (it compares the confirmed device change against pending operations), and facts caused by a rule-origin operation do not re-trigger rules in the same chain.
- A rule cannot fire more than N times per minute (default 6). Exceeding this auto-disables the rule and shows "Rule paused: it fired too often".

### 3.5 Failure handling

An action resolves to an operation like any other. Outcomes:
- **Confirmed**: history records the change.
- **Unsupported** (target lacks the capability, e.g. device at fixed level): record once, no retry, mark the rule with a warning badge.
- **Target absent** (app not running, device disconnected): the claim stays in layer 3 as a dormant claim. If the target appears while the rule is still active, the claim applies then. No polling, no retry timer: presence is itself an event.
- **Failed** (Core Audio error): one retry after 500 ms, then record failure and stop. Never loop.

## 4. Conflict resolution, worked examples

**Example A: meeting ducking vs headphones restore (from the brief).**
- Rule M (level, priority 10): while Zoom is producing audio, Music volume 25%.
- Rule H (edge, priority 5): when AirPods connect, Music volume 60%.
- Preference: Music 45%.

Sequence: Zoom call starts, M activates, Music 45% to 25%. During the call AirPods connect, H fires. Both now have layer 3 claims on `appVolume(Music)`. Higher priority wins: Music stays 25%. The UI shows H's claim as "shadowed by Meeting ducking". Call ends, M deactivates and its claim is removed. H's claim is still in layer 3, so Music becomes 60%, not 45%. That is arguably correct: the last thing the user asked automation to do for headphones was 60%. If the user drags Music to 30% during the call, a manual claim now sits on top; when M deactivates the manual claim is kept (it was written after M activated) and Music stays 30%.

Users who want H to lose permanently can raise M's priority or set H to "apply only if no higher rule is active" (a per-rule `skipIfShadowed` flag; when set, a shadowed edge claim is discarded instead of kept).

**Example B: two profiles claim the same device.** "Meetings" picks the USB headset, "Music" picks the speakers, both active, not in an exclusive group. The later activation wins. The profile list shows the loser with a small "1 setting overridden" note that expands to the detail.

**Example C: rule targets a vanished device.** Rule: when the dock connects, select "Studio Display Speakers". The dock connects but the display's audio device takes 3 s to appear. The select-device claim is dormant until the device UID appears, then applies, as long as the rule's claim has not been superseded. If the device never appears within the rule's `timeout` (default 15 s), the claim is dropped with history entry "Studio Display Speakers did not appear".

**Example D: preference vs rule on session start.** Preference Music 45%, rule M active at launch because Zoom is already in a call. Music starts at 25% with origin `.sessionRestore`, history shows "Meeting ducking was already active".

## 5. Activity history

### 5.1 Event schema

```
HistoryEntry
  id: UUID
  timestamp: Date
  origin: Origin                  user / profile / rule / sessionRestore / system
  kind: .change | .failure | .ruleState | .profileState | .device
  changes: [TargetChange]         target, from, to (display-ready values)
  summary: String                 rendered once at write time, localized key + args
  correlationID: UUID?            groups entries from one evaluation pass
```

Rendered example: `11:42 PM  Meeting profile activated. Music 45% to 20%, Zoom 70% to 85%.`

### 5.2 What is recorded

Recorded: profile and rule activation and deactivation, operations they cause, failures, device connect and disconnect, manual changes **coalesced**: a slider drag produces one entry at drag end, and consecutive manual changes to the same target within 10 s merge into one ("Music 45% to 60%").

Not recorded: audio content (never available), per-second activity, which apps produced audio when (only when that fact fired a rule, and then only "Zoom started producing audio" as the trigger reason). The history is an explanation log, not a usage log.

### 5.3 Retention and controls

- Default: last 7 days or 2,000 entries, whichever is smaller. Options: 1 day, 7 days, 30 days, off.
- Stored locally as an append-only JSON Lines file in Application Support, compacted on launch.
- "Clear history" button; history is excluded from configuration export by default.
- Diagnostics export includes history only when the user ticks it, and the export preview shows the content.

### 5.4 "Why did this change?"

Every app row and the master control can show the origin of the current value from the resolver (not from history): "Set by Meeting ducking (rule) at 11:42". A context menu offers "Pause this rule", "Revert to preference", and "Show history". This works even with history turned off because it reads the live layer stack.

## 6. Swift data model sketch

```swift
public enum Origin: Codable, Hashable, Sendable {
    case user(Surface)                 // menuBar, settings, shortcut, contextMenu
    case profile(ProfileID)
    case rule(RuleID)
    case sessionRestore
    case system                        // reconciliation after external change
}

public enum Target: Codable, Hashable, Sendable {
    case appVolume(SourceID), appMute(SourceID)
    case masterVolume(DeviceID), masterMute(DeviceID)
    case outputDevice, inputDevice
    case eqPreset(DeviceID?)
}

public enum TargetValue: Codable, Hashable, Sendable {
    case level(Double)                 // 0...1
    case flag(Bool)
    case device(DeviceID)
    case preset(PresetID)
}

public struct Claim: Codable, Hashable, Sendable {
    public var target: Target
    public var value: TargetValue
    public var origin: Origin
    public var createdAt: Date
}

public struct Profile: Codable, Identifiable, Sendable {
    public static let schemaVersion = 1
    public var id: ProfileID           // UUID, stable across renames
    public var name: String
    public var aspects: Set<Aspect>
    public var claims: [Claim]         // origin filled in on activation
    public var priority: Int
    public var exclusivityGroup: String?
}

public struct Rule: Codable, Identifiable, Sendable {
    public static let schemaVersion = 1
    public var id: RuleID
    public var name: String
    public var trigger: Trigger        // .event(EventPattern) or .condition(Condition)
    public var conditions: [Condition]
    public var actions: [RuleAction]
    public var priority: Int
    public var cooldown: TimeInterval
    public var skipIfShadowed: Bool
    public var enabled: Bool
}

@MainActor
final class Resolver {
    func effective(_ t: Target) -> (TargetValue, Origin)
    func apply(_ claims: [Claim], layer: Layer) -> [Operation]
    func remove(origin: Origin) -> [Operation]
}
```

On disk, profiles and rules live in one versioned document (`automation.json`, `{"version": 1, "profiles": [...], "rules": [...]}`) separate from Phase 1 preferences, so a corrupt automation file never takes down basic mixer preferences. Device references store UID plus the last seen name and transport type, so the UI can say "Studio Display Speakers (not connected)" and import can avoid remapping to a different device with the same name.

### Pipeline

`Resolver` produces `Operation` values. The Phase 1 operation executor runs them unchanged: validate against capabilities, mark pending, call the audio service, confirm via listener or fail. The executor never knows whether the user or a rule asked. The history writer subscribes to operation outcomes and groups them by `correlationID`.

## 7. Hooks Phase 1 should add now

1. **`Origin` on every Operation**, even if Phase 1 only ever uses `.user(surface)`, `.sessionRestore`, and `.system`.
2. **`correlationID` on operations** so batched changes can be grouped later.
3. **A `Target` enum** used by the operation layer instead of ad hoc per-control methods, so the resolver can drive the same API.
4. **Stable IDs everywhere**: `SourceID` from bundle identity, `DeviceID` from Core Audio UID, never display names. Persist last-seen display name and transport type alongside device UIDs.
5. **Separate preference values from live values** in the store (already planned): layer 1 must exist as its own data, not as "whatever the slider was last at".
6. **Mute stored separately from volume** (already planned), because rules mute without losing level.
7. **Operation outcome stream** (an `AsyncStream` or Combine publisher of confirmed and failed operations) for the future history writer.
8. **Debounced per-source "producing audio" fact** exposed by the discovery service as a published value, since rules and the activity UI both need it.
9. **External change detection tagged `.system`**: when a value changes outside Pyrate, record it as a system-origin observation rather than silently overwriting user preferences.
10. **Versioned persistence with per-file schemas**, so `automation.json` can be added without migrating the Phase 1 file.

## 8. Task breakdown

1. Resolver and layer stack with unit tests (pure Swift, PyrateCore).
2. Profile model, persistence (`automation.json` v1), activation and deactivation, exclusivity groups.
3. Profile UI: list, create, rename, duplicate, reorder, delete, aspect picker, "overridden" indicators.
4. Fact stream: NSWorkspace, device, default device, producing-audio, time facts with debounce.
5. Rule engine: indexing, level and edge evaluation, cooldown, causal depth, rate limiting, dormant claims, timeouts.
6. Rule editor UI with "when" vs "while" phrasing and plain-language preview.
7. History writer, coalescing, retention, history view, "why did this change" affordance.
8. Settings > Automation: manual override lifetime option, history retention, pause all automation switch.

## 9. Acceptance criteria and test scenarios

- Deactivating a level rule restores the pre-rule value when the user made no manual change; keeps the manual value when they did. (unit)
- Two profiles with disjoint aspects both apply fully; with overlapping aspects the higher priority or later activation wins and the loser is reported as overridden. (unit)
- Relative ducking never compounds across re-evaluations. (unit)
- Example A sequence produces 45, 25, 25, 60 for Music; with `skipIfShadowed` it produces 45, 25, 25, 45. (unit)
- A rule targeting an absent app or device produces no retries and applies when the target appears while still active. (unit with fake fact stream)
- A rule that selects an output device does not re-trigger itself through the resulting default-device fact. (unit)
- A rule firing more than the rate limit is paused and reported. (unit)
- Flapping `IsRunningOutput` (on/off every 500 ms for 10 s) produces at most one activation. (unit with virtual clock)
- Session start with an already-running meeting applies the rule without emitting edge events for pre-existing apps. (integration)
- Slider drag from 45% to 60% produces exactly one history entry. (unit)
- History respects retention and contains no entries when set to off; "why did this change" still works. (unit and UI)
- Corrupt `automation.json` leaves the mixer and Phase 1 preferences working, with a visible error and a backup of the bad file. (integration)
- Every automatic change is visible in history with its origin and is reversible via "Revert to preference". (UI)
