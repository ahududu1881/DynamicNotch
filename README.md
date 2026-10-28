<p align="center"><img src="docs/hero.jpg" alt="Dynamic Notch"></p>

<p align="center">
  <a href="https://github.com/ahududu1881/DynamicNotch/releases"><img alt="Release" src="https://img.shields.io/github/v/release/ahududu1881/DynamicNotch?style=flat-square&color=8A3FE6"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2EA44F?style=flat-square"></a>
  <a href="https://github.com/ahududu1881/DynamicNotch/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/ahududu1881/DynamicNotch/actions/workflows/ci.yml/badge.svg"></a>
</p>

<p align="center"><b>English</b> · <a href="README.tr.md">Türkçe</a> · <a href="PLUGINS.md">Plugin guide</a> · <a href="CHANGELOG.md">Changelog</a></p>

A menu bar app that turns the MacBook notch into a Dynamic Island. Now Playing, volume and brightness, AirPods, notifications,
Focus, Touch ID, low battery and screen recording all grow out of the notch the way they do on an iPhone.

Requires macOS 14 or later. Made for MacBooks with a notch; other Macs get a simulated notch at the top of the screen.

## Install

Download **DynamicNotch-1.0.0.dmg** from [Releases](../../releases), open it and drag **Dynamic Notch** onto the **Applications** shortcut.
The app is not notarized by Apple, so the first time you may need to right-click it in Applications and choose **Open**.

Or build it from source (the Xcode command line tools are enough):

```bash
./scripts/build.sh && open "build/Dynamic Notch.app"
```

The build is signed with the first Apple Development / Developer ID identity in your keychain, or set `SIGN_IDENTITY`.
Without one it is ad-hoc signed, and macOS asks for the permissions again after every rebuild.
`./scripts/package.sh` builds the app and wraps it in a drag-to-Applications `.dmg` for a release.

## Permissions

Dynamic Notch works without any of them; each one only switches on the matching feature. **Settings → Permissions** shows their state.

