
# screen-transit — Technical Design

**Bluetooth-triggered monitor input switcher for macOS (Apple Silicon)**

A lightweight Swift CLI daemon that watches Bluetooth device connect/disconnect events via `IOBluetooth` and sends DDC/CI input-switch commands directly to external displays via IOKit. Runs as a launchd user agent with no GUI and no external runtime dependencies.

This document describes the architecture and the non-obvious decisions behind it. The source under `Sources/screen-transit/` is the authoritative reference for implementation detail.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  main.swift                                                  │
│  • parses flags (--init, --doctor, --debug, --test, ...)     │
│  • loads config, wires the orchestrator, runs RunLoop.main   │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  SwitchOrchestrator                                          │
│  • EventSourceDelegate — accepts (source, device, trigger)   │
│  • matches event against config rules                        │
│  • debounces (per rule, DispatchWorkItem cancellable)        │
│  • dispatches to DDCService after config.delay               │
└──────────────────────────────────────────────────────────────┘
        ▲                                            │
        │                                            ▼
┌──────────────────────────┐         ┌──────────────────────────┐
│  BluetoothEventSource    │         │  DDCService              │
│  (EventSource impl)      │         │  • DCPAVServiceProxy     │
│  • connect notification  │         │    enumeration           │
│    (IOBluetooth)         │         │  • IOAVServiceCreate     │
│  • disconnect via 1 s    │         │  • IOAVServiceWriteI2C   │
│    isConnected() poll    │         │    (retried, m1ddc-style)│
│  • MAC normalisation     │         │  • VCP 0x60 set/get      │
└──────────────────────────┘         └──────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  ConfigLoader  →  ScreenTransitConfig { delay, [SwitchRule]} │
│  • reads ~/.config/screen-transit/config.yaml                │
│  • hand-rolled YAML parser (no SPM dependencies)             │
│  • validates required fields; logs and aborts on error       │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Out-of-band utilities (not part of the run loop)            │
│  • InitService     — --init / --init --reset                 │
│  • DoctorService   — --doctor install-conflict report        │
│  • MACAddress      — normalisation + validation              │
│  • Logger          — timestamped stderr/dated file logging   │
└──────────────────────────────────────────────────────────────┘
```

### Runtime flow (daemon mode)

1. Load and validate config.
2. Construct a `DDCService` and a `SwitchOrchestrator`.
3. Construct a `BluetoothEventSource` seeded with the set of MACs that any `trigger: disconnect` rule references; attach it to the orchestrator.
4. The event source:
   - Registers a class-level `IOBluetoothDevice` connect notification (fires reliably for new connections, and synchronously replays already-connected devices on registration).
   - If at least one disconnect rule exists, schedules a 1 s `Timer` that polls `IOBluetoothDevice.pairedDevices()` and detects `true → false` transitions of `isConnected()` per watched MAC.
5. On every connect or synthesised disconnect, the orchestrator filters config rules by `(source, device, trigger)` and schedules each matching rule for execution after `config.delay`. Re-firing the same rule cancels the previous pending work item (reconnection-storm debounce).
6. `DDCService.setInput` reads VCP 0x60 first; if the low byte already matches the requested input, it skips the write. Otherwise it writes the VCP Set Feature packet over I2C, repeating the write twice with a 10 ms gap to match m1ddc — many monitors silently drop a single write.
7. `RunLoop.main.run()` keeps the process alive.

### Why disconnects are polled instead of `register(forDisconnectNotification:)`

`IOBluetoothDevice`'s per-device disconnect notification is unreliable for multi-host Bluetooth keyboards (e.g. Logitech MX Keys S). When the keyboard's channel selector switches to another host, the host (this Mac) sees the connection drop in `IOBluetoothDevice.isConnected()` and in `system_profiler SPBluetoothDataType`, but `register(forDisconnectNotification:)` does not fire its callback. Polling `isConnected()` at 1 Hz produces the same observable behaviour for every device we tested, including ones where the notification API would have worked, with no measurable CPU cost.

## Prerequisites

- macOS 12+ on Apple Silicon. The DDC/CI implementation uses `IOAVService`, which is only available on Apple Silicon Macs.
- DDC/CI enabled on the monitor (usually on by default).
- `m1ddc` recommended for one-time discovery of display indices and input codes (`brew install m1ddc`). It is **not** a runtime dependency.

## Configuration

**Location:** `~/.config/screen-transit/config.yaml`

```yaml
# Seconds to wait before executing a DDC/CI command after the trigger
# event. Increase if your monitor needs more time to wake. Default: 1.0.
delay: 1.0

