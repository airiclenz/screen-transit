
# ScreenTransit — Technical Design

**Bluetooth-triggered monitor input switcher for macOS (Apple Silicon)**

A lightweight Swift CLI daemon that monitors Bluetooth device connect/disconnect events via `IOBluetooth` and sends DDC/CI input-switch commands directly to external displays via IOKit. Runs as a launchd user agent with no GUI and no external dependencies.

## Architecture

```
┌────────────────────────────┐
│  IOBluetooth Framework     │
│  (event-driven, no poll)   │
├────────────────────────────┤
│  BluetoothWatcher          │
│  • registers for connect   │
│    notifications           │
│  • filters by MAC address  │
│  • on match → fires rule   │
├────────────────────────────┤
│  DDCService                │
│  • IOKit / IOAVService     │
│  • native I2C DDC/CI write │
│  • VCP 0x60 input switch   │
├────────────────────────────┤
│  ConfigLoader              │
│  • reads YAML from         │
│    ~/.config/screentransit/ │
│    config.yaml             │
│  • validates on startup    │
└────────────────────────────┘
```

**Runtime flow:**

1. Load and validate config
2. Register `IOBluetoothDevice` connect notification (class-level observer — fires for *any* device)
3. On connect event: check device MAC against config rules where `trigger: connect`
4. On connect event: also register a per-device disconnect notification for devices matching `trigger: disconnect` rules
5. On match → send DDC/CI input-switch command via IOKit
6. Run `RunLoop.main` indefinitely (daemon)

## Prerequisites

- macOS 12+ on Apple Silicon
- DDC/CI enabled on monitor (usually on by default)
- `m1ddc` recommended for initial **discovery only** — finding display IDs and input codes (`brew install m1ddc`)

## Configuration

**Location:** `~/.config/screentransit/config.yaml`

```yaml
# ScreenTransit configuration
#
# DDC/CI note: monitors listen for DDC/CI commands on ALL connected
# ports regardless of which input is currently active. This means
# you can switch a monitor TO your Mac's input even when it's
# currently showing another source.

# Seconds to wait before sending DDC/CI command after the BT event.
# Some monitors need a moment after wake. Default: 1.0
delay: 1.0

rules:
  - name: "Keychron K3 → Work setup"
    bluetooth_mac: "AA:BB:CC:DD:EE:FF"
    display: 1                # display number from `m1ddc display list`
    input: 15                 # DDC/CI input code (get via `m1ddc get input`)
    trigger: connect          # "connect" or "disconnect"

  - name: "Keychron K3 disconnect → Switch to USB-C"
    bluetooth_mac: "AA:BB:CC:DD:EE:FF"
    display: 1
    input: 17
    trigger: disconnect
```

### Config fields

| Field | Type | Required | Description |
|---|---|---|---|
| `delay` | Double | No | Seconds to wait before sending command. Default `1.0` |
| `rules` | Array | Yes | One or more switch rules |
| `rules[].name` | String | Yes | Human-readable label (used in log output) |
| `rules[].bluetooth_mac` | String | Yes | Target device MAC (`AA:BB:CC:DD:EE:FF` or `aa-bb-cc-dd-ee-ff`, normalised internally) |
| `rules[].display` | Int | Yes | Display number as reported by `m1ddc display list` |
| `rules[].input` | Int | Yes | DDC/CI VCP 0x60 input source code |
| `rules[].trigger` | String | Yes | `"connect"` or `"disconnect"` |

## Project Structure

```
ScreenTransit/
├── Package.swift
├── Sources/
│   └── ScreenTransit/
│       ├── main.swift                # Entry point: load config, start watcher, run loop
│       ├── Config.swift              # YAML parser + Config/Rule models
│       ├── BluetoothWatcher.swift    # IOBluetooth connect/disconnect observer
│       ├── DDCService.swift          # Native DDC/CI via IOKit/IOAVService
│       └── Logger.swift              # Timestamped stderr logging
└── launchd/
    └── com.screentransit.agent.plist # launchd user agent template
```

**SPM Package.swift:**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenTransit",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "screentransit",
            path: "Sources/ScreenTransit",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
