import Foundation
import Testing

@testable import EnviousWisprCore

/// Validates Phase R3 compile-out: `AppLogger` is dev-only, release sinks are dead code.
///
/// In debug builds, enabling debug mode + logging must produce content on disk under
/// `~/Library/Logs/EnviousWispr/app.log`. In release builds, the same call sequence
/// must NOT emit the marker — the sink machinery is gated behind `#if DEBUG`.
///
/// Tests are non-destructive: each assertion uses a unique-per-run marker token and
/// inspects the existing log file (or its absence) without deleting or truncating
/// the developer's real logs. Running the suite locally never wipes
/// `~/Library/Logs/EnviousWispr/`.
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

    @Test("Debug build: log() emits the marker into the file sink")
    func debugBuildEmitsMarkerIntoFileSink() async throws {
      let marker = Self.uniqueMarker("debug")
      let priorMode = await AppLogger.shared.isDebugModeEnabled

      await AppLogger.shared.setDebugMode(true)
      await AppLogger.shared.log(marker, level: .info, category: "Test")
      // Drain in-flight actor work before reading the file.
      _ = await AppLogger.shared.logDirectoryURL()

      let url = Self.expectedLogURL
      #expect(FileManager.default.fileExists(atPath: url.path))
      #expect(Self.fileContains(url, marker: marker))

      // Restore prior debug-mode state — never assume default false, so suite
      // ordering does not change behavior.
      await AppLogger.shared.setDebugMode(priorMode)
    }

  #else

    @Test("Release build: log() does NOT emit the marker (sink is dead code)")
    func releaseBuildSinkIsDeadCode() async throws {
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

  #endif
}