rules:
  - name: "Keyboard connect → DisplayPort"
    source: bluetooth                 # optional; defaults to "bluetooth"
    device_id: "AA:BB:CC:DD:EE:FF"    # MAC; case- and separator-insensitive
    display: 1                        # 1-based; see `m1ddc display list`
    input: 15                         # DDC/CI VCP 0x60 code (0–255)
    trigger: connect                  # "connect" or "disconnect"

  - name: "Keyboard disconnect → USB-C"
    source: bluetooth
    device_id: "AA:BB:CC:DD:EE:FF"
    display: 1
    input: 27
    trigger: disconnect
```

### Config fields

| Field | Type | Required | Description |
|---|---|---|---|
| `delay` | Double | No | Seconds to wait before sending the command. Default `1.0`; clamped to `[0.0, 30.0]`. |
| `rules` | Array | No | Switch rules. An empty/absent list logs `Config contains no rules — running idle`; the daemon stays up but never acts. |
| `rules[].name` | String | Yes | Human-readable label, used in log output. |
| `rules[].source` | String | No | Event source type. Default `"bluetooth"`. The orchestrator matches rules by this value against the source's `sourceType`. |
| `rules[].device_id` | String | Yes | Source-specific identifier. For Bluetooth: a MAC (`AA:BB:CC:DD:EE:FF` or `aa-bb-cc-dd-ee-ff`), normalised to uppercase colon-separated. The legacy key `bluetooth_mac` is still accepted. |
| `rules[].display` | Int | Yes | Display number as reported by `m1ddc display list` (1-based). Must be > 0. |
| `rules[].input` | Int | Yes | DDC/CI VCP 0x60 input source code. Must be in `0–255`. |
| `rules[].trigger` | String | Yes | `"connect"` or `"disconnect"`. |

The YAML parser is hand-rolled (line-based, indentation-aware, supports `#` comments and `"..."` quoting). Avoid YAML features beyond what the example uses — no anchors, no multi-line strings, no nested rule arrays.

## Project Structure

```
screen-transit/
├── Package.swift
├── VERSION
├── build.sh                          # writes Version.swift, swift build -c release
├── deploy.sh                         # source install path
├── uninstall.sh                      # remove binary, plist, optional config/cert
├── screen-transit-signing.sh         # create cert (if missing) and codesign binary
├── launchd/
│   └── com.screen-transit.agent.plist  # template for deploy.sh installs
├── config/
│   └── ...                           # example configs (not packaged)
└── Sources/
    └── screen-transit/
        ├── main.swift                  # CLI dispatch + run-loop entry
        ├── Version.swift               # generated, holds appVersion
        ├── Config.swift                # ScreenTransitConfig + ConfigLoader
        ├── EventSource.swift           # protocol + Trigger enum + delegate
        ├── BluetoothEventSource.swift  # IOBluetooth source (connect + poll)
        ├── SwitchOrchestrator.swift    # event → rule matching + debouncing
        ├── DDCService.swift            # DCPAVServiceProxy + IOAVService I2C
        ├── MACAddress.swift            # normalise() / isValid()
        ├── Logger.swift                # timestamped stderr + dated file log
        ├── InitService.swift           # --init / --init --reset
        └── DoctorService.swift         # --doctor
```

`Package.swift` is minimal:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "screen-transit",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "screen-transit",
            path: "Sources/screen-transit",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
```

No SPM dependencies. YAML parsing is in-tree. DDC/CI is native via IOKit.

## Module Details

### Config.swift

`ScreenTransitConfig` and `SwitchRule` are plain structs. `ConfigLoader.load(from:)` reads the file, hands it to `parse(_:)`, which streams lines and accumulates rule dictionaries on indentation transitions. Each completed rule dictionary is run through `buildRule(from:)`, which:

- requires `name`, `device_id` (or legacy `bluetooth_mac`), `display`, `input`, `trigger`,
- defaults `source` to `"bluetooth"`,
- enforces `display > 0` and `0 ≤ input ≤ 255`,
- normalises the MAC via `MACAddress.normalise` and (when `source == "bluetooth"`) validates the format,
- returns `nil` and logs a descriptive error if anything fails.

A `nil` from any rule short-circuits parsing back to the loader, which then surfaces the failure to `main.swift` to `exit(1)`.

### EventSource.swift

The orchestrator talks to event producers through one protocol so adding a new source (e.g. USB, network) doesn't change the orchestrator:

```swift
enum Trigger: String { case connect, disconnect }