```

No external dependencies. YAML parsing is hand-rolled for the flat config structure. DDC/CI is native via IOKit.

## Module Details

### Config.swift

**Responsibilities:**
- Read `~/.config/screentransit/config.yaml`
- Parse YAML manually (line-based: split on `:`, handle array items with `- ` prefix, track indentation for nesting)
- Normalise MAC addresses to uppercase colon-separated format (`AA:BB:CC:DD:EE:FF`)
- Validate: all required fields present, MAC format valid, trigger is `connect` or `disconnect`, input is positive integer

**Models:**

```swift
struct ScreenTransitConfig {
    let delay: Double
    let rules: [SwitchRule]
}

struct SwitchRule {
    let name: String
    let bluetoothMAC: String       // normalised: "AA:BB:CC:DD:EE:FF"
    let display: Int
    let input: Int
    let trigger: Trigger

    enum Trigger: String {
        case connect
        case disconnect
    }
}
```

**Error handling:** Print clear message to stderr and `exit(1)` on invalid config. No silent defaults for required fields.

### DDCService.swift

**Responsibilities:**
- Enumerate external displays via IOKit service matching
- Send DDC/CI write commands over I2C to set VCP code 0x60 (input source)
- No dependency on m1ddc — talks directly to the display controller

**How it works:**

Apple Silicon Macs expose display I2C access through `IOAVService`, a private but stable IOKit service. The path is:

```
IOService → DCPAVServiceProxy → IOAVServiceCreate → IOAVServiceWriteI2C
```

**DDC/CI protocol (write):**

A DDC/CI Set VCP Feature command is a fixed-format I2C message:

```
Destination address: 0x37 (DDC/CI standard)
Message structure:
  [0x51]              - source address (host)
  [0x84]              - length: 4 bytes follow (0x80 | 0x04)
  [0x03]              - opcode: Set VCP Feature
  [VCP code]          - 0x60 for input source
  [value high byte]   - 0x00 for input values < 256
  [value low byte]    - the input code
  [checksum]          - XOR of all preceding bytes including dest addr
```

**Implementation outline:**

```swift
import Foundation
import IOKit

class DDCService {

    // ── Public API ──────────────────────────────────────────────

    /// Set VCP feature on a specific display by index
    func setInput(display: Int, inputCode: Int) -> Bool {
        guard let service = getDisplayService(at: display) else {
            Log.error("Display \(display) not found")
            return false
        }
        defer { IOObjectRelease(service) }

        return writeVCP(service: service,
                        code: 0x60,
                        value: UInt16(inputCode))
    }

    // ── Display Enumeration ─────────────────────────────────────

