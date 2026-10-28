# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting started

```bash
swift build          # debug build
swift test           # the whole suite; it should pass before you open a pull request
./scripts/build.sh   # release build: "build/Dynamic Notch.app"
```

You need macOS 14+, the Xcode command line tools and a Mac with a notch to see everything. Without a notch the app falls back to a notch-sized area at the top of the screen.

## How the code is organised

| Path | What lives there |
|---|---|
| `Sources/DynamicNotch/NotchModel.swift` | All state the notch renders: presentation, HUD priority queue, activities, sizes |
| `Sources/DynamicNotch/NotchViews.swift` | The SwiftUI views (pill, player, HUDs, cards, Touch ID animation) |
| `Sources/DynamicNotch/NotchController.swift`, `NotchPanel.swift` | The borderless panel above the menu bar, mouse handling, full-screen handling |
| `Sources/DynamicNotch/*Monitor.swift` | One file per system source: power, Focus, notifications, Touch ID, screen recording, Bluetooth |
| `Sources/DynamicNotch/Plugins/` | The JavaScript plugin host, manager and permissions |
| `Sources/DynamicNotch/Settings*.swift` | Persisted preferences and the Settings window |
| `Helper/` | The MediaRemote bridge, a dylib loaded into `/usr/bin/perl` |
| `Tests/DynamicNotchTests` | Unit tests; some render snapshots when an environment variable is set |

## Guidelines

- **Test what you change.** The model, parsers and plugin host are covered by unit tests; add one next to the behaviour you touch.
- **Visual changes:** the snapshot tests (`TOUCHID_SNAPSHOT`, `FEATURE_SNAPSHOT`, `LEVEL_SNAPSHOT`, `OUTPUT_SNAPSHOT`, set to an output PNG path) render views with `ImageRenderer` so you can review them without the notch. Include a screenshot or screen recording in the pull request.
- **Never crash on bad input from the outside world.** macOS formats can change between releases (notification database, Focus files, Bluetooth reports). Parse defensively, and report a broken dependency in `Diagnostics` instead of failing.
- **Keep it Apple-like.** Springs rather than linear animations, content that moves instead of popping in and out, no jarring flashes. Look at how existing HUDs enter and leave before adding one.
- **Strings** go through `L("tr", "en")`; add both languages.
- **Private APIs** are a last resort and belong behind a check that degrades gracefully. Explain in the pull request why there is no public alternative.
- Match the surrounding code's style and comment density.

## Pull requests

Describe what changed and why, how you tested it, and on which macOS version. Small, focused pull requests are reviewed fastest.