protocol EventSourceDelegate: AnyObject {
    func eventSource(_ source: EventSource,
                     didDetect trigger: SwitchRule.Trigger,
                     forDevice identifier: String)
}

protocol EventSource: AnyObject {
    var sourceType: String { get }       // matches SwitchRule.source
    var delegate: EventSourceDelegate? { get set }
    func start()
}
```

### BluetoothEventSource.swift

Implements `EventSource` with `sourceType = "bluetooth"`. Responsibilities:

- On `start()`:
  - Register class-level connect notification via `IOBluetoothDevice.register(forConnectNotifications:selector:)`. Apple's API replays already-connected devices synchronously into the selector during this call, so we see the current Bluetooth fleet immediately.
  - If `disconnectIdentifiers` (the set of MACs referenced by `trigger: disconnect` rules) is non-empty, seed `lastConnectedState` from current `isConnected()` values and start a 1 s `Timer.scheduledTimer`.
- On a connect callback: normalise the device's MAC, log it, forward to the delegate, and update `lastConnectedState[identifier] = true` if the device is in `disconnectIdentifiers` (so a fresh connect doesn't get misread as a stale disconnect by the next poll).
- On every poll tick: for each watched identifier, look up the matching paired device, read `isConnected()`, and synthesise a `disconnect` delegate call on a `true → false` transition.

The class is kept alive by a strong reference in `main.swift`. `IOBluetoothUserNotification` requires the registrant to outlive the registration; if `BluetoothEventSource` were deallocated, notifications would silently stop.

### SwitchOrchestrator.swift

Owns the config and the set of event sources. Implements `EventSourceDelegate`:

- For each incoming `(source, trigger, identifier)`, scans `config.rules` and computes `rule.source == source.sourceType && rule.deviceIdentifier == identifier && rule.trigger == trigger`. All matching rules are scheduled.
- `scheduleSwitch(rule:)` cancels any pending `DispatchWorkItem` keyed by `rule.name`, then schedules a new one on the main queue with `deadline: .now() + config.delay`. The work item calls `DDCService.setInput(display:inputCode:)` and logs the outcome. Cancellation gives reconnection-storm protection: a disconnect immediately followed by a reconnect within the delay window collapses to a single net action (the latest one).

### DDCService.swift

Apple Silicon exposes display I2C through the private but stable `IOAVService` (resolved via `dlsym(RTLD_DEFAULT, "IOAVServiceCreate")` etc., the same approach m1ddc uses). The path is:

```
IOServiceMatching("DCPAVServiceProxy")  →  io_service_t (1-based index)
  →  IOAVServiceCreate                  →  AnyObject (IOAVService handle)
    →  IOAVServiceWriteI2C / ReadI2C   →  raw DDC/CI frames at chip 0x37
