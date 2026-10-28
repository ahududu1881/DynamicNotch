# Writing plugins

**English** · [Türkçe](PLUGINS.tr.md)

Plugins are written in JavaScript. No server, port or extra program is needed: the app runs each plugin inside itself,
isolated from other plugins and from the app.

## 1. Your first plugin (2 minutes)

Menu bar icon → **Settings → Plugins → Add example plugins** copies three examples. Or create a folder by hand:

```
~/Library/Application Support/DynamicNotch/Plugins/my-plugin/
    plugin.json
    main.js
```

`plugin.json`:

```json
{
  "id": "me.hello",
  "name": "Hello",
  "version": "1.0",
  "description": "Says hello in the notch.",
  "permissions": []
}
```

`main.js`:

```js
notch.toast({ text: "Hello!", symbol: "hand.wave.fill", tint: "#FF9F0A" });
```

The moment you save a file the plugin reloads itself (about 2 seconds). Errors appear under
**Settings → Plugins → Show log**.

### plugin.json fields

| Field | Required | Description |
|---|---|---|
| `id` | yes | 3–80 characters: letters, digits, `-`, `_`, `.`. Identifies the plugin, do not change it |
| `name` | yes | Name shown in the list |
| `version`, `description`, `author` | no | Information |
| `main` | no | Main script, `main.js` by default. Cannot point outside the folder |
| `permissions` | no | The permissions below |

## 2. Showing things in the notch

```js
notch.toast({ text: "Done", symbol: "checkmark.circle.fill", tint: "#34C759", duration: 2, id: "build" })
notch.toast({ level: 0.6, symbol: "arrow.down.circle.fill" })          // a bar
notch.card({ title: "Deploy finished", subtitle: "v2.4 is live", symbol: "shippingbox.fill", tint: "#0A84FF",
             url: "https://example.com", duration: 6 })                // clicking the card opens the link
notch.activity({ id: "download", text: "Downloading", symbol: "arrow.down.circle.fill", level: 0.4 })  // persistent indicator
notch.activity({ id: "rec", text: "Recording", countsUp: true })       // counts elapsed time
notch.endActivity("download")
notch.timer({ id: "tea", seconds: 300, label: "Tea" })                 // countdown; sound + 'timer' event when done
```

- `symbol`: any SF Symbol name. `tint`: `#RRGGBB`.
- A toast or card with the same `id` updates in place, others queue.
- A plugin may show at most 8 toasts/cards per 10 seconds and keep at most 4 activities at a time.
- Toasts and cards are not shown while a full-screen app is active.

## 3. Reacting to events

```js
notch.on("media", function (m) { ... })
notch.off("media", handler)
```

| Event | Data |
|---|---|
| `launch` | `{}`, when the plugin loads |
| `media` | `changed` (`track` / `state` / `stopped`), `title`, `artist`, `album`, `app`, `appName`, `playing`, `duration`, `position` |
| `volume` | `level` (0–1), `muted` |
| `brightness` | `level` |
| `focus` | `on`, `name`, `id` |
| `battery` | `percent`, `charging`, `plugged` |
| `accessory` | `name`, `connected`, `model` (AirPods, Beats, JBL...) |
| `recording` | `active`, `seconds` (when it ends) |
| `touchid` | `phase`: `waiting`, `success`, `cancelled` |
| `timer` | `id`, `label`: when a timer set by the plugin finishes |
| `notification` | `app`, `bundleId`, `title`, `subtitle`, `body` (**needs the `notifications` permission**) |

If one event handler throws, the others keep running; the error goes to the log.

## 4. Reading state and storing data

```js
notch.media.state()          // { title, artist, playing, duration, position, ... }  ({} when nothing plays)
notch.system.volume()        // 0–1 or null
notch.storage.set("key", { a: 1 }); notch.storage.get("key"); notch.storage.remove("key")
setTimeout(fn, ms); setInterval(fn, ms); clearTimeout(id); clearInterval(id)   // at least 50 ms, at most 20 timers
console.log / info / warn / error                                              // writes to the log
notch.plugin   // { id, name, version, permissions }
```

`storage` keeps up to 64 KB of JSON per plugin and survives restarts. `Promise` and `async/await` work.

## 5. Permissions

Plugins that ask for no permission run without any prompt. For the others an approval dialog appears on first load;
**if the plugin's code changes it asks again.** If you refuse, the plugin does not run at all
(use "Ask again" in Settings to be asked once more).

| Permission | Unlocks |
|---|---|
| `network` | `notch.fetch(url, {method, headers, body})` (Promise), `notch.http.get/request(…, callback)`. http/https only; 15 s timeout; 1 MB response limit |
| `shell` | `notch.shell.run("/absolute/path", [args], function (err, {code, stdout, stderr}) {})`. There is no shell: only the executable's full path and its arguments. 30 s, 3 at a time |
| `control` | `notch.media.toggle/next/previous/seek(s)`, `notch.system.setVolume(0–1)`, `notch.openURL(url)` (http, https, mailto and System Settings links only) |
| `notifications` | the `notification` event |

```js
// network
notch.fetch("https://api.example.com/status").then(function (r) { return r.json(); }).then(function (d) {
  notch.card({ title: d.title, symbol: "cloud.fill" });
});
// shell
notch.shell.run("/usr/bin/say", ["Hello"], function (err, r) { if (err) console.error(err); });
```

## 6. Safety and resilience

- Each plugin runs in its own JavaScript context on its own thread. A plugin that falls into an infinite loop
  only locks itself; the notch and other plugins are unaffected. Turning it off and on (or saving the file) refreshes it.
- A plugin cannot reach the file system, the environment, other plugins or the app's internals; it only sees the functions above.
- A script may not exceed 512 KB, the log 100 lines. Symbolic links pointing outside the folder are rejected.
- A broken `plugin.json` or script does not affect the app; the error is shown next to the plugin.

## 7. Examples

Under `Plugins/examples/`:

- **track-toast**: shows the title on every new track.
- **focus-timer**: a 25 minute counter when a Focus turns on, a break card when it ends.
- **weather**: a weather card using the `network` permission.
