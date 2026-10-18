# iMonitor

A macOS menu bar system monitor that displays CPU, Memory, GPU utilization and network speed per process.

## Features

- **System Metrics** — Real-time CPU, Memory, and GPU utilization with animated bar charts in the menu bar
- **Network Monitoring** — Upload/download speed with per-process breakdown
- **Per-Process Details** — CPU%, memory and GPU% for each process, sortable by network, CPU, memory or GPU
- **Hide Menu Bar Icons** — An arrow and separator that tuck icons you choose out of sight (ported from Hidden Bar), with auto-collapse and expand-on-hover
- **Hidden Icons Dropdown** — Double-click the arrow (or the iMonitor icon) to list every menu-bar icon in one dropdown — fully hidden ones and icons squeezed behind the notch included — click to open, ⌘-drag to rearrange, without expanding the bar
- **Dark Mode** — Automatically adapts to system appearance
- **Universal Binary** — Native support for Apple Silicon (arm64) and Intel (x86_64)

## Menu Bar Icons (Hidden Bar)

Click the arrow to hide the icons to its left; click it again to bring them back
out, to the left of the arrow. **Double-click** the arrow instead to open a
dropdown below it listing **all** menu-bar icons — the fully hidden ones and the
icons squeezed behind the camera notch included — while the bar stays collapsed:
click an entry to open it, or ⌘-drag entries to rearrange the bar.

**⌘-drag the `|` separator** to choose which icons get hidden: everything left of
the separator hides when collapsed. Right-click the arrow or the separator for the
menu (Show Menu-bar Items, Expand Menu Bar, Auto Collapse toggle, Settings, Quit).
With icon hiding on, the arrow hosts the icon list itself; the standalone chevron
only appears when icon hiding is off.

**Expand on hover** (Settings, off by default) peeks at the hidden icons when the
pointer *rests* on an empty part of the menu bar — on the arrow's hidden side,
past the app's menus. Moving across the bar to an app menu or another icon, or
clicking one, never reveals them, and a peek hides again once the pointer leaves
the bar. The arrow itself never expands on hover, only on a click.

On macOS 27 the system's own hiding mode keeps macOS's menu-bar items (the
clock/calendar, Wi-Fi, Control Center) visible but unresponsive while the icons
are hidden. Expand the bar with the arrow to use them; the calendar and widgets
panel then open as usual.

On **macOS 26 and later**, macOS manages menu-bar items through Control Center: if
the arrow (or the standalone chevron shown when icon hiding is off) does not appear
after enabling a feature, add it under
**System Settings › Control Center › Menu Bar**. The icon list needs the
**Accessibility permission** to read other apps' icons (it prompts on first use).
On macOS 27, hiding is per app and uses the system's own menu-bar visibility, so
iMonitor needs that permission for hiding too.

## Requirements

- macOS 11.0 (Big Sur) or later

## Install

**Homebrew:**

```bash
brew tap aresnasa/homebrew-tap
brew install --cask imonitor
```

**Download:**

Download the latest zip from [Releases](https://github.com/aresnasa/iMonitor/releases/latest), extract, and move `iMonitor.app` to `/Applications`.

## Build from Source

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Generate the Xcode project: `xcodegen generate`
3. Open `iMonitor.xcodeproj` and build, or run: `xcodebuild -project iMonitor.xcodeproj -scheme iMonitor -configuration Release build ONLY_ACTIVE_ARCH=NO`

## Build Script

```bash
./build.sh                # Build Release .app
./build.sh --dmg          # Build + package as DMG
./build.sh --ci           # CI mode (build + DMG)
./build.sh --clean        # Remove build artefacts
```

## Release

```bash
./build.sh --release 1.2.3                # Full release
./build.sh --release 1.2.3 --dry-run      # Preview without publishing
./build.sh --release 1.2.3 --skip-brew    # Skip Homebrew cask update
./build.sh --release 1.2.3 --fix-sha      # Fix cask SHA from existing GitHub release
./build.sh --release 1.2.3 --force        # Overwrite existing tag/release
```

The `--release` flag runs the full release cycle: build universal binary + DMG, create & push git tag, create GitHub Release with the DMG, and update the Homebrew tap (`aresnasa/homebrew-tap`) cask.

**Prerequisites:** `gh` CLI authenticated (`gh auth login`) and git push access.

## Snapshot

<img src="./snapshot.png" width="600" />

## Acknowledgments

- [eul](https://github.com/gao-sun/eul) — System monitoring API reference
- [ITraffic](https://github.com/foamzou/ITraffic-monitor-for-mac) — Original network monitoring project
- [Hidden Bar](https://github.com/dwarvesf/hidden) — Menu-bar icon hiding and notch-overflow menu (MIT, © Dwarves Foundation)

## License

MIT
