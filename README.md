# CoreGlance

A lightweight menu bar system monitor for Mac. It shows your Mac's health at a glance, built for Apple Silicon (M1 and later) with Swift and SwiftUI.

- **Light:** about 1% of one CPU core and about 20 MB of memory.
- **Private:** no network requests, no analytics, no account. Nothing leaves your Mac.
- **Small:** about 1,200 lines of code, no third-party dependencies.

<p align="center"><img src="docs/screenshot.png" width="337" alt="The CoreGlance popup showing CPU, memory, GPU, network, disk and battery"></p>

## What it shows

| | |
|---|---|
| **CPU** | Total, user, system, idle, load average, a live graph, and per-core bars split into efficiency and performance cores |
| **Memory** | Used / total, app, wired, compressed, swap, and the macOS memory pressure level (Normal / Warning / Critical) |
| **GPU** | Utilization with a live graph |
| **Network** | Download and upload speed of your internet connection, in bytes or bits |
| **Disk** | Free and total space on the startup disk, with a low-space warning |
| **Battery** | Charge, health (current vs design capacity), cycle count, time remaining, charger wattage |
| **Thermal** | The macOS thermal state (Cool / Warm / Hot / Critical) |
| **Temperature and fans** | Optional, off by default: chip temperature and the speed of each fan |
| **Top processes** | Top 6 by CPU or memory |

The menu bar item can show any mix of CPU, RAM, GPU and network speed, either on one line or in a compact two-line layout.

Optional alerts notify you when memory pressure turns critical, the disk is nearly full, or the Mac is overheating.

## Install

**Requirements:** an Apple Silicon Mac with macOS 14 or later.

### Homebrew

```bash
brew install --cask amritadasbijoy/tap/coreglance
```

Then open CoreGlance from your Applications folder. It is not notarized by Apple, so macOS blocks it the first time: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

To update later, run `brew upgrade --cask coreglance`.

### Download

1. Download `CoreGlance-<version>.zip` from the [Releases](../../releases) page and unzip it.
2. Move `CoreGlance.app` to your Applications folder and open it.
3. The app is not notarized by Apple, so macOS blocks it the first time. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

### Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/amritadasbijoy/CoreGlance.git
cd CoreGlance
./build.sh install
```

This builds the app and copies it to `~/Applications/CoreGlance.app`.

## Settings

Click the gear icon at the bottom of the popup to open the settings page:

- Refresh interval: 1, 2, 5 or 10 seconds
- Appearance: follow the system, or always light or dark
- What the menu bar shows, and the compact two-line style
- Top processes on or off
- Temperature and fan speed on or off (the temperature can also go in the menu bar)
- Network speed in bytes or bits
- Alerts
- Launch at login

## How it stays light

- One timer drives everything, with tolerance so macOS can group wakeups.
- Battery and disk are read every 30 seconds, not on every tick.
- The process list is only read while the popup is open.
- The popup is not redrawn at all while it is closed.
- The menu bar item is redrawn only when its text changes.

## Limits

- **Temperature and fan speed are optional and off by default.** macOS has no public API for them on Apple Silicon, so CoreGlance reads them through undocumented interfaces (the HID temperature sensors and the SMC). They may be missing on some Macs or stop working after a macOS update; the official thermal state is always shown. The temperature is the hottest sensor on the chip.
- **Top processes lists your own processes only.** System processes such as WindowServer need administrator rights, which CoreGlance never asks for.
- **Network speed is measured on the interface that carries your internet connection** (Wi-Fi, Ethernet, tethering or a full VPN). Other interfaces are ignored, and it reads zero when offline. Transfers to devices on the same local network use that same interface, so they are included.
- **Not on the Mac App Store.** The App Store sandbox blocks the process list.

## Development

```bash
swift build          # compile
swift test           # run the tests (needs Xcode, not just the Command Line Tools)
./build.sh           # build build/CoreGlance.app
./build.sh zip       # also create a zip for a release
swift scripts/make-icon.swift   # regenerate the app icon

# Draw the popup to a PNG without clicking the menu bar (handy for checking layout changes):
COREGLANCE_SNAPSHOT=/tmp/popup.png build/CoreGlance.app/Contents/MacOS/CoreGlance
```

| File | Purpose |
|---|---|
| `Sources/CoreGlance/Sensors.swift` | Reads the system (Mach, IOKit, sysctl) |
| `Sources/CoreGlance/Thermals.swift` | Optional temperature and fan readings (undocumented interfaces) |
| `Sources/CoreGlance/Core.swift` | Pure calculations and formatting, covered by tests |
| `Sources/CoreGlance/Monitor.swift` | The sampling timer, menu bar image and alerts |
| `Sources/CoreGlance/Views.swift` | The popup interface |
| `Sources/CoreGlance/App.swift` | App entry point and menu bar item |

To publish a release, push a tag such as `v1.0.0`. The GitHub Action builds the app and attaches the zip to a new release. It then updates the Homebrew cask in [homebrew-tap](https://github.com/amritadasbijoy/homebrew-tap) by itself. If that step ever fails, run the "Update Homebrew cask" workflow by hand from the Actions tab.

## Author

Developed by **Amrita Chandra Das** · [amrita.bd](https://amrita.bd) · [techistbd.com](https://techistbd.com)

## License

[MIT](LICENSE)
