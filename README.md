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
| Bluetooth event watching | `IOBluetooth` connect notifications + 1 s `isConnected()` polling for disconnect (reliable across multi-host keyboards like Logitech MX Keys S) |
| DDC/CI output | Raw `VCP 0x60` commands via `IOAVService`, with m1ddc-compatible write retry for monitors that drop single writes |
| Configurable rules | YAML config maps device + event to monitor + input |
| Delay support | Optional delay before sending the command to allow monitors to wake |
| Debug logging | Verbose output with `--debug` |
| Self-contained | Single executable, no external dependencies |
| Launchd / Homebrew services | Run as a background agent via `launchd` or `brew services` |
| Self-signed code signing | Local cert created on first run so macOS Bluetooth permission persists across upgrades |

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
screen-transit --init
brew services start screen-transit
```

`--init` writes the default config to `~/.config/screen-transit/config.yaml` (if absent) and runs the signing script, which creates a self-signed `Screen Transit Local` code-signing certificate in your login keychain on first run. That stable identity is what macOS keys the Bluetooth permission to, so the permission persists across `brew upgrade`. If you ever see a "codesign wants to access key" popup after an upgrade, run `screen-transit --init --reset` to purge and recreate the cert cleanly.

To diagnose installation conflicts (e.g. a `deploy.sh` install left over from development), run `screen-transit --doctor`.

### deploy.sh (source install)

`deploy.sh` builds from source, installs the binary to `/usr/local/bin`, creates a default config if missing, and sets up a `launchd` agent under the label `com.screen-transit.agent`:

```bash
git clone https://github.com/airiclenz/screen-transit.git
cd screen-transit
./deploy.sh
```

The script signs the binary with the same `Screen Transit Local` cert (creating it via `screen-transit-signing.sh` on first run). It refuses to run while a Homebrew install of screen-transit is present, since the two would register competing launchd agents under different labels and race on Bluetooth events. To switch from brew to source, run `brew uninstall airiclenz/tap/screen-transit` first.

### Manual

```bash
git clone https://github.com/airiclenz/screen-transit.git
cd screen-transit
./build.sh
sudo cp .build/release/screen-transit /usr/local/bin/
./screen-transit-signing.sh /usr/local/bin/screen-transit
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
# Homebrew install (launchd label: homebrew.mxcl.screen-transit):
brew services restart screen-transit
# or equivalently:
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.screen-transit

# deploy.sh install (launchd label: com.screen-transit.agent):
launchctl kickstart -k gui/$(id -u)/com.screen-transit.agent
```

---

## Usage

```
screen-transit                  Run as daemon
screen-transit --debug          Run with verbose logging
screen-transit --list-displays  Show detected external displays
screen-transit --test D I       Test DDC/CI switch: display D, input I
screen-transit --init           First-time setup: create default config
                                and sign the binary (run once after brew install)
screen-transit --init --reset   Like --init but purges any existing signing cert
                                first — use to recover from a stale cert that
                                triggers a codesign popup on every brew upgrade
screen-transit --doctor         Diagnose install conflicts
screen-transit --version        Print version
screen-transit --help           Show help
```

When run without flags, it loads the config, registers for Bluetooth connect notifications, starts a 1-second `isConnected()` poll for any device referenced by a disconnect rule, and keeps a run loop alive. On a matching event it waits `delay` seconds and sends the DDC/CI command.

---

## Development

```bash
git clone https://github.com/airiclenz/screen-transit.git
cd screen-transit
swift build
swift run screen-transit --debug
```

Version is managed via the `VERSION` file at the project root. `build.sh` and `deploy.sh` inject it into `Sources/screen-transit/Version.swift` at build time.
