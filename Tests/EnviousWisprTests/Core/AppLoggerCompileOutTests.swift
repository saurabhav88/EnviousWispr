import Darwin
import Foundation
import Testing

@testable import EnviousWisprCore

/// Validates Phase R3 compile-out: `AppLogger` is dev-only, release sinks are dead code.
///
/// In debug builds, enabling debug mode + logging must produce content in the
/// test lane's private log directory. In release builds, the same call sequence
/// must NOT emit the marker — the sink machinery is gated behind `#if DEBUG`.
///
/// Tests are non-destructive: each assertion uses a unique-per-run marker token.
@Suite("AppLogger R3 compile-out")
struct AppLoggerCompileOutTests {

  /// Resolves the file URL the (debug-build) sink would write to. Mirrors the actor
  /// implementation but stays out of process so we can inspect the filesystem
  /// regardless of which config we're compiled in.
  private static var expectedLogURL: URL {
    let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    return
      lib
      .appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
      .appendingPathComponent("app.log")
  }

  /// Returns true if the file at `url` contains `marker` as a UTF-8 substring.
  /// Returns false if the file does not exist or cannot be read.
  private static func fileContains(_ url: URL, marker: String) -> Bool {
    guard let data = try? Data(contentsOf: url),
      let s = String(data: data, encoding: .utf8)
    else { return false }
    return s.contains(marker)
  }

  /// Generates a one-shot marker that cannot collide with any prior log line.
  private static func uniqueMarker(_ tag: String) -> String {
    "R3-test-\(tag)-\(UUID().uuidString)"
  }

  #if DEBUG

    @Test("test log override accepts only an absolute path")
    func testLogOverrideAcceptsOnlyAbsolutePath() {
      let fallback = URL(fileURLWithPath: "/tmp/ew-library", isDirectory: true)
      let isolated = AppLogger.resolveLogDirectory(
        environment: ["EW_APP_LOG_DIRECTORY": "/tmp/ew-tests/logger"],
        libraryDirectory: fallback)
      #expect(isolated.path == "/tmp/ew-tests/logger")

      let rejected = AppLogger.resolveLogDirectory(
        environment: ["EW_APP_LOG_DIRECTORY": "relative/logger"],
        libraryDirectory: fallback)
      #expect(rejected == fallback.appendingPathComponent("Logs/EnviousWispr", isDirectory: true))
    }

    @Test("every file handle appends at write time instead of keeping a stale offset")
    func everyFileHandleUsesAppendSemantics() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2159-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }

      let url = directory.appendingPathComponent("app.log")
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
      let first = try #require(AppLogger.openAppendFileHandle(at: url))
      let second = try #require(AppLogger.openAppendFileHandle(at: url))
      defer {
        try? first.close()
        try? second.close()
      }

      let flags = fcntl(first.fileDescriptor, F_GETFL)
      #expect(flags >= 0)
      #expect(flags & O_APPEND == O_APPEND, "the AppLogger handle must carry O_APPEND")

      // Both handles opened while the file was empty. Without O_APPEND each
      // keeps offset zero and these alternating writes overwrite one another.
      // With O_APPEND, the kernel resolves the current end for every write.
      for (handle, line) in [
        (first, "main-1\n"),
        (second, "xpc-1-longer\n"),
        (first, "main-2-even-longer\n"),
        (second, "xpc-2\n"),
      ] {
        try handle.write(contentsOf: Data(line.utf8))
      }
      try first.synchronize()
      try second.synchronize()

      let contents = try String(contentsOf: url, encoding: .utf8)
      #expect(contents == "main-1\nxpc-1-longer\nmain-2-even-longer\nxpc-2\n")
    }

    @Test("Debug build: log() emits the marker into the file sink")
    func debugBuildEmitsMarkerIntoFileSink() async throws {
      // Three separate suites toggle the AppLogger singleton and Swift Testing
      // runs suites in parallel; `.serialized` cannot span them (#1361).
      try await withAppLoggerExclusion {
      let marker = Self.uniqueMarker("debug")
      let priorMode = await AppLogger.shared.isDebugModeEnabled

      await AppLogger.shared.setDebugMode(true)
      await AppLogger.shared.log(marker, level: .info, category: "Test")
      // Drain in-flight actor work before reading the file.
      _ = await AppLogger.shared.logDirectoryURL()

      let logDirectory = await AppLogger.shared.logDirectoryURL()
      let url = logDirectory.appendingPathComponent("app.log")
      if let configuredDirectory = ProcessInfo.processInfo.environment["EW_APP_LOG_DIRECTORY"] {
        let configuredURL = URL(fileURLWithPath: configuredDirectory, isDirectory: true)
          .standardizedFileURL
        // The canonical test wrapper always takes this branch, keeping a running
        // developer app and the test process on separate files.
        #expect(logDirectory == configuredURL)
        #expect(logDirectory != Self.expectedLogURL.deletingLastPathComponent())
      } else {
        // Direct xcodebuild callers, including GitHub CI, intentionally exercise
        // the normal app fallback instead of requiring a wrapper-only variable.
        #expect(logDirectory == Self.expectedLogURL.deletingLastPathComponent())
      }
      #expect(FileManager.default.fileExists(atPath: url.path))
      #expect(Self.fileContains(url, marker: marker))

      // Restore prior debug-mode state — never assume default false, so suite
      // ordering does not change behavior.
      await AppLogger.shared.setDebugMode(priorMode)
      }
    }

  #else

    @Test("Release build: log() does NOT emit the marker (sink is dead code)")
    func releaseBuildSinkIsDeadCode() async throws {
      // See the DEBUG case above: cross-suite exclusion, not `.serialized`.
      try await withAppLoggerExclusion {
      let marker = Self.uniqueMarker("release")
      let priorMode = await AppLogger.shared.isDebugModeEnabled
      let url = Self.expectedLogURL
      let priorExists = FileManager.default.fileExists(atPath: url.path)

      await AppLogger.shared.setDebugMode(true)
      await AppLogger.shared.log(marker, level: .info, category: "Test")
      // Drain in-flight actor work before checking the filesystem.
      _ = await AppLogger.shared.logDirectoryURL()

      // The marker MUST NOT appear anywhere in the (possibly pre-existing) file.
      // Existence/size of the file are not asserted because a developer running
      // the suite locally may have a populated app.log from prior dev work.
      #expect(!Self.fileContains(url, marker: marker))
      #expect(FileManager.default.fileExists(atPath: url.path) == priorExists)

      // Internal state still updates harmlessly even though the sink is dead.
      let isEnabled = await AppLogger.shared.isDebugModeEnabled
      #expect(isEnabled == true)

      await AppLogger.shared.setDebugMode(priorMode)
      }
    }

  #endif
}