```

**Set VCP Feature (write).** Build the 6-byte frame `[0x84, 0x03, 0x60, valueHi, valueLo, checksum]`, where the checksum is `0x6E ^ 0x51 ^ length ^ 0x03 ^ 0x60 ^ valueHi ^ valueLo`. Submit via `IOAVServiceWriteI2C(handle, 0x37, 0x51, &data, 6)`. The submission is wrapped in a **retry loop of two iterations with `usleep(10_000)` before each call** — without this, some monitors (notably the Dell U3423WE we tested against) report a successful I2C write but never act on the VCP change. This matches m1ddc's `DDC_ITERATIONS` / `DDC_WAIT` pattern.

**Get VCP Feature (read).** Send the 4-byte read request `[0x82, 0x01, 0x60, checksum]` where the checksum is `0x6E ^ length ^ 0x01 ^ 0x60` (note: source address `0x51` is *excluded* from the read-request checksum; m1ddc and the spec agree on this). Sleep 50 ms (DDC/CI spec minimum is 40 ms), then `IOAVServiceReadI2C` 11 bytes from chip 0x37 sub 0x50. Validate the reply: `reply[0] == 0x6E`, `reply[2] == 0x02`, `reply[3] == 0x00`, `reply[4] == 0x60`, and the XOR-cumulative checksum at `reply[10]` matches.

**Reply parsing for `setInput` early-return.** VCP 0x60 is documented as 16-bit big-endian, but in practice it's effectively single-byte. Some monitors (Dell U3423WE again) populate `curHi` with a duplicate of `curLo`, so a naive `(curHi << 8) | curLo` never equals the requested input code. The "already on input X" optimisation therefore compares only `current & 0xFF` against `inputCode`.

**No code signing or entitlements are needed for IOKit I2C access.** The code-signing layer described elsewhere in this document exists solely so that macOS TCC remembers the Bluetooth permission grant across upgrades — see [Code signing](#code-signing).

### MACAddress.swift

`MACAddress.normalise(_:)` uppercases and replaces `-` separators with `:`. `MACAddress.isValid(_:)` checks the post-normalisation shape (`XX:XX:XX:XX:XX:XX`, hex only). Used by `ConfigLoader` and `BluetoothEventSource` so that user-supplied and OS-supplied MACs compare equal regardless of original formatting.

### Logger.swift

`Log.debug` / `Log.info` / `Log.error` write ISO-8601-timestamped lines to **both** stderr (visible via `launchctl print … stderr path`) and `~/Library/Logs/screen-transit/YYYY-MM-DD.log` (rotated daily by filename, never trimmed). `Log.isDebugEnabled` is set from `--debug` and suppresses `debug` lines when false.

### InitService.swift

Drives `--init` / `--init --reset`. On `--init`:

1. If `~/.config/screen-transit/config.yaml` does not exist, write the template config (commented placeholders) to it. Existing configs are left untouched.
2. Locate the signing script as a sibling of the running executable (works for both the brew install at `/opt/homebrew/opt/screen-transit/bin/` and the source install at `/usr/local/bin/`).
3. If no `Screen Transit Local` identity exists in the keychain — or `--reset` was passed — prompt for the login keychain password via `/dev/tty` (echo off), then `Process`-exec the signing script with `ST_KEYCHAIN_PASS` and (for reset) `ST_RESET=1` in the environment. The script handles cert creation and binary signing.

`--init --reset` is the recovery path for users whose cert was created by an older script version that lacked `set-key-partition-list`, which triggers a "codesign wants to access key" popup on every `brew upgrade`.

### DoctorService.swift

Reports detectable conflicts that produce "screen-transit is broken" symptoms with no obvious root cause — most notably the dual-daemon situation where a Homebrew install and a `deploy.sh` install are both registered with launchd under different labels. Pure read-only; never modifies state. Run after surprising behaviour and before re-installing.

## Code signing

`screen-transit-signing.sh` creates a local self-signed code-signing identity called `Screen Transit Local` in the user's login keychain on first run, then signs the binary with it. Subsequent runs reuse the same identity. The script:

- Counts identities matching the CN; if exactly one exists, signs and exits.
- If more than one exists (legacy duplicate-cert state), purges and recreates a clean one — `codesign -s "Screen Transit Local"` would otherwise fail with `ambiguous`.
- Imports the cert with `-A` (any-app ACL) and sets the keychain partition list to `apple-tool:,apple:,codesign:` so that codesign can use the key non-interactively.
- Hash-pins the signing identity (`security find-identity ... | awk '{print $2}'`) before calling `codesign -s <hash>`, again to avoid `ambiguous` errors.

The identity is local — different on every user's machine. That is intentional: TCC keys Bluetooth permission by the signing identity's hash, so each user grants once and the grant persists across upgrades as long as the same identity continues to sign the binary. There is no shared distribution certificate; this is a deliberate choice to avoid the Apple Developer Program fee. The trade-off is a one-time per-machine keychain password prompt during `--init`.

If a user reports a "codesign wants to access key" popup at `brew upgrade` time, the recovery is `screen-transit --init --reset`, which purges the old cert and creates a fresh one with the partition list set correctly.

## launchd

### Homebrew install

The formula's `post_install` writes `~/Library/LaunchAgents/homebrew.mxcl.screen-transit.plist`. Start/stop via `brew services start screen-transit` or directly:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/homebrew.mxcl.screen-transit.plist
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.screen-transit
```

Logs land at `/opt/homebrew/var/log/screen-transit/stderr.log` (and the dated `~/Library/Logs/screen-transit/YYYY-MM-DD.log` via the application logger).

### deploy.sh install

`launchd/com.screen-transit.agent.plist` is copied into `~/Library/LaunchAgents/`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>com.screen-transit.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/screen-transit</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
```

`deploy.sh` refuses to run when a Homebrew install is detected — the two register under different labels and would otherwise run concurrently, racing on every Bluetooth event. To switch installations, uninstall one before installing the other.

## Build, Install, Run

```bash
# Build (writes Version.swift from VERSION first)
./build.sh

# Source install
./deploy.sh

# Homebrew install
brew install airiclenz/tap/screen-transit
screen-transit --init
brew services start screen-transit

# Verify
launchctl list | grep screen-transit
tail -f ~/Library/Logs/screen-transit/$(date +%Y-%m-%d).log

# Reload after config change (brew install)
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.screen-transit

