# screen‑transit

> **Bluetooth‑triggered monitor input switcher for macOS** – a tiny Swift CLI daemon that watches for Bluetooth device connect/disconnect events and automatically sends DDC/CI commands to switch external displays.


## Table of Contents
- [What It Does](#what-it-does)
- [Why](#why)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Running as a Launchd Agent](#running-as-a-launchd-agent)
- [Development](#development)
- [License](#license)
- [Acknowledgements](#acknowledgements)

---

## What It Does
When a Bluetooth device you care about (e.g. a keyboard or headset) connects or disconnects, **screen‑transit** sends a DDC/CI *input‑source* command to one or more external monitors. The command can be sent on either the *connect* or *disconnect* event, and you can specify which monitor and which input source code to switch to.

The program is written in pure Swift, uses only macOS system frameworks (`IOBluetooth`, `IOKit`), and has no external dependencies. It is designed to run as a background agent via `launchd`.

---

## Why
If you have multiple displays and a Bluetooth device that you want to control what the monitor shows (e.g. a keyboard that, when plugged in, should automatically switch to the “USB‑C” input), this tool automates that.

It is useful for:

- Laptop docking stations that have multiple monitor inputs.
- Switching from a TV’s built‑in source to a Mac when you bring a keyboard close.
- Ensuring a monitor always displays the desired input when a peripheral is connected.

---

## Features
| Feature | Description |
|---------|-------------|
| **Bluetooth event watching** | Uses `IOBluetooth` to receive connect/disconnect notifications for all devices; filters by MAC address. |
| **DDC/CI output** | Sends raw DDC/CI `VCP 0x60` commands via `IOAVService` – no external tools needed. |
| **Configurable rules** | YAML file (`~/.config/screen-transit/config.yaml`) lets you map device‑MAC + event → monitor + input. |
| **Delay support** | Optional delay before the command to allow monitors to wake. |
| **Debug logging** | Verbose output to `stderr` when `--debug` is supplied. |
| **Self‑contained Swift CLI** | Builds into a single executable with no external binaries. |
| **Launchd integration** | Example plist in `launchd/` for user‑level background execution. |

---

## Prerequisites
- macOS **12+** (Monterey or later) on **Apple Silicon**. The DDC/CI implementation uses `IOAVService`, a private framework only available on Apple Silicon.
- DDC/CI enabled on the monitor (most modern monitors enable it by default).
- (Optional) `m1ddc` for initial discovery of display IDs and input codes:
  ```bash
  brew install m1ddc
  m1ddc display list
  m1ddc get input <display-number>
  ```

---

## Installation
```
git clone https://github.com/yourname/screen-transit.git
cd screen-transit
swift build -c release
sudo cp .build/release/screen-transit /usr/local/bin
```

The executable is now available as `screen-transit`. The default configuration file is `~/.config/screen-transit/config.yaml`; create it before first run.

---

## Configuration
Create the YAML file at `~/.config/screen-transit/config.yaml`:

```yaml
# screen-transit configuration
# Seconds to wait before sending DDC/CI command after the BT event.
# Some monitors need a moment after wake. Default: 1.0
delay: 1.0

rules:
  - name: "Keychron K3 → Work setup"
    bluetooth_mac: "AA:BB:CC:DD:EE:FF"
    display: 1                # display number from `m1ddc display list`
    input: 15                 # DDC/CI input code (get via `m1ddc get input`)
    trigger: connect          # "connect" or "disconnect"

  - name: "Keychron K3 disconnect → Switch to USB‑C"
    bluetooth_mac: "AA:BB:CC:DD:EE:FF"
    display: 1
    input: 17
    trigger: disconnect
```

### Config fields
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `delay` | Double | No | Seconds to wait before sending command. |
| `rules` | Array | Yes | One or more switch rules |
| `rules[].name` | String | Yes | Human‑readable label |
| `rules[].bluetooth_mac` | String | Yes | MAC address (AA:BB:CC:DD:EE:FF or aa-bb-cc-dd-ee-ff) |
| `rules[].display` | Int | Yes | Display number as reported by `m1ddc display list` |
| `rules[].input` | Int | Yes | DDC/CI VCP 0x60 input code |
| `rules[].trigger` | String | Yes | `connect` or `disconnect` |

---

## Usage
```
# Normal daemon mode (background)
screen-transit

# Debug mode with verbose logging
screen-transit --debug

# List detected external displays
screen-transit --list-displays

# Test a specific switch
screen-transit --test 1 15

# Print version
screen-transit --version

# Show help
screen-transit --help
```

When run normally it will load the config, register for Bluetooth events, and keep a run loop alive. On a matching event it will wait `delay` seconds and send the DDC/CI command.

---

## Running as a Launchd Agent
The repo ships a `launchd` plist that will start `screen-transit` automatically for the current user:

```bash
# Copy the template
cp launchd/com.screen-transit.agent.plist ~/Library/LaunchAgents/

# Load the agent
launchctl load ~/Library/LaunchAgents/com.screen-transit.agent.plist

# To stop it
launchctl unload ~/Library/LaunchAgents/com.screen-transit.agent.plist
```

The plist runs the binary at login and keeps it running as a background process.

---

## Development
```
# Clone the repo
git clone https://github.com/yourname/screen-transit.git
cd screen-transit

# Build (debug)
swift build

# Run with local config
export CONFIG_PATH="$(pwd)/config.yaml"
swift run screen-transit --debug
```

### Running the test suite
The project contains a TDD file (`screen-transit.TDD.md`) documenting the intended behavior. Tests are not auto‑generated, but you can write Swift unit tests under `Tests/` if desired.

---

## License
MIT © 2024

---

## Acknowledgements
- The DDC/CI implementation uses private Apple Silicon frameworks (`IOAVService`); the approach is inspired by open‑source tools like [m1ddc](https://github.com/danielbailey/m1ddc). 
- Thanks to the Swift community for the Swift Package Manager.
