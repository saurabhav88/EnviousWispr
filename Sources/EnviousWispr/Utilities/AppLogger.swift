import Foundation
import OSLog

/// Centralised logging for EnviousWispr.
///
/// - OSLog entries are always emitted (at the appropriate level) and are
///   visible in Console.app under subsystem "com.enviouswispr.app".
/// - File logging to ~/Library/Logs/EnviousWispr/ is active only while
///   isDebugModeEnabled is true.
/// - API keys and secrets are never logged — callers must redact before passing.
actor AppLogger {
    static let shared = AppLogger()

    private(set) var isDebugModeEnabled: Bool = false
    private(set) var logLevel: DebugLogLevel = .info

    private let oslog = Logger(subsystem: "com.enviouswispr.app", category: "pipeline")

    private let maxFileSize: Int = 10 * 1024 * 1024
    private let maxFileCount: Int = 5

    private var logDirectory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
    }
    private var currentLogURL: URL { logDirectory.appendingPathComponent("app.log") }
    private var fileHandle: FileHandle?

    private init() {}

    func setDebugMode(_ enabled: Bool) {
        isDebugModeEnabled = enabled
        if enabled {
            openFileHandleIfNeeded()
            log("Debug mode enabled", level: .info, category: "AppLogger")
        } else {
            log("Debug mode disabled", level: .info, category: "AppLogger")
            fileHandle?.closeFile()
            fileHandle = nil
        }
    }

    func setLogLevel(_ level: DebugLogLevel) {
        logLevel = level
    }

    func log(_ message: String, level: DebugLogLevel = .info, category: String = "App") {
        switch level {
        case .info:    oslog.info("[\(category)] \(message)")
        case .verbose: oslog.debug("[\(category)] \(message)")
        case .debug:   oslog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        }

        guard isDebugModeEnabled, level <= logLevel else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        writeToFile(data)
    }

    // MARK: - File management

    private func openFileHandleIfNeeded() {
        guard fileHandle == nil else { return }
        let dir = logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: currentLogURL.path) {
            FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: currentLogURL)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ data: Data) {
        guard let fh = fileHandle else { return }
        fh.write(data)
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
              let size = attrs[.size] as? Int,
              size >= maxFileSize else { return }

        fileHandle?.closeFile()
        fileHandle = nil

        let dir = logDirectory
        for i in stride(from: maxFileCount - 1, through: 1, by: -1) {
            let old = dir.appendingPathComponent("app.\(i).log")
            let new = dir.appendingPathComponent("app.\(i + 1).log")
            try? FileManager.default.moveItem(at: old, to: new)
        }
        try? FileManager.default.moveItem(at: currentLogURL,
                                          to: dir.appendingPathComponent("app.1.log"))

        let oldest = dir.appendingPathComponent("app.\(maxFileCount + 1).log")
        try? FileManager.default.removeItem(at: oldest)

        openFileHandleIfNeeded()
    }

    // MARK: - Utilities

    func logDirectoryURL() -> URL { logDirectory }

    func clearLogs() throws {
        fileHandle?.closeFile()
        fileHandle = nil
        let dir = logDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "log" {
            try FileManager.default.removeItem(at: file)
        }
        if isDebugModeEnabled { openFileHandleIfNeeded() }
    }
}