# Uninstall (source install)
./uninstall.sh
```

## Discovery: Finding Your Values

`m1ddc` is used for one-time discovery, not at runtime:

```bash
brew install m1ddc

# Bluetooth MAC
system_profiler SPBluetoothDataType
# or: blueutil --paired

# Display number
m1ddc display list

# Input codes — switch the monitor's input via OSD, then read:
m1ddc get input
```

Common DDC/CI input codes for VCP 0x60 (vary by manufacturer — always verify):

| Code | Typical mapping |
|---|---|
| 1 | VGA-1 |
| 3 | DVI-1 |
| 4 | HDMI-1 |
| 5 | HDMI-2 |
| 15 | DisplayPort-1 |
| 16 | DisplayPort-2 |
| 17 | USB-C (DP Alt Mode, often) |

## DDC/CI: Inactive Input Behaviour

Monitors with DDC/CI process commands on **all physically connected ports**, not just the active input. This means:

- ✅ You can switch a monitor *to* your Mac even when it's currently showing another source.
- ✅ Disconnect triggers work: when the BT keyboard leaves Mac A, Mac A can still tell the monitor to switch to Mac B's input.
- ⚠️ Some monitors with buggy DDC/CI may only respond on the active input — test yours with `m1ddc set input <code>` while viewing a different input. If m1ddc can do it, screen-transit can too.

## Edge Cases and Considerations

**Reconnection storms.** Bluetooth devices sometimes flap (rapid disconnect/reconnect) during wake or at range boundaries. The `config.delay` plus per-rule `DispatchWorkItem` cancellation handles this — if the opposite event fires within the delay window, the pending switch is cancelled and only the newer rule runs.

**Multi-host keyboards.** Keyboards like the Logitech MX Keys S keep three host bonds warm; switching channels causes the OS to see a real disconnect (`system_profiler` shows `Connected: No`) but `IOBluetooth`'s disconnect notification does not fire. The 1 s polling loop in `BluetoothEventSource` is the workaround. Latency is ≤ 1 s, well under `config.delay`'s default of 1 s, so practical effect on rule firing is nil.

**Single-write monitor drops.** Some monitors silently ignore single DDC/CI writes. `DDCService.writeI2C` repeats writes twice with 10 ms spacing (matching m1ddc) to compensate. If you encounter a monitor that still drops writes, the right fix is to increase `DDC_ITERATIONS` / `DDC_WAIT` in `writeI2C`, not to add a sleep around `setInput`.

**False-positive `setInput` success.** `IOAVServiceWriteI2C` returns `kIOReturnSuccess` when the I2C transaction completes at the bus level, not when the monitor *acts on* the command. `--test` and the daemon both report "success" on this basis. If a write succeeds but the monitor doesn't switch, cross-check with `m1ddc set input <code>` — they share the same code path semantically, so divergent behaviour points at our DDC code rather than the hardware.

**IOAVService stability.** `IOAVServiceCreate` / `WriteI2C` / `ReadI2C` are private undocumented APIs resolved at runtime via `dlsym`. They have been stable from macOS 12 through 15. If Apple changes them, every DDC/CI tool on the platform (m1ddc, BetterDisplay, etc.) breaks the same way and screen-transit follows whichever fix m1ddc lands.

**Display hot-plug.** If a display is disconnected and reconnected, its index from `m1ddc display list` may change. For setups with multiple external displays, verify display numbering after any cable changes.

**Code signing per machine.** The `Screen Transit Local` identity is local to each user's keychain (see [Code signing](#code-signing)). One-time keychain password prompt during `--init` is the only friction. Cert deletion is supported in `uninstall.sh`.

**Config reload.** For the current version, restart the agent after config changes (`launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.screen-transit`). A `DispatchSource.makeFileSystemObjectSource`-based watcher is listed in Future Enhancements.

## Future Enhancements

- **Config file watcher** — auto-reload via `DispatchSource.makeFileSystemObjectSource`.
- **Display matching by serial/model** — more stable than index for multi-monitor setups.
- **Verified switch outcome** — after writing VCP 0x60, read it back and downgrade the "Input switch successful" log to "switch attempted; monitor did not confirm" on mismatch. Today's "success" log only attests to I2C bus completion.
- **Status command** — `screen-transit --status` to show loaded rules and current connection/input state.
- **Dry-run mode** — `screen-transit --dry-run` to log what would happen without sending DDC/CI commands.
- **Additional event sources** — USB, network presence, calendar, time-of-day — all would slot in behind the existing `EventSource` protocol.
