import Foundation
import Darwin

enum InitService {

    // =========================================================================
    private static let configRelativePath = ".config/screen-transit/config.yaml"
    private static let signingScriptName = "screen-transit-signing.sh"

    // =========================================================================
    /// Default config written on first --init when no config exists yet.
    /// This is the single source of truth — the Homebrew formula and
    /// deploy.sh no longer ship their own copies.
    private static let defaultConfigYAML = """
        # screen-transit configuration
        #
        # Replace the placeholder values below with your actual device information.
        #
        # Discovery commands:
        #   blueutil --paired                     Find Bluetooth MAC address
        #   system_profiler SPBluetoothDataType   Alternative for Bluetooth MAC
        #   m1ddc display list                    Find display number
        #   m1ddc get input                       Find current input code
        #                                         (switch input via monitor OSD first)
        #
        # Common DDC/CI input codes (VCP 0x60) -- verify yours with m1ddc:
        #   15 = DisplayPort-1    16 = DisplayPort-2
        #   17 = USB-C             4 = HDMI-1         5 = HDMI-2
        #
        # Reload after editing:
        #   brew services restart screen-transit

        # Seconds to wait before sending DDC/CI command after the trigger event.
        # Increase if your monitor needs more time to wake. Default: 1.0
        delay: 1.0

        rules:
          # Uncomment and edit the rules below.
          #
          # - name: "Keyboard connect → DisplayPort"
          #   source: bluetooth
          #   device_id: "AA:BB:CC:DD:EE:FF"
          #   display: 1
          #   input: 15
          #   trigger: connect
          #
          # - name: "Keyboard disconnect → USB-C"
          #   source: bluetooth
          #   device_id: "AA:BB:CC:DD:EE:FF"
          #   display: 1
          #   input: 17
          #   trigger: disconnect
        """

    // -------------------------------------------------------------------------
    /// Runs first-time setup: creates the default config file if missing and
    /// invokes the sibling signing script to create a self-signed cert and
    /// sign this binary. Exits 0 on success, non-zero on failure.
    static func run() -> Never {
        print("screen-transit init")
        print("===================")
        print("")

        ensureConfigExists()
        print("")
        let signed = runSigningScript()

        print("")
        if signed {
            print("Setup complete.")
            print("")
            print("Next steps:")
            print(
                "  1. Edit your config: "
                    + "~/\(configRelativePath)"
            )
            print(
                "  2. Start the service: "
                    + "brew services start screen-transit"
            )
        } else {
            print("Setup finished with errors. See messages above.")
        }

        exit(signed ? 0 : 1)
    }

    // -------------------------------------------------------------------------
    /// Creates ~/.config/screen-transit/config.yaml with the default template
    /// if it does not already exist. Existing configs are left untouched.
    private static func ensureConfigExists() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(configRelativePath)
        let manager = FileManager.default

        if manager.fileExists(atPath: configURL.path) {
            print("[ OK ] Config already exists: \(configURL.path)")
            return
        }

        let configDir = configURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: configDir,
                withIntermediateDirectories: true
            )
            try defaultConfigYAML.write(
                to: configURL,
                atomically: true,
                encoding: .utf8
            )
            print("[ OK ] Created default config: \(configURL.path)")
        } catch {
            print(
                "[FAIL] Could not write config to \(configURL.path): "
                    + "\(error.localizedDescription)"
            )
        }
    }

    // -------------------------------------------------------------------------
    /// Locates the sibling signing script and runs it against this binary.
    /// If no codesigning identity exists yet, prompts the user for their
    /// login keychain password here (echo disabled) and forwards it to the
    /// script via the ST_KEYCHAIN_PASS environment variable. This avoids
    /// terminal-attribute inheritance issues with the spawned bash process.
    /// Returns true if the script exited 0.
    private static func runSigningScript() -> Bool {
        guard let executablePath = currentExecutablePath() else {
            print("[FAIL] Could not determine running executable path.")
            return false
        }

        let scriptURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent(signingScriptName)

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            print(
                "[FAIL] Signing script not found next to binary: "
                    + scriptURL.path
            )
            print(
                "       Expected sibling of: \(executablePath)"
            )
            return false
        }

        var env = ProcessInfo.processInfo.environment

        if !hasValidIdentity() {
            print(
                "==> No code-signing identity found — a new one will be "
                    + "created."
            )
            guard let password = promptPasswordSilently(
                "    Login keychain password: "
            ), !password.isEmpty else {
                print("[FAIL] Could not read keychain password.")
                return false
            }
            env["ST_KEYCHAIN_PASS"] = password
        }

        print("==> Running \(signingScriptName)...")
        fflush(stdout)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, executablePath]
        process.environment = env

        do {
            try process.run()
        } catch {
            print(
                "[FAIL] Could not launch signing script: "
                    + "\(error.localizedDescription)"
            )
            return false
        }
        process.waitUntilExit()

        return process.terminationStatus == 0
    }

    // -------------------------------------------------------------------------
    /// Returns true if a "Screen Transit Local" codesigning identity exists
    /// in the user's keychain. We intentionally omit `-v` ("Valid only")
    /// because self-signed certs without explicit trust settings are filtered
    /// out by it — even though codesign happily uses them.
    private static func hasValidIdentity() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "security find-identity -p codesigning "
                + "| grep -q '\"Screen Transit Local\"'",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // -------------------------------------------------------------------------
    /// Reads a line from /dev/tty with echo disabled. Returns nil if no
    /// controlling terminal is available (e.g. running detached). The prompt
    /// is written directly to /dev/tty so it always appears on the user's
    /// screen regardless of stdout redirection.
    private static func promptPasswordSilently(_ prompt: String) -> String? {
        let tty = open("/dev/tty", O_RDWR)
        guard tty >= 0 else { return nil }
        defer { close(tty) }

        var oldTermios = termios()
        guard tcgetattr(tty, &oldTermios) == 0 else { return nil }

        var newTermios = oldTermios
        newTermios.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(tty, TCSANOW, &newTermios) == 0 else { return nil }
        defer { _ = tcsetattr(tty, TCSANOW, &oldTermios) }

        prompt.withCString { cstr in
            _ = write(tty, cstr, strlen(cstr))
        }

        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(tty, &byte, 1) == 1 {
            if byte == 0x0a || byte == 0x0d { break }
            bytes.append(byte)
        }

        var newline: UInt8 = 0x0a
        _ = write(tty, &newline, 1)

        return String(bytes: bytes, encoding: .utf8)
    }

    // -------------------------------------------------------------------------
    /// Returns the absolute, symlink-resolved path of the running executable
    /// using _NSGetExecutablePath + realpath.
    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 1024
        var buffer = [CChar](repeating: 0, count: Int(size))

        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) != 0 {
                return nil
            }
        }

        guard let resolved = realpath(buffer, nil) else {
            return String(cString: buffer)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
