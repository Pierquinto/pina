# Pina

Pina is a small native macOS app that keeps your Mac tidy, like a good cleaning lady: it scrubs away the gigabytes you do not need. It shows what is filling your disk and memory, and clears what can safely be regenerated.

Built with SwiftUI, no dependencies, no network calls, no telemetry. The interface is currently in Italian.

## What it does

- **Panoramica (Overview):** free disk space, memory pressure, swap, uptime and the apps using the most memory.
- **Pulizia (Clean up):** developer caches (npm, pnpm, Bun, Yarn, pip, uv, Composer, Xcode DerivedData, Playwright, node-gyp, Homebrew), app caches (Cursor, Claude, Codex, Spotify, Chrome, only while the app is closed) and build folders (`.next`, `.astro`, `.nuxt`, `.svelte-kit`, `.turbo`, `.parcel-cache`). Every item shows its size, and nothing is deleted without a confirmation listing the exact paths.
- **Memoria (Memory):** quit memory-heavy apps and free inactive memory with `purge` (macOS asks for the admin password itself).
- **Disinstalla (Uninstall):** removes an app together with the files it leaves in `~/Library`, moving everything to the Trash so it can be recovered.
- **Spazio (Space):** a read-only, drill-down map of the folders and files taking up space.
- **Menu bar indicator:** shows how much memory is in use and opens a panel with two quick actions. *Free memory*: quit the heaviest apps or free inactive memory. *Free space*: remove every cache and build folder that is safe to delete right now, after showing the exact list.

Folder sizes are measured natively on all CPU cores, so scans take a fraction of the time `du` would need. Pina keeps running in the menu bar when you close its window; quit it from the panel or with ⌘Q.

## Safety rules

- It never follows symbolic links and never touches anything outside your home folder.
- It only removes caches and generated folders. Chats, sessions, databases and virtual machines are never on the list.
- App caches are locked while the app is running.
- Leftover files are matched only by exact bundle identifier or exact app name, never by partial text.
- Cache cleanup is permanent; uninstalling goes through the Trash.

## Install

Requires macOS 14 Sonoma or later on a Mac with Apple Silicon (M1 or later). Intel Macs can build it from source.

1. Download `Pina-<version>.zip` from the [latest release](https://github.com/Pierquinto/pina/releases/latest).
2. Double-click the zip to extract `Pina.app`.
3. Drag `Pina.app` into your `Applications` folder and open it.

The app is signed with a Developer ID and notarized by Apple, so it opens without security warnings.

Some features ask for permissions along the way:

- **Free inactive memory** asks for your administrator password (macOS asks, not Pina).
- **Uninstall** may ask for your password when an app was installed by an administrator.
- To measure folders such as Mail or Safari data, give Pina Full Disk Access in System Settings → Privacy & Security. Without it those folders are simply skipped.

To update, replace `Pina.app` with the new version. To remove Pina, drag it to the Trash.

## Build from source

Requires macOS 14 or later and the Swift toolchain (the Xcode Command Line Tools are enough).

```bash
./build.sh
```

The app is installed in `~/Applications/Pina.app`. Set `BUNDLE_ID` to use your own identifier, and `DEST` to install elsewhere. To redraw the icon: `swift scripts/make-icon.swift`.

A local build is signed ad hoc, so the first launch may need right click → Open. To produce a signed and notarized zip, as in the releases, use `scripts/release.sh` with your own Developer ID certificate and notarytool profile (instructions at the top of the script).

Build folders are searched in common project locations in your home (`Development`, `Developer`, `Projects`, `Code`, `Sites`, `src`, `GitHub`) and in Codex and Cursor worktrees.

## License

Pina is **source-available**, not open source in the OSI sense. It is released under the [PolyForm Noncommercial License 1.0.0](LICENSE.md): you can use, study, modify and share it for any noncommercial purpose. Selling it, bundling it in a paid product or using it commercially requires a separate commercial license from the author: [open an issue](https://github.com/Pierquinto/pina/issues) to ask for one.

Copyright (c) 2026 Pierquinto Manco.