    /// Find the IOAVService for a display at the given index (1-based)
    private func getDisplayService(at index: Int) -> io_service_t? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("DCPAVServiceProxy")

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var current = io_service_t()
        var count = 0
        while case let s = IOIteratorNext(iterator), s != IO_OBJECT_NULL {
            count += 1
            if count == index {
                current = s
            } else {
                IOObjectRelease(s)
            }
        }
        return count >= index ? current : nil
    }

    // ── DDC/CI I2C Communication ────────────────────────────────

    /// Write a VCP Set Feature command via IOAVService I2C
    private func writeVCP(service: io_service_t,
                          code: UInt8,
                          value: UInt16) -> Bool {

        // Open IOAVService — private API, bridged via dlsym
        guard let avService = openAVService(service: service) else {
            Log.error("Failed to open IOAVService")
            return false
        }

        // Build DDC/CI Set VCP Feature packet
        let destAddr: UInt8 = 0x37
        let srcAddr: UInt8  = 0x51
        let length: UInt8   = 0x84   // 0x80 | 4 payload bytes
        let opcode: UInt8   = 0x03   // Set VCP Feature
        let valueHi         = UInt8(value >> 8)
        let valueLo         = UInt8(value & 0xFF)

        let checksum = destAddr ^ srcAddr ^ length ^ opcode
                       ^ code ^ valueHi ^ valueLo

        var data: [UInt8] = [
            srcAddr, length, opcode,
            code, valueHi, valueLo,
            checksum
        ]

        // Send via I2C at address 0x37
        let result = writeI2C(avService: avService,
                              address: 0x37,
                              data: &data,
                              length: data.count)

        closeAVService(avService)
        return result
    }

    // ── IOAVService Bridging ────────────────────────────────────
    //
    // IOAVServiceCreate, IOAVServiceWriteI2C, and IOAVServiceReadI2C
    // are private C functions in IOKit. Access via dlsym at runtime.
    //
    // Function signatures (from m1ddc / reverse engineering):
    //
    //   IOAVServiceCreate(CFAllocatorRef, io_service_t) -> IOAVServiceRef
    //   IOAVServiceWriteI2C(IOAVServiceRef, UInt32 chipAddr,
    //                       UInt32 dataAddr, UnsafeMutablePointer<UInt8>,
    //                       UInt32 length) -> IOReturn
    //   IOAVServiceReadI2C(IOAVServiceRef, UInt32 chipAddr,
    //                      UInt32 dataAddr, UnsafeMutablePointer<UInt8>,
    //                      UInt32 length) -> IOReturn
    //
    // These are resolved at runtime via dlsym(RTLD_DEFAULT, ...) and
    // cast to the appropriate Swift function types via
    // unsafeBitCast.
    //
    // Reference implementation: github.com/waydabber/m1ddc
    // The IOAVService approach has been stable across macOS 12–15.

    private func openAVService(service: io_service_t) -> AnyObject? {
        // dlsym + IOAVServiceCreate
        // Implementation follows m1ddc's pattern
        typealias CreateFn = @convention(c) (CFAllocator?, io_service_t)
                             -> Unmanaged<CFTypeRef>?

        guard let sym = dlsym(RTLD_DEFAULT, "IOAVServiceCreate") else {
            return nil
        }
        let create = unsafeBitCast(sym, to: CreateFn.self)
        return create(kCFAllocatorDefault, service)?
               .takeRetainedValue()
    }

    private func writeI2C(avService: AnyObject,
                          address: UInt32,
                          data: UnsafeMutablePointer<UInt8>,
                          length: Int) -> Bool {
        // dlsym + IOAVServiceWriteI2C
        typealias WriteFn = @convention(c) (AnyObject, UInt32, UInt32,
                            UnsafeMutablePointer<UInt8>, UInt32)
                            -> IOReturn

        guard let sym = dlsym(RTLD_DEFAULT,
                              "IOAVServiceWriteI2C") else {
            return false
        }
        let write = unsafeBitCast(sym, to: WriteFn.self)
        let result = write(avService, address, 0, data, UInt32(length))
        return result == kIOReturnSuccess
    }

    private func closeAVService(_ avService: AnyObject) {
        // CFTypeRef is reference-counted; releasing the retained
        // reference from openAVService is sufficient.
        // ARC handles this when avService goes out of scope.
    }
}
```

**Important notes:**
- `IOAVServiceCreate`, `IOAVServiceWriteI2C`, `IOAVServiceReadI2C` are **private undocumented APIs** — resolved via `dlsym` at runtime
- These APIs have been stable from macOS 12 through macOS 15 and are the same path m1ddc uses
- No code signing or entitlements required — IOKit I2C access works from unsigned CLI tools
- `DCPAVServiceProxy` is the IOKit class for Apple Silicon display controllers (DCP = Display Controller Processor)
- Display indexing matches what `m1ddc display list` reports (1-based)
- A DDC/CI write does not require the monitor to be showing that input — the I2C bus is always active on connected ports

### BluetoothWatcher.swift

**Responsibilities:**
- Register for global Bluetooth connect notifications via `IOBluetoothDevice.register(forConnectNotifications:selector:)`
- On connect callback:
  - Extract device MAC via `device.addressString`
  - Normalise and compare against all `trigger: connect` rules
  - For devices matching any `trigger: disconnect` rule, call `device.register(forDisconnectNotification:selector:)` to watch for that specific device's disconnect
- On disconnect callback:
  - Match against `trigger: disconnect` rules
  - Fire `DDCService`
- Manage pending `DispatchWorkItem` per rule for reconnection storm protection

**Implementation:**

```swift
import IOBluetooth
import Foundation

class BluetoothWatcher {
    private let config: ScreenTransitConfig
    private let ddc: DDCService
    private var connectNotification: IOBluetoothUserNotification?
    private var pendingWork: [String: DispatchWorkItem] = [:]  // keyed by rule name

