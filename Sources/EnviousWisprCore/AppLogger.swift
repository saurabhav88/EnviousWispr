import Foundation
import OSLog

/// Centralised logging for EnviousWispr.
///
/// **Release builds: dead code.** The entire log pipeline (OSLog + file sink)
/// is gated behind `#if DEBUG`. Call sites compile unchanged but produce no
/// output, no Console.app entries, and no `~/Library/Logs/EnviousWispr/` files
/// in shipped binaries. Production diagnostics route via
/// `SentryBreadcrumb.captureError` (errors) and `TelemetryService` (PostHog
/// opt-in events) — NOT through AppLogger.
///
/// **Debug builds:** OSLog entries appear in Console.app under subsystem
/// "com.enviouswispr.app", and file logging to `~/Library/Logs/EnviousWispr/`
/// is active when `isDebugModeEnabled` is true. API keys and secrets are never
/// logged — callers must redact before passing.
public actor AppLogger {
  public static let shared = AppLogger()

  // State preserved in both configs so Settings UI compiles unchanged.
  // In release the setters update internal state harmlessly; log() is a no-op
  // so the state is never observed by any sink.
  public private(set) var isDebugModeEnabled: Bool = false
  public private(set) var logLevel: DebugLogLevel = .info

  #if DEBUG
    private let oslog = Logger(subsystem: "com.enviouswispr.app", category: "pipeline")

    /// Cached date formatter to avoid allocation per log line.
    /// Instance property is safe since AppLogger is an actor with serialized access.
    /// Uses the user's local time zone so `[2026-04-15T19:11:22-04:00]` in the
    /// file log matches their wall clock, not UTC.
    private let timestampFormatter: ISO8601DateFormatter = {
      let formatter = ISO8601DateFormatter()
      // autoupdatingCurrent tracks DST transitions and travel; .current would
      // snapshot the offset at init and go stale in long-running sessions.
      formatter.timeZone = TimeZone.autoupdatingCurrent
      return formatter
    }()

    private let maxFileSize: Int = 10 * 1024 * 1024
    private let maxFileCount: Int = 5

    private var logDirectory: URL {
      let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      return lib.appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
    }
    private var currentLogURL: URL { logDirectory.appendingPathComponent("app.log") }
    private var fileHandle: FileHandle?
  #endif

  private init() {}

  public func setDebugMode(_ enabled: Bool) {
    isDebugModeEnabled = enabled
    #if DEBUG
      if enabled {
        openFileHandleIfNeeded()
        log("Debug mode enabled", level: .info, category: "AppLogger")
      } else {
        log("Debug mode disabled", level: .info, category: "AppLogger")
        fileHandle?.closeFile()
        fileHandle = nil
      }
    #endif
  }

  public func setLogLevel(_ level: DebugLogLevel) {
    logLevel = level
  }

  public func log(_ message: String, level: DebugLogLevel = .info, category: String = "App") {
    #if DEBUG
      switch level {
      case .info: oslog.info("[\(category)] \(message)")
      case .verbose: oslog.debug("[\(category)] \(message)")
      case .debug: oslog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
      }

      guard isDebugModeEnabled, level <= logLevel else { return }

      let timestamp = timestampFormatter.string(from: Date())
      let line = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(message)\n"

      guard let data = line.data(using: .utf8) else { return }
      writeToFile(data)
    #endif
    // Release: no-op. The 148 call sites still pay the actor-hop cost of
    // `await AppLogger.shared.log(...)`; the privacy win is removing all sink
    // output, not eliminating call-site overhead.
  }

  #if DEBUG

    // MARK: - File management (debug-only)

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
        size >= maxFileSize
      else { return }

      fileHandle?.closeFile()
      fileHandle = nil

      let dir = logDirectory
      for i in stride(from: maxFileCount - 1, through: 1, by: -1) {
        let old = dir.appendingPathComponent("app.\(i).log")
        let new = dir.appendingPathComponent("app.\(i + 1).log")
        try? FileManager.default.moveItem(at: old, to: new)
      }
      try? FileManager.default.moveItem(
        at: currentLogURL,
        to: dir.appendingPathComponent("app.1.log"))

      let oldest = dir.appendingPathComponent("app.\(maxFileCount).log")
      try? FileManager.default.removeItem(at: oldest)

      openFileHandleIfNeeded()
    }

  #endif

  // MARK: - Utilities

  public func logDirectoryURL() -> URL {
    #if DEBUG
      return logDirectory
    #else
      // API-shape preservation only. Settings UI's "Open log folder" button is
      // hidden in release via the Diagnostics tab `#if DEBUG` wrap; this URL
      // never gets opened. No file is ever created here.
      let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      return lib.appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
    #endif
  }

  public func clearLogs() throws {
    #if DEBUG
      fileHandle?.closeFile()
      fileHandle = nil
      let dir = logDirectory
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil
        )
      else { return }
      for file in files where file.pathExtension == "log" {
        try FileManager.default.removeItem(at: file)
      }
      if isDebugModeEnabled { openFileHandleIfNeeded() }
    #endif
    // Release: no-op. The Diagnostics tab's "Clear logs" button is hidden via
    // `#if DEBUG`; this method exists only to keep the public API stable.
  }
}
