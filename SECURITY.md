# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on the repository page) and include what you found, how to reproduce it and the macOS version.
You can expect a first answer within a week.

## What is in scope

- The optional local HTTP API (off by default, bound to `127.0.0.1`)
- The JavaScript plugin sandbox and its permission model (see [PLUGINS.md](PLUGINS.md))
- Anything that makes the app read, send or run something the user did not allow

## Design notes

- The app's only network requests are album artwork lookups in the Music/Spotify scripting mode: Spotify's artwork URL and Apple's public iTunes Search API (which receives the track's artist and title). A plugin can only reach the network after the user approves its `network` permission, and the approval is tied to the plugin's code: changing the code asks again.
- The HTTP API only listens on the loopback interface, requires `Content-Type: application/json` on `POST` (so web pages cannot trigger it) and supports a Bearer token.
- Notification mirroring reads Notification Center's local database and needs Full Disk Access, which the user grants explicitly. Message text is only read to be shown: it is never stored or sent anywhere (a temporary copy of the database made while reading is deleted right away), and it can be hidden entirely in Settings.
- The media bridge loads a small helper library into `/usr/bin/perl` to reach the private MediaRemote framework. Its source is in `Helper/`.
