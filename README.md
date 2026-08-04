# iMonitor

A macOS menu bar system monitor that displays CPU, Memory, GPU utilization and network speed per process.

## Features

- **System Metrics** — Real-time CPU, Memory, and GPU utilization with animated bar charts in the menu bar
- **Network Monitoring** — Upload/download speed with per-process breakdown
- **Per-Process Details** — CPU% and memory usage for each process
- **Dark Mode** — Automatically adapts to system appearance
- **Universal Binary** — Native support for Apple Silicon (arm64) and Intel (x86_64)

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

## License

MIT
