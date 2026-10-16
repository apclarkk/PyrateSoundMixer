# Pyrate Sounds

A native macOS menu bar app for controlling your Mac's audio: master volume, output device, and per-app volume and mute.

Requires macOS 14.4 or later.

## Build and run

```sh
scripts/build-app.sh --open   # release build, ad-hoc signed, into build/, then launch
swift test                    # domain unit tests
```

The first time you change an app's volume, macOS asks for audio recording permission. Per-app control works by tapping that app's audio and playing it back at your level; apps left at 100% are never tapped.

## Features

- **Mixer:** per-app volume and mute, master output, output and input devices, pinned apps and custom order
- **Per-app sound:** 10-band EQ with presets and preset previews, loudness matching, lookahead limiter, balance, mono and channel swap, routing to any output
- **Automation:** profiles (layered, undoable), rules with priority and automatic restore, activity history
- **Shortcuts and integrations:** global hot keys, `pyratesounds://` commands for Shortcuts, Raycast, and scripts (see `docs/extensions.md`)
- **Settings portability:** export, import with device remapping, automatic backups, shareable profiles
- **Under the hood:** routing map window and a diagnostics report

## Layout

```
Sources/
  PyrateCore/     domain: identities, capabilities, volume state, operations, preferences (no Core Audio)
  PyrateAudio/    audio services: devices, process discovery, process taps
  PyrateSounds/   presentation: menu bar panel, settings, AppStore
Tests/PyrateCoreTests/
docs/
  architecture.md
  capability-matrix.md
  research/       pre-work for Phases 2 to 5
```

The TODO list lives in the Obsidian vault at `Projects/Pyrate Sounds/TODO.md`.