    init(config: ScreenTransitConfig, ddc: DDCService) {
        self.config = config
        self.ddc = ddc
    }

    func start() {
        // Class-level: fires for ANY Bluetooth device connecting
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )
        Log.info("Bluetooth watcher registered")
    }

    @objc func deviceDidConnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let mac = normalise(device.addressString)
        Log.info("Device connected: \(mac)")

        // Fire connect rules
        for rule in config.rules where rule.trigger == .connect
                                    && rule.bluetoothMAC == mac {
            scheduleSwitch(rule: rule)
        }

        // Register disconnect watcher for disconnect rules
        let disconnectRules = config.rules.filter {
            $0.trigger == .disconnect && $0.bluetoothMAC == mac
        }
        if !disconnectRules.isEmpty {
            device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDidDisconnect(_:device:))
            )
        }
    }

    @objc func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let mac = normalise(device.addressString)
        Log.info("Device disconnected: \(mac)")

        for rule in config.rules where rule.trigger == .disconnect
                                    && rule.bluetoothMAC == mac {
            scheduleSwitch(rule: rule)
        }
    }

    // ── Reconnection Storm Protection ───────────────────────────
    //
    // BT devices can rapidly disconnect/reconnect during wake or
    // at range boundaries. We delay execution and cancel pending
    // work if the inverse event fires within the delay window.

    private func scheduleSwitch(rule: SwitchRule) {
        // Cancel any pending work for this rule
        pendingWork[rule.name]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Log.info("Executing rule: \(rule.name) → "
                   + "display \(rule.display), input \(rule.input)")
            let success = self.ddc.setInput(
                display: rule.display, inputCode: rule.input
            )
            if success {
                Log.info("Input switch successful")
            } else {
                Log.error("Input switch failed for rule: \(rule.name)")
            }
            self.pendingWork.removeValue(forKey: rule.name)
        }

        pendingWork[rule.name] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + config.delay,
            execute: work
        )
    }

    // ── MAC Address Normalisation ───────────────────────────────

    private func normalise(_ address: String) -> String {
        address
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }
}
```

**Important notes:**
- `IOBluetoothDevice.register(forConnectNotifications:selector:)` is a *class method* — fires for all devices, filtering by MAC is essential
- The disconnect notification is *per-device instance* — registered on the specific `IOBluetoothDevice` received in the connect callback
- `device.addressString` returns format `"aa-bb-cc-dd-ee-ff"` — normalised to `AA:BB:CC:DD:EE:FF`
- `BluetoothWatcher` must be kept alive (strong reference from main); if deallocated, notifications stop
- Reconnection storm protection: each `scheduleSwitch` cancels any pending work item for the same rule name before scheduling a new one

### Logger.swift

Minimal timestamped logging to stderr (visible in `Console.app` under the launchd label and in `/tmp/screentransit.stderr.log`).

```swift
import Foundation

enum Log {
    static func info(_ msg: String)  { log("INFO", msg) }
    static func error(_ msg: String) { log("ERROR", msg) }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func log(_ level: String, _ message: String) {
        let ts = formatter.string(from: Date())
        FileHandle.standardError.write(
            Data("[\(ts)] [\(level)] \(message)\n".utf8)
        )
    }
}
```

### main.swift

```swift
import Foundation

// 1. Load config
let configPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/screentransit/config.yaml")

guard let config = ConfigLoader.load(from: configPath) else {
    Log.error("Failed to load config from \(configPath.path)")
    exit(1)
}

Log.info("ScreenTransit started with \(config.rules.count) rule(s)")
for rule in config.rules {
    Log.info("  Rule: \(rule.name) — \(rule.trigger.rawValue) "
           + "\(rule.bluetoothMAC) → display \(rule.display), "
           + "input \(rule.input)")
}

// 2. Create DDC service and Bluetooth watcher
let ddc = DDCService()
let watcher = BluetoothWatcher(config: config, ddc: ddc)
watcher.start()

