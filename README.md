# screen-transit

> **Bluetooth-triggered monitor input switcher for macOS** -- a tiny Swift daemon that watches for Bluetooth connect/disconnect events and automatically sends DDC/CI commands to switch external display inputs.

## Table of Contents
- [What It Does](#what-it-does)
- [Why](#why)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Development](#development)

---

## What It Does

When a Bluetooth device you care about (e.g. a keyboard or headset) connects or disconnects, **screen-transit** sends a DDC/CI *input-source* command to one or more external monitors. You define rules in a YAML config that map a device MAC + event to a monitor + input code.

Written in pure Swift using only macOS system frameworks (`IOBluetooth`, `IOKit`) with zero external dependencies. Designed to run as a background agent via `launchd`.

---

## Why

If you dock a laptop and want your monitor to automatically switch to the right input when a Bluetooth peripheral appears (or disappears), this tool handles it.

Useful for:

- **Docking stations** with multiple monitor inputs -- switch input when a keyboard connects.
- **Shared displays** -- automatically switch from a TV's built-in source to your Mac.
- **Multi-machine setups** -- pair different inputs with different Bluetooth devices.

---

## Features

| Feature | Description |
|---|---|
| Bluetooth event watching | `IOBluetooth` connect/disconnect notifications, filtered by MAC address |
| DDC/CI output | Raw `VCP 0x60` commands via `IOAVService` -- no external tools needed |
| Configurable rules | YAML config maps device + event to monitor + input |
| Delay support | Optional delay before sending the command to allow monitors to wake |
| Debug logging | Verbose output with `--debug` |
| Self-contained | Single executable, no external dependencies |
| Launchd / Homebrew services | Run as a background agent via `launchd` or `brew services` |

---

## Prerequisites

- macOS **12+** (Monterey or later) on **Apple Silicon**. The DDC/CI implementation uses `IOAVService`, which is only available on Apple Silicon Macs.
- DDC/CI enabled on the monitor (most modern monitors enable it by default).
- **Recommended:** [m1ddc](https://github.com/waydabber/m1ddc) for discovering display numbers and input codes:
  ```bash
  brew install m1ddc
  m1ddc display list
  m1ddc get input <display-number>
  ```

---

## Installation

### Homebrew (recommended)

```bash
brew install airiclenz/tap/screen-transit
```

To run as a background service:

```bash
brew services start screen-transit
```

### deploy.sh

The included `deploy.sh` script builds from source, installs the binary to `/usr/local/bin`, creates a default config if none exists, and sets up a `launchd` agent:

```bash
git clone https://github.com/airiclenz/screen-transit.git
cd screen-transit
./deploy.sh
```

### Manual

```bash
git clone https://github.com/airiclenz/screen-transit.git
cd screen-transit
./build.sh
sudo cp .build/release/screen-transit /usr/local/bin/
```

Then set up the config and launchd agent yourself (see below).

---

## Configuration

Create `~/.config/screen-transit/config.yaml`:

```yaml
# Seconds to wait before sending DDC/CI command after the trigger event.
# Increase if your monitor needs more time to wake. Default: 1.0
delay: 1.0

rules:
  - name: "Keyboard connect -> DisplayPort"
    source: bluetooth
    device_id: "AA:BB:CC:DD:EE:FF"
    display: 1
    input: 15
    trigger: connect

  - name: "Keyboard disconnect -> USB-C"
    source: bluetooth
    device_id: "AA:BB:CC:DD:EE:FF"
    display: 1
    input: 17
    trigger: disconnect
```

### Finding your values

| Value | How to find it |
|---|---|
| Device MAC | `blueutil --paired` or `system_profiler SPBluetoothDataType` |
| Display number | `m1ddc display list` |
| Input code | Switch input via the monitor OSD, then run `m1ddc get input <display>` |

### Common DDC/CI input codes (VCP 0x60)

| Code | Input |
|---|---|
| 15 | DisplayPort-1 |
| 16 | DisplayPort-2 |
| 17 | USB-C |
| 4 | HDMI-1 |
| 5 | HDMI-2 |

These vary by monitor -- always verify with `m1ddc`.

### Config fields

| Field | Type | Required | Description |
|---|---|---|---|
| `delay` | Double | No | Seconds to wait before sending the DDC/CI command (default: 1.0) |
| `rules` | Array | Yes | One or more switch rules |
| `rules[].name` | String | Yes | Human-readable label (used in logs) |
| `rules[].source` | String | No | Event source type (default: `bluetooth`) |
| `rules[].device_id` | String | Yes | MAC address (`AA:BB:CC:DD:EE:FF` or `aa-bb-cc-dd-ee-ff`) |
| `rules[].display` | Int | Yes | Display number from `m1ddc display list` |
| `rules[].input` | Int | Yes | DDC/CI VCP 0x60 input code |
| `rules[].trigger` | String | Yes | `connect` or `disconnect` |

### Reloading after config changes

```bash
# If using brew services:
brew services restart screen-transit

# If using launchd directly:
launchctl kickstart -k gui/$(id -u)/com.screen-transit.agent
```

---

## Usage

```
screen-transit                Run as daemon
screen-transit --debug        Run with verbose logging
screen-transit --list-displays  Show detected external displays
screen-transit --test D I     Test DDC/CI switch: display D, input I
screen-transit --version      Print version
screen-transit --help         Show help
```

When run without flags, it loads the config, registers for Bluetooth events, and keeps a run loop alive. On a matching event it waits `delay` seconds and sends the DDC/CI command.

---

## Development

```bash
git clone https://github.com/airiclenz/screen-transit.git
cd screen-transit
swift build
swift run screen-transit --debug
```

Version is managed via the `VERSION` file at the project root. `build.sh` and `deploy.sh` inject it into `Sources/screen-transit/Version.swift` at build time.
