import Foundation

enum DoctorService {

    // =========================================================================
    private static let legacyBinary = "/usr/local/bin/screen-transit"
    private static let brewBinary = "/opt/homebrew/bin/screen-transit"
    private static let legacyServiceLabel = "com.screen-transit.agent"
    private static let brewServiceLabel = "homebrew.mxcl.screen-transit"

    private static let legacyPlistPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/LaunchAgents/com.screen-transit.agent.plist"
            )
            .path
    }()

    // -------------------------------------------------------------------------
    /// Runs the doctor diagnostics and prints results to stdout.
    /// Exits the process with code 1 if any conflicts are found, 0 otherwise.
    static func run() -> Never {
        let manager = FileManager.default
        let legacyBinExists = manager.fileExists(atPath: legacyBinary)
        let brewBinExists = manager.fileExists(atPath: brewBinary)
        let plistExists = manager.fileExists(atPath: legacyPlistPath)
        let loaded = launchctlLoadedLabels()
        let legacyLoaded = loaded.contains(legacyServiceLabel)
        let brewLoaded = loaded.contains(brewServiceLabel)

        print("screen-transit doctor")
        print("=====================")
        print("")

        var issues = 0

        // Binary locations
        switch (legacyBinExists, brewBinExists) {
        case (false, false):
            print(
                "[WARN] No screen-transit binary found at the known install paths."
            )
            issues += 1
        case (true, false):
            print("[ OK ] Single binary: \(legacyBinary)  (deploy.sh)")
        case (false, true):
            print("[ OK ] Single binary: \(brewBinary)  (Homebrew)")
        case (true, true):
            print("[WARN] Two binaries on disk:")
            print("       \(legacyBinary)  (deploy.sh)")
            print("       \(brewBinary)  (Homebrew)")
            if let winner = resolvePathWinner() {
                print("       PATH resolves to: \(winner)")
            }
            issues += 1
        }

        // Version reconciliation between the two binaries
        if legacyBinExists && brewBinExists {
            let legacyVersion = readVersion(of: legacyBinary)
            let brewVersion = readVersion(of: brewBinary)
            if let legacyVersion, let brewVersion {
                if legacyVersion == brewVersion {
                    print(
                        "[ OK ] Both binaries report the same version: "
                            + "\(legacyVersion)"
                    )
                } else {
                    print(
                        "[WARN] Version mismatch — deploy.sh: \(legacyVersion), "
                            + "Homebrew: \(brewVersion)"
                    )
                    issues += 1
                }
            }
        }

        // Legacy plist on disk
        if plistExists {
            let isConflict = brewBinExists || brewLoaded
            let prefix = isConflict ? "[WARN]" : "[ OK ]"
            print("\(prefix) Legacy launchd plist present: \(legacyPlistPath)")
            if isConflict {
                issues += 1
            }
        } else {
            print("[ OK ] No legacy launchd plist on disk.")
        }

        // Loaded services
        switch (legacyLoaded, brewLoaded) {
        case (false, false):
            print("[WARN] No screen-transit launchd service is loaded.")
        case (true, false):
            print(
                "[ OK ] One service loaded: \(legacyServiceLabel)  (deploy.sh)"
            )
        case (false, true):
            print(
                "[ OK ] One service loaded: \(brewServiceLabel)  (Homebrew)"
            )
        case (true, true):
            print(
                "[FAIL] Both launchd services are loaded — "
                    + "they will fight over DDC:"
            )
            print("       \(legacyServiceLabel)  (deploy.sh)")
            print("       \(brewServiceLabel)  (Homebrew)")
            issues += 1
        }

        print("")

        // Remediation block
        let hasLegacy = legacyBinExists || plistExists || legacyLoaded
        let hasBrew = brewBinExists || brewLoaded
        if hasLegacy && hasBrew {
            print("Suggested cleanup of the legacy install:")
            print("")
            if legacyLoaded {
                print("  launchctl unload \(legacyPlistPath)")
            }
            if plistExists {
                print("  rm -f \(legacyPlistPath)")
            }
            if legacyBinExists {
                print("  sudo rm -f \(legacyBinary)")
            }
            print("")
            print("Re-run 'screen-transit --doctor' afterwards to verify.")
        } else if issues == 0 {
            print("No conflicts detected.")
        }

        exit(issues == 0 ? 0 : 1)
    }

    // -------------------------------------------------------------------------
    /// Returns the trimmed stdout of `<binary> --version`, or nil on failure.
    private static func readVersion(of binaryPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--version"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // -------------------------------------------------------------------------
    /// Walks PATH and returns the first directory containing an executable
    /// named screen-transit.
    private static func resolvePathWinner() -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        let manager = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/screen-transit"
            if manager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // -------------------------------------------------------------------------
    /// Returns the set of launchd labels listed by `launchctl list`.
    private static func launchctlLoadedLabels() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var labels: Set<String> = []
        for (lineIndex, line) in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            if lineIndex == 0 { continue }
            let columns = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard let last = columns.last else { continue }
            let label = last.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty {
                labels.insert(label)
            }
        }
        return labels
    }
}
