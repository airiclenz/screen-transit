import Foundation

enum Log {

    // =========================================================================
    /// Controls whether debug-level messages are emitted.
    static var isDebugEnabled = false

    // =========================================================================
    /// Directory for daily log files.
    private static let logDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/screen-transit")
    }()

    // =========================================================================
    /// Maximum age in days before a log file is deleted.
    private static let maxLogAgeDays = 7

    // =========================================================================
    /// Cached file handle and the date string it belongs to.
    private static var currentLogFile: (date: String, handle: FileHandle)?

    // =========================================================================
    /// Date formatter for log file names (yyyy-MM-dd).
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // =========================================================================
    /// ISO 8601 date formatter with fractional seconds for log timestamps.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()

    // -------------------------------------------------------------------------
    /// Writes a timestamped debug message when debug mode is active.
    static func debug(_ message: String) {
        guard isDebugEnabled else { return }
        log("DEBUG", message)
    }

    // -------------------------------------------------------------------------
    /// Writes a timestamped informational message.
    static func info(_ message: String) {
        log("INFO", message)
    }

    // -------------------------------------------------------------------------
    /// Writes a timestamped error message.
    static func error(_ message: String) {
        log("ERROR", message)
    }

    // -------------------------------------------------------------------------
    /// Formats and writes a log entry to stderr and the daily log file.
    private static func log(_ level: String, _ message: String) {
        let now = Date()
        let timestamp = timestampFormatter.string(from: now)
        let line = Data("[\(timestamp)] [\(level)] \(message)\n".utf8)

        FileHandle.standardError.write(line)
        writeToFile(line, date: now)
    }

    // -------------------------------------------------------------------------
    /// Appends data to the daily log file, rotating when the date changes.
    private static func writeToFile(_ data: Data, date: Date) {
        let today = dateFormatter.string(from: date)

        if currentLogFile?.date != today {
            currentLogFile?.handle.closeFile()
            currentLogFile = nil

            let manager = FileManager.default
            try? manager.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )

            let filePath = logDirectory
                .appendingPathComponent("\(today).log")

            if !manager.fileExists(atPath: filePath.path) {
                manager.createFile(
                    atPath: filePath.path,
                    contents: nil
                )
            }

            guard let handle = try? FileHandle(
                forWritingTo: filePath
            ) else {
                return
            }

            handle.seekToEndOfFile()
            currentLogFile = (date: today, handle: handle)

            purgeOldLogs(manager: manager, today: date)
        }

        currentLogFile?.handle.write(data)
    }

    // -------------------------------------------------------------------------
    /// Deletes log files older than maxLogAgeDays.
    private static func purgeOldLogs(
        manager: FileManager,
        today: Date
    ) {
        guard let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -maxLogAgeDays,
            to: today
        ) else {
            return
        }

        guard let files = try? manager.contentsOfDirectory(
            atPath: logDirectory.path
        ) else {
            return
        }

        for file in files where file.hasSuffix(".log") {
            let datePart = String(file.dropLast(4))

            guard let fileDate = dateFormatter.date(from: datePart),
                  fileDate < cutoff else {
                continue
            }

            let filePath = logDirectory.appendingPathComponent(file)
            try? manager.removeItem(at: filePath)
            Log.info("Purged old log: \(file)")
        }
    }
}
