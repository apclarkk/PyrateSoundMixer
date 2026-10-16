# Pyrate Sounds

A menu bar app that gives every app on your Mac its own volume slider, a feature macOS has been meaning to get around to since about 2001.

Needs macOS 14.4 or later.

## What it does

Each app gets a volume, a mute button, and a 10-band EQ with presets, R&B included. You can stack Apple's built-in effects on top, such as reverb, echo, distortion, and pitch shift, in case your standup would sound better from inside a cathedral.

Apps can play through a different output than the rest of the system. When that device disconnects, the app falls back to the system output and moves back when the device returns.

Profiles save a setup you can switch to in one click. Rules make changes for you, like lowering Music while Zoom has the microphone, and put things back when the call ends. There are also global shortcuts, settings export and import, and `pyratesounds://` links for the Shortcuts app, Raycast, or scripts (see `docs/extensions.md`).

## How it works

Pyrate Sounds taps an app's audio and plays it back at your level, so macOS asks for audio recording permission the first time you touch a slider. Apps you leave at 100% with nothing else changed are never tapped. Nothing is recorded or sent anywhere.

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
