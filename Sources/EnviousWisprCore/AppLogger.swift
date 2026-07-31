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

    // MARK: Pre-sink buffer (#1361)
    //
    // Lines logged BEFORE the file sink is enabled used to vanish. The cause is
    // not a FileHandle race (the issue's original guess) but the plain
    // `isDebugModeEnabled` guard in `log(...)`: that flag is false until
    // `PipelineSettingsSync.applyInitialSettings` calls `setDebugMode(true)`,
    // so everything emitted earlier in launch reached OSLog and nothing else.
    // A launch-window `finishFailed` never made it to app.log while the
    // IDENTICAL call at press-time did, and that cost about an hour chasing a
    // phantom warmup wedge. Same family as #728, which seeded debug mode at
    // launch; this closes the window that still precedes the seeding.
    //
    // Entries are buffered unrendered so the level filter is applied at FLUSH
    // time against the log level that is actually in force by then, while the
    // timestamp is captured at LOG time so the flushed lines stay in true
    // chronological order.
    private struct PendingLine {
      let timestamp: String
      let level: DebugLogLevel
      let category: String
      let message: String
    }
    private var pendingLines: [PendingLine] = []
    private var pendingDroppedCount = 0
    /// The window is EXACTLY "before the persisted debug setting has been
    /// applied", which is the whole of the bug and nothing more. It closes on
    /// the first `setDebugMode` call in either direction — that call is
    /// `PipelineSettingsSync.applyInitialSettings` at launch.
    ///
    /// Closing on `false` too is what keeps this free in steady state. Keying it
    /// on "has never been ENABLED" instead meant that in the overwhelmingly
    /// common case — a DEBUG build with debug mode off — every one of the ~148
    /// log call sites would format a timestamp and allocate, forever, for output
    /// that can never be flushed. Worse, past the cap each further call paid an
    /// O(n) `removeFirst` on a 500-element array. Neither cost is acceptable to
    /// buy a launch-window diagnostic.
    private var hasAppliedInitialDebugMode = false
    private let maxPendingLines = 500
  #endif

  private init() {}

  public func setDebugMode(_ enabled: Bool) {
    isDebugModeEnabled = enabled
    #if DEBUG
      if enabled {
        openFileHandleIfNeeded()
        // #1361: flush BEFORE the "Debug mode enabled" marker so the launch
        // window's lines, which are older, appear above it and every timestamp
        // in the file ascends. `isDebugModeEnabled` is already true above, so
        // nothing written from here re-enters the buffer.
        flushPendingLines()
        hasAppliedInitialDebugMode = true
        log("Debug mode enabled", level: .info, category: "AppLogger")
      } else {
        // #1361: the window closes here too. Debug logging is off, so nothing
        // buffered can ever be written — discard it rather than hold it, and
        // stop buffering from now on.
        hasAppliedInitialDebugMode = true
        pendingLines = []
        pendingDroppedCount = 0
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

      guard isDebugModeEnabled, level <= logLevel else {
        // #1361: only the pre-sink window is buffered. A line rejected because
        // debug mode is ON but the level is below the threshold is a deliberate
        // filter, not a lost line, so it is NOT buffered.
        if !isDebugModeEnabled, !hasAppliedInitialDebugMode {
          bufferPreSink(level: level, category: category, message: message)
        }
        return
      }

      writeRendered(
        timestamp: timestampFormatter.string(from: Date()),
        level: level, category: category, message: message)
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

    /// Single renderer for both the live path and the #1361 flush, so a format
    /// change cannot apply to one and not the other.
    private func writeRendered(
      timestamp: String, level: DebugLogLevel, category: String, message: String
    ) {
      let line = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      writeToFile(data)
    }

    private func bufferPreSink(level: DebugLogLevel, category: String, message: String) {
      // Bounded: drop the OLDEST and count it, so a long run with debug mode
      // never enabled cannot grow without limit. The count is reported at flush
      // rather than silently swallowed.
      if pendingLines.count >= maxPendingLines {
        pendingLines.removeFirst()
        pendingDroppedCount += 1
      }
      pendingLines.append(
        PendingLine(
          timestamp: timestampFormatter.string(from: Date()),
          level: level, category: category, message: message))
    }

    private func flushPendingLines() {
      // RETAIN if the sink did not actually open. `openFileHandleIfNeeded` fails
      // silently on a directory-creation or permission error, leaving
      // `fileHandle` nil — and `writeToFile` then drops every line on the floor.
      // Clearing the buffer first would destroy exactly the launch-window
      // diagnostics this whole change exists to preserve, and destroy them for
      // the one user whose machine is having a problem. Holding them costs
      // nothing and a later successful open still flushes.
      guard fileHandle != nil else { return }

      let pending = pendingLines
      let dropped = pendingDroppedCount
      pendingLines = []
      pendingDroppedCount = 0
      guard !pending.isEmpty || dropped > 0 else { return }

      // Entries FIRST, marker after. Writing the marker first stamped it with
      // `now` and then emitted older entries beneath it, so the file read
      // now -> launch-time -> now and time ran BACKWARD — the opposite of what
      // the comment claimed. Emitting the entries first keeps every timestamp in
      // the file ascending, and the marker then reports what just happened
      // rather than predicting it.
      var written = 0
      for entry in pending where entry.level <= logLevel {
        writeRendered(
          timestamp: entry.timestamp, level: entry.level, category: entry.category,
          message: entry.message)
        written += 1
      }

      let filtered = pending.count - written
      writeRendered(
        timestamp: timestampFormatter.string(from: Date()), level: .info, category: "AppLogger",
        message:
          "The \(written) line(s) above were buffered before the log file opened and carry their "
          + "original timestamps"
          + (filtered > 0 ? "; \(filtered) more were below the current log level" : "")
          + (dropped > 0 ? "; \(dropped) older line(s) dropped at the \(maxPendingLines) cap" : ""))
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

  #if DEBUG
    /// #1361 test seam. `AppLogger` is a singleton, so a suite that has already
    /// applied a debug mode would leave `hasAppliedInitialDebugMode` latched and the
    /// pre-sink window unreachable for the next test. `package` rather than
    /// `internal` so tests reach it on a plain import, without coupling the seam
    /// to `@testable`.
    package func resetPreSinkBufferForTesting() {
      pendingLines = []
      pendingDroppedCount = 0
      hasAppliedInitialDebugMode = false
    }

    /// Count of lines currently held in the pre-sink buffer (#1361 tests).
    package var pendingPreSinkLineCount: Int { pendingLines.count }
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
