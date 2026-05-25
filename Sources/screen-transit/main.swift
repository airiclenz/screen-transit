import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("screen-transit \(appVersion)")
    exit(0)
}

if arguments.contains("--help") {
    print("""
        screen-transit v\(appVersion)
        Bluetooth-triggered monitor input switcher for macOS

        Usage:
          screen-transit                Run as daemon (normal mode)
          screen-transit --debug        Run as daemon with verbose logging
          screen-transit --list-displays Show detected external displays
          screen-transit --test D I     Test DDC switch: display D, input I
          screen-transit --doctor       Diagnose install conflicts
          screen-transit --version      Print version and exit
          screen-transit --help         Show this help
        """)
    exit(0)
}

if arguments.contains("--doctor") {
    DoctorService.run()
}

if arguments.contains("--debug") {
    Log.isDebugEnabled = true
    Log.debug("Debug logging enabled")
}

let ddcService = DDCService()

if arguments.contains("--list-displays") {
    let count = ddcService.getDisplayCount()

    if count == 0 {
        print("No external displays found (DCPAVServiceProxy)")
        print("Make sure a monitor is connected and powered on.")
    } else {
        print("Found \(count) external display(s):")
        for index in 1...count {
            print("  Display \(index)")
        }
        print("")
        print("Test a switch: screen-transit --test <display> <input>")
    }

    exit(0)
}

if let testIndex = arguments.firstIndex(of: "--test") {
    guard testIndex + 2 < arguments.count,
          let display = Int(arguments[testIndex + 1]),
          let input = Int(arguments[testIndex + 2]) else {
        print("Usage: screen-transit --test <display> <input>")
        print("Example: screen-transit --test 1 15")
        exit(1)
    }

    print("Sending DDC/CI: display \(display) → input \(input)...")
    let isSuccessful = ddcService.setInput(
        display: display,
        inputCode: input
    )

    if isSuccessful {
        print("Success. Monitor should switch to input \(input).")
    } else {
        print("Failed. Run with --debug for details:")
        print("  screen-transit --debug --test \(display) \(input)")
    }

    exit(isSuccessful ? 0 : 1)
}

let configPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/screen-transit/config.yaml")

guard let config = ConfigLoader.load(from: configPath) else {
    Log.error("Failed to load config from \(configPath.path)")
    exit(1)
}

Log.info(
    "screen-transit v\(appVersion) started "
        + "with \(config.rules.count) rule(s)"
)

for rule in config.rules {
    Log.info(
        "  Rule: \(rule.name) — \(rule.trigger.rawValue) "
            + "\(rule.source):\(rule.deviceIdentifier) "
            + "→ display \(rule.display), input \(rule.input)"
    )
}

Log.debug("Display count: \(ddcService.getDisplayCount())")

let orchestrator = SwitchOrchestrator(
    config: config,
    ddcService: ddcService
)

let bluetoothDisconnectIdentifiers = Set(
    config.rules
        .filter { $0.source == "bluetooth" && $0.trigger == .disconnect }
        .map(\.deviceIdentifier)
)

let bluetoothSource = BluetoothEventSource(
    disconnectIdentifiers: bluetoothDisconnectIdentifiers
)
orchestrator.addEventSource(bluetoothSource)

Log.info("Watching for events...")
RunLoop.main.run()
