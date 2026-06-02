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
brew install imonitor
```

**Download:**

Download the latest zip from [Releases](https://github.com/aresnasa/iMonitor/releases/latest), extract, and move `iMonitor.app` to `/Applications`.

## Build from Source

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Generate the Xcode project: `xcodegen generate`
3. Open `iMonitor.xcodeproj` and build, or run: `xcodebuild -project iMonitor.xcodeproj -scheme iMonitor -configuration Release build ONLY_ACTIVE_ARCH=NO`

## Release

```bash
./release.sh [version]
```

This script builds a universal binary, packages it, creates a GitHub release, and updates the Homebrew tap.

## Snapshot

<img src="./snapshot.png" width="600" />

## Acknowledgments

- [eul](https://github.com/gao-sun/eul) — System monitoring API reference
- [ITraffic](https://github.com/foamzou/ITraffic-monitor-for-mac) — Original network monitoring project

## License

MIT