// 3. Run forever
Log.info("Watching for Bluetooth events...")
RunLoop.main.run()
```

## launchd User Agent

**File:** `~/Library/LaunchAgents/com.screentransit.agent.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.screentransit.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/screentransit</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/screentransit.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/screentransit.stderr.log</string>
</dict>
</plist>
```

## Build, Install, Run

```bash
# Build
cd ScreenTransit/
swift build -c release

# Install binary
cp .build/release/screentransit /usr/local/bin/screentransit

# Create config directory and edit config
mkdir -p ~/.config/screentransit
nano ~/.config/screentransit/config.yaml

# Install and load launchd agent
cp launchd/com.screentransit.agent.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.screentransit.agent.plist

# Verify
launchctl list | grep screentransit
tail -f /tmp/screentransit.stderr.log

# Reload after rebuild
launchctl kickstart -k gui/$(id -u)/com.screentransit.agent

# Uninstall
launchctl unload ~/Library/LaunchAgents/com.screentransit.agent.plist
rm ~/Library/LaunchAgents/com.screentransit.agent.plist
rm /usr/local/bin/screentransit
```

## Discovery: Finding Your Values

These commands use `m1ddc` as a one-time discovery tool. It is not a runtime dependency.

```bash
# Install m1ddc for discovery
brew install m1ddc

# Find your keyboard's Bluetooth MAC address
blueutil --paired
# or
system_profiler SPBluetoothDataType

# Find your display number
m1ddc display list

# Find input codes: manually switch your monitor to each input
# via the OSD, then read the current value each time
m1ddc get input
# or for a specific display:
m1ddc display 1 get input
```

### Common DDC/CI input codes (VCP 0x60)

These vary by manufacturer — always verify with `m1ddc get input`.

| Code | Typical mapping |
|------|----------------|
| 1 | VGA-1 |
| 3 | DVI-1 |
| 4 | HDMI-1 |
| 5 | HDMI-2 |
| 15 | DisplayPort-1 |
| 16 | DisplayPort-2 |
| 17 | USB-C (often DP Alt Mode) |

## DDC/CI: Inactive Input Behaviour

Monitors with DDC/CI process commands on **all physically connected ports**, not just the active input. This means:

- ✅ You can switch a monitor *to* your Mac even when it's showing another source
- ✅ Disconnect triggers work: when the BT keyboard leaves Mac A, Mac A can still tell the monitor to switch to Mac B's input
- ⚠️ Some monitors with buggy DDC/CI implementations may only respond on the active input — test yours with `m1ddc set input <code>` while viewing a different input

## Edge Cases and Considerations

**Reconnection storms:** Bluetooth devices sometimes rapidly disconnect/reconnect during wake or range issues. The `delay` config plus `DispatchWorkItem` cancellation handles this — if a disconnect is followed by a reconnect within the delay window, the pending switch is cancelled.

**Multiple rules per device:** A device can have both a connect and disconnect rule (common pattern: connect → switch to DP, disconnect → switch to USB-C). These are independent rules with separate work items.

**IOAVService stability:** The `IOAVServiceCreate` / `IOAVServiceWriteI2C` functions are private APIs. They have been stable across macOS 12–15 and are the same path m1ddc uses. If Apple changes these in a future macOS version, ScreenTransit would need updating — but so would every DDC/CI tool on the platform.

**Permissions:** `IOBluetooth` will trigger a Bluetooth permission prompt on first run. The launchd agent handles this — macOS shows the dialog. No entitlements or code signing required for a CLI tool.

**Display hot-plug:** If a display is disconnected and reconnected, its index from `m1ddc display list` may change. For setups with multiple external displays, verify display numbering after any cable changes.

**Config reload:** For v1, restart the agent after config changes (`launchctl kickstart -k gui/$(id -u)/com.screentransit.agent`). Future enhancement: watch the config file with `DispatchSource.makeFileSystemObjectSource`.

## Future Enhancements

- **Config file watcher** — auto-reload on change via `DispatchSource.makeFileSystemObjectSource`
- **Display matching by serial/model** — more stable than index for multi-monitor setups
- **Read VCP** — verify current input before switching (skip if already correct)
- **Status command** — `screentransit --status` to show loaded rules and connected devices
- **Dry-run mode** — `screentransit --dry-run` to log what would happen without sending DDC/CI commands