| Permission | Used for |
|---|---|
| Accessibility | Catching the volume, brightness and media keys so the notch can replace macOS's own HUD |
| Full Disk Access | Mirroring notifications and detecting Focus changes (reads Notification Center's database and Focus files) |
| Automation | Controlling Music and Spotify directly. macOS asks the first time it is needed |

Nothing leaves your Mac. There are no analytics, and the only network access is looking up album artwork when it controls Music or Spotify through scripting (Spotify's artwork URL, Apple's public iTunes Search with the artist and title), plus whatever a plugin you approved asks for.

## See it in motion

<p align="center">
  <a href="https://github.com/ahududu1881/DynamicNotch/blob/main/docs/promo.mp4"><img src="docs/promo.gif" alt="Dynamic Notch in action" width="560"></a>
</p>
<p align="center"><a href="https://github.com/ahududu1881/DynamicNotch/blob/main/docs/promo.mp4"><b>▶ Watch the full 60-second film</b></a> (1080p, with sound)</p>

## Features

<table>
  <tr>
    <td><img src="docs/features/pill.jpg" alt="Live media"></td>
    <td><img src="docs/features/player.jpg" alt="Full player"></td>
    <td><img src="docs/features/outputs.jpg" alt="Output picker"></td>
  </tr>
  <tr>
    <td><img src="docs/features/volume.jpg" alt="Volume"></td>
    <td><img src="docs/features/brightness.jpg" alt="Brightness"></td>
    <td><img src="docs/features/airpods.jpg" alt="AirPods and Beats"></td>
  </tr>
  <tr>
    <td><img src="docs/features/notifications.jpg" alt="Notifications"></td>
    <td><img src="docs/features/focus.jpg" alt="Focus"></td>
    <td><img src="docs/features/battery.jpg" alt="Low battery"></td>
  </tr>
  <tr>
    <td><img src="docs/features/touchid.jpg" alt="Touch ID"></td>
    <td><img src="docs/features/recording.jpg" alt="Screen recording"></td>
    <td><img src="docs/features/plugins.jpg" alt="Plugins"></td>
  </tr>
</table>

<sub>Every image above is rendered from the app's own views (`swift test` with `MARKETING_SNAPSHOT`, see Development).</sub>

- **Live media.** Whatever is playing on the Mac (Spotify, Music, browsers, YouTube...) in a pill with the artwork and a waveform; click it for the full player with progress, controls and an output device picker.
- **Volume, brightness and media keys** in the notch instead of macOS's toast. While the player is open the feedback grows out of its bottom.
- **AirPods, Beats and JBL.** A short strip with the model's icon when they connect or leave, then the battery of each bud and the case.
- **Notifications.** WhatsApp, Instagram, Messages and more (or every app) appear in the notch with the sender and text.
- **Focus.** The mode's name, icon and colour when it turns on or off.
- **Touch ID.** An animation modelled on Face ID while the fingerprint is requested, ending in a check.
- **Low battery and charging** cards in the style of the iPhone's alert, with the animated ring.
- **Screen recording** indicator with a timer.
- **Full screen.** The notch stays out of the way; only system state changes (volume, brightness, Focus, headphones) show briefly.
- **Activities and timers** pushed by other apps and plugins (downloads, builds, countdowns).
- **Gestures and shortcuts.** Scroll over the notch for volume, swipe the player to skip, `⌃⌥ Space / ← / → / ↑ / ↓ / N` for the rest.
- **Plugins** written in JavaScript, isolated and permission-gated. See [PLUGINS.md](PLUGINS.md).
- **Compatibility checks.** Settings → Advanced shows the health of every macOS dependency. After a macOS update the app checks itself and tells you if something broke; if the media bridge fails it falls back to scripting Music and Spotify.
- **Make it yours.** Language, Dock icon, menu bar icon, animation speed, timings, which events show: Settings has all of it.

## Settings

Menu bar icon → **Settings…** (or click the Dock icon when it is shown). The app lives in the menu bar by default; **General** lets you show it in the Dock
instead of, or as well as, the menu bar icon. One of the two always stays on so you can always get back to Settings, and opening the app again from Finder
brings the window up too.

## Plugins

Write your own in JavaScript: show toasts, cards, persistent indicators and timers; react to media, volume, Focus, battery, AirPods, recording and Touch ID events;
optionally use the network, run commands or control media. Every plugin runs isolated, plugins that ask for permissions need your approval, and changed code asks again.

Quick start: **Settings → Plugins → Add example plugins**, or drop a `plugin.json` and `main.js` into
`~/Library/Application Support/DynamicNotch/Plugins/<name>/`. Full guide and API: [PLUGINS.md](PLUGINS.md).

```js
notch.on("media", function (m) {
  if (m.changed === "track") notch.toast({ text: m.title, symbol: "music.note" });
});
```

## Local HTTP API (optional)

Plugins cover most needs, so the HTTP server is **off by default** (Settings → Advanced). Turn it on to trigger the notch from a script, `curl` or another app.

It listens on `127.0.0.1:39283` (the port is configurable), only reachable from this Mac. `POST` requests must send `Content-Type: application/json`,
which keeps web pages from triggering it. An optional Bearer token can be set in Settings.

| Request | Body | What it does |
|---|---|---|
| `GET /v1/health` | | Is it running |
| `GET /v1/diagnostics` | | Whether every feature works on this Mac |
| `GET /v1/state` | | Notch state, current media, volume |
| `POST /v1/toast` | `text`, `symbol`, `level` (0–1), `tint` (`#RRGGBB`), `duration` (s), `id` | Transient indicator: a bar when `level` is given, text otherwise |
| `POST /v1/activity` | `id` (required), `text`, `subtitle`, `symbol`, `level` (0–1), `tint`, `ttl` (s, default 3600) | Adds or updates a persistent indicator (same `id` = update); shown in the pill when no media plays |
| `POST /v1/activity/end` | `id` | Removes an indicator |
| `GET /v1/activities` | | Active indicators |
| `POST /v1/activity/clear` | | Removes all indicators |
| `POST /v1/timer` | `seconds` (1–86400, required), `label`, `id`, `symbol`, `tint` | Countdown with a sound and a card when done |
| `POST /v1/media` | `action`: `toggle` `next` `previous` `seek` (+ `seconds`) | Controls the playing media |
| `POST /v1/expand`, `/v1/collapse` | | Opens / closes the player |

`symbol` is any SF Symbol name (`hammer.fill`, `arrow.down.circle.fill`...); an invalid one falls back to `bell.fill`. While a full-screen app is active `toast` returns `409`.
A toast with the same `id` updates in place, others queue. With a token set every request needs `Authorization: Bearer <token>` (except `/v1/health`; the CLI reads `NOTCH_TOKEN`).
Errors come back as `{"ok":false,"error":"..."}` with a fitting HTTP status.

```bash
scripts/notch toast "Build finished" hammer.fill "#34C759" 2
scripts/notch progress 0.6 arrow.down.circle.fill
scripts/notch media next
scripts/notch activity build "Building" hammer.fill 0.4
scripts/notch end build
scripts/notch timer 300 "Tea"
scripts/notch state
```

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"text":"Deploy done","symbol":"checkmark.circle.fill","tint":"#34C759"}' \
  http://127.0.0.1:39283/v1/toast
```

## Development

```bash
swift build              # debug build
swift test               # 170+ unit tests: HTTP parser, API validation, notification queue, media states, settings, plugins...
python3 scripts/stress.py  # hostile traffic and 1400+ concurrent requests against a running app (enable the API first)
swift scripts/make-icon.swift  # regenerates Resources/AppIcon.icns and docs/icon.png
MARKETING_SNAPSHOT=docs swift test --filter MarketingSnapshotTests  # regenerates docs/hero.jpg and docs/features/*.jpg
PROMO_DIR=/tmp/frames swift test --filter PromoVideoTests  # renders the promo video frames, see the header of Tests/DynamicNotchTests/PromoVideoTests.swift
python3 scripts/make-promo-audio.py /tmp/frames/timeline.json docs/promo-audio.wav  # the video's soundtrack, synthesised from scratch (original, no licence needed)
```

Code layout: `Sources/DynamicNotch` (the app), `Tests/DynamicNotchTests`, `Helper/` (the MediaRemote bridge), `Plugins/examples`.
The notch UI is driven by one model (`NotchModel`) with a small priority queue for transient indicators; see [CONTRIBUTING.md](CONTRIBUTING.md).

## A note on private APIs

Media capture, brightness, Touch ID, screen recording and notification mirroring use undocumented macOS interfaces
(MediaRemote through a helper loaded into `/usr/bin/perl`, DisplayServices, SkyLight, Notification Center's database). They are the only way to do
these things from outside Apple, but it means the app cannot ship on the Mac App Store and a macOS update can break a feature.
When that happens the app reports it in Settings → Advanced rather than crashing; please open an issue with the report that page can copy for you.

## Contributing and license

Contributions are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).
Released under the [MIT license](LICENSE).
