<img width="350" height="720" alt="Screenshot 2026-10-16 at 13 16 15" src="https://github.com/user-attachments/assets/396392e2-f6aa-4c4e-95c9-47ba96682749" />

# Pyrate Sounds Mixer

A menu bar app that gives every app on your Mac its own volume slider and output mapping, a feature macOS has been meaning to get around to since about 2001.

Needs macOS 14.4 or later.

## What it does

Each app gets a volume, a mute button, and a 10-band EQ with presets. You can stack Apple's built-in effects on top, such as reverb, echo, distortion, and pitch shift, in case your 9am standup would sound better from inside a cathedral. Apps can play through a different output than the rest of the system all with app-specific EQ and mixing settings. 

This app can replace the native Apple sound control menu
> ⌘ + "Click & Drag" to rearrange menu icon arrangement, pulling an icon completely off the menu bar removes it entirely. Ensure that PyrateSounds has "Start on Login" permissions enabled

## Building

```sh
scripts/build-app.sh --install   # build, copy to /Applications, launch
scripts/build-app.sh --open      # build and launch from build/ instead
swift test                       # run the tests
```

The build is ad-hoc signed, which is fine on your own Mac and useless for handing to anyone else.

## Layout

```
Sources/
  PyrateCore/      domain: identities, volume, EQ, effects, profiles, rules, preferences
  PyrateAudio/     Core Audio: devices, process discovery, taps, the realtime chain
  PyrateAtomics/   C11 atomics for talking to the audio thread
  PyrateSounds/    the menu bar panel, settings, and the store
Tests/
docs/
  architecture.md
  capability-matrix.md
  extensions.md
  research/
```
